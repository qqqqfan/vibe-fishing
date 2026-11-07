import AppKit
import ApplicationServices
import Combine
import RelayCore

/// One guided connection path. Phone setup is manual; task events drive the
/// two-frame playback prototype only after the video page is confirmed.
@MainActor
final class LaunchCoordinator: ObservableObject {
    @Published private(set) var flow = LaunchFlowState()
    @Published private(set) var detail = ""
    @Published private(set) var phoneLaunchSent = false
    @Published private(set) var arranging = false
    @Published var keepTogether = UserDefaults.standard.object(forKey: "keepTogether") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(keepTogether, forKey: "keepTogether")
            if !keepTogether { followTask?.cancel() }
        }
    }
    @Published var autoArrangeWindows = UserDefaults.standard.object(forKey: "autoArrangeWindows") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoArrangeWindows, forKey: "autoArrangeWindows")
            if !autoArrangeWindows { followTask?.cancel(); rearrangeTask?.cancel() }
        }
    }
    @Published var autoOpenPreferredApp = UserDefaults.standard.bool(forKey: "autoOpenPreferredApp") {
        didSet { UserDefaults.standard.set(autoOpenPreferredApp, forKey: "autoOpenPreferredApp") }
    }
    weak var store: RelayStore?
    private var task: Task<Void, Never>?
    private var followTask: Task<Void, Never>?
    private var rearrangeTask: Task<Void, Never>?
    private var following = false
    private var lastFollow: TimeInterval = 0
    private var agentApp: NSRunningApplication?
    private var videoPageConfirmed = false
    private var manualPlaybackSelected = false
    private var manuallyOpened = false
    private var screenSignature = ""
    private var lastRelayout: TimeInterval = 0
    private var permissionSubscription: AnyCancellable?
    private var lastConnectionCheck: TimeInterval = 0
    private var missingMirrorChecks = 0

    var steps: [LaunchStep] { flow.steps }
    var currentIndex: Int {
        flow.currentStep.flatMap { steps.firstIndex(of: $0) } ?? min(flow.completedSteps.count, steps.count - 1)
    }
    var progress: Double { Double(flow.completedSteps.count) / Double(max(1, steps.count)) }
    var isWaitingForSignal: Bool { isStarted && store?.listening == true && !flow.agentEventsVerified }
    var primaryActionTitle: String {
        if isBusy { return "处理中…" }
        if isWaitingForSignal { return "等待 AI 生成" }
        switch flow.currentStep {
        case .grantPermissions:
            if store?.permissions.accessibilityGranted == true { return "继续" }
            return store?.permissions.accessibilitySettingsOpened == true ? "继续" : "打开系统设置"
        case .connectPlayback: return store?.playback.kind == .local ? "选择视频" : "继续"
        default: return "继续"
        }
    }

    func observePermissionChanges() {
        guard let store else { return }
        permissionSubscription = store.permissions.$accessibilityGranted
            .sink { [weak self] granted in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if granted {
                    guard self.flow.status == .blocked, self.flow.currentStep == .grantPermissions else { return }
                    self.startOrRetry()
                } else if self.flow.currentStep != .grantPermissions {
                    self.interruptConnection(at: .grantPermissions, reason: "辅助功能权限已关闭。")
                }
            }
        }
    }

    func advanceCurrentStep() {
        guard !isBusy else { return }
        switch flow.currentStep {
        case .grantPermissions:
            if store?.permissions.checkAccessibility() == true {
                startOrRetry()
            } else if store?.permissions.accessibilitySettingsOpened == true {
                detail = "未检测到授权。"
            } else {
                store?.permissions.requestAccessibility()
            }
        case .openPreferredPhoneApp: continueWithManualPlayback()
        case .connectPlayback where store?.playback.kind == .mirror:
            let recovery = recoveryStep(for: .connectPlayback)
            if recovery == .openPhoneMirror {
                interruptConnection(at: .openPhoneMirror, reason: "请先重新连接 iPhone 镜像。")
                startOrRetry()
            } else if !videoPageConfirmed {
                confirmVideoPage()
            } else {
                startOrRetry()
            }
        case .connectPlayback where store?.playback.kind == .local:
            let generation = flow.generation
            store?.playback.chooseVideos()
            guard flow.generation == generation, flow.status == .blocked,
                  flow.currentStep == .connectPlayback else { return }
            if store?.playback.hasLocalVideos == true { startOrRetry() }
        default: startOrRetry()
        }
    }

    var isBusy: Bool { flow.status == .running }
    var isStarted: Bool { flow.status == .ready }
    var needsVideoConfirmation: Bool { flow.status == .blocked && (flow.currentStep == .connectPlayback || flow.currentStep == .openPreferredPhoneApp) }
    var needsPhoneSelection: Bool { flow.status == .blocked && flow.currentStep == .openPreferredPhoneApp }
    func startOrRetry() {
        guard !isBusy, !isStarted else { return }
        let command: LaunchStepCommand?
        if flow.status == .blocked { command = flow.retry() }
        else {
            store?.stopListening()
            store?.mirror.controlEnabled = false
            store?.mirror.window = nil
            store?.mirror.point = nil
            store?.mirror.supportsAutomaticPlayback = false
            videoPageConfirmed = false
            manualPlaybackSelected = false
            phoneLaunchSent = false
            manuallyOpened = false
            let route: [LaunchStep] = store?.playback.kind == .local
                ? [.grantPermissions, .openAIClient, .connectPlayback, .startListening]
                : LaunchStep.allCases
            flow = LaunchFlowState(steps: route)
            command = flow.begin()
        }
        guard let command else { return }
        run(command)
    }

    func stop() {
        task?.cancel()
        followTask?.cancel()
        rearrangeTask?.cancel()
        flow.cancel()
        store?.stopListening()
        store?.mirror.controlEnabled = false
        store?.mirror.setObservationEnabled(false)
        videoPageConfirmed = false
        manualPlaybackSelected = false
        detail = ""
    }

    private func recoveryStep(for requested: LaunchStep) -> LaunchStep {
        guard let store, store.playback.kind == .mirror,
              [.openPreferredPhoneApp, .arrangeWindows, .connectPlayback, .startListening].contains(requested) else { return requested }
        guard let window = store.mirror.window, window.liveFrame != nil,
              NSRunningApplication(processIdentifier: window.pid)?.isTerminated == false,
              Self.mirrorConnectionBlocker(window) == nil else { return .openPhoneMirror }
        if requested == .connectPlayback && !videoPageConfirmed { return .openPreferredPhoneApp }
        return requested
    }

    func interruptConnection(at requested: LaunchStep, reason: String) {
        let step = recoveryStep(for: requested)
        guard flow.interrupt(at: step, reason: reason) else { return }
        task?.cancel()
        followTask?.cancel()
        rearrangeTask?.cancel()
        store?.stopListening()
        store?.mirror.controlEnabled = false
        store?.mirror.setObservationEnabled(false)
        if step == .openPhoneMirror {
            store?.mirror.window = nil
            videoPageConfirmed = false
            phoneLaunchSent = false
        }
        if step == .grantPermissions {
            videoPageConfirmed = false
            manuallyOpened = false
            store?.mirror.window = nil
        }
        detail = reason
        store?.onNeedsGuidance?()
    }

    /// Page confirmation never claims that we can read the phone's video state.
    func confirmVideoPage() {
        guard needsVideoConfirmation else { return }
        videoPageConfirmed = true
        store?.mirror.supportsAutomaticPlayback = false
        if needsPhoneSelection { manuallyOpened = true }
        startOrRetry()
    }

    func continueWithManualPlayback() {
        guard needsVideoConfirmation else { return }
        manualPlaybackSelected = true
        confirmVideoPage()
    }

    func recordAgentEvent() { _ = flow.recordAgentEvent() }
    func listeningChanged(_ listening: Bool) { flow.resetAgentConnection(isListening: listening) }

    /// Every AI app installed on this Mac, running or not, for the picker.
    var installableClients: [(name: String, bundleID: String, url: URL, running: Bool)] {
        let runningIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let clients = store?.agentMonitor.clients ?? AgentAppMonitor.standardClients
        var seen = Set<String>()
        return clients.compactMap { client in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: client.bundleID),
                  seen.insert(url.path).inserted else { return nil }
            return (name: client.name, bundleID: client.bundleID, url: url,
                    running: runningIDs.contains(client.bundleID))
        }
    }

    @Published private(set) var openingClientID: String?

    /// Picker action: open the app if it is not running, or bring it forward
    /// and ask it for a window if it is (the reopen event that a Dock click
    /// sends). Once its window appears, select it and continue the step.
    func chooseClient(bundleID: String) {
        guard let store, openingClientID == nil,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        openingClientID = bundleID
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        configuration.promptsUserIfNeeded = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
        Task { @MainActor [weak self] in
            defer { self?.openingClientID = nil }
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard let self else { return }
                guard self.flow.currentStep == .openAIClient else { return }
                store.refreshWindows()
                if let window = store.windows.first(where: { $0.bundleID == bundleID && $0.liveFrame != nil }) {
                    store.selectedWindowID = window.id
                    NSApp.activate(ignoringOtherApps: true)
                    self.advanceCurrentStep()
                    return
                }
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func openClient(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        configuration.promptsUserIfNeeded = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    /// One-click layout from the main window and the menu bar.
    func rearrangeLayout() {
        store?.refreshWindows()
        rearrange()
    }

    /// One-line explanation shown on hover in the step timeline.
    static func stepHint(_ step: LaunchStep) -> String {
        switch step {
        case .grantPermissions: return "检查辅助功能与音频读取授权。"
        case .openAIClient: return "至少打开一个 AI 应用窗口。"
        case .openPhoneMirror: return "打开 iPhone 镜像并等待连接。"
        case .openPreferredPhoneApp: return "在镜像中打开竖屏短视频信息流，开启自动连播。"
        case .arrangeWindows: return "把 AI 窗口和镜像并排铺开。"
        case .connectPlayback: return "开始读取镜像的声音与画面信号。"
        case .startListening: return "在 AI 应用发送一条消息，完成首次验证。"
        }
    }

    func stepTitle(_ step: LaunchStep) -> String {
        switch step {
        case .grantPermissions: return "开启权限"
        case .openAIClient: return "打开 AI 应用"
        case .openPhoneMirror: return "连接 iPhone 镜像"
        case .arrangeWindows: return "排列窗口"
        case .openPreferredPhoneApp: return "打开短视频"
        case .connectPlayback: return store?.playback.kind == .local ? "选择本地视频" : "准备播放控制"
        case .startListening: return "等待 AI 生成"
        }
    }

    /// Connection readiness is checked independently of window docking.
    /// Silence is a valid paused video and must never mean disconnected.
    private static func isMinimized(_ window: ClientWindow) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(window.element, kAXMinimizedAttribute as CFString, &value) == .success
            && (value as? Bool) == true
    }

    private func checkConnectionHealth() {
        guard isStarted, let store else { missingMirrorChecks = 0; return }
        let now = Date().timeIntervalSince1970
        guard now - lastConnectionCheck >= 1 else { return }
        lastConnectionCheck = now
        guard AccessibilityProbe.isTrusted else {
            interruptConnection(at: .grantPermissions, reason: "辅助功能权限已关闭，请重新授权。")
            return
        }
        if store.playback.kind == .mirror {
            guard let window = store.mirror.window,
                  let app = NSRunningApplication(processIdentifier: window.pid), !app.isTerminated else {
                missingMirrorChecks += 1
                if missingMirrorChecks >= 2 {
                    interruptConnection(at: .openPhoneMirror, reason: "iPhone 镜像窗口已断开，请重新连接。")
                }
                return
            }
            // Minimizing/hiding the mirror is an intentional way to get it
            // out of the way, not a disconnection. Keep AI listening and the
            // connection state; MirrorController queues playback intent until
            // the window is visible again.
            let tucked = app.isHidden || Self.isMinimized(window)
            if tucked {
                missingMirrorChecks = 0
            } else {
                guard window.liveFrame != nil else {
                    missingMirrorChecks += 1
                    if missingMirrorChecks >= 2 {
                        interruptConnection(at: .openPhoneMirror, reason: "iPhone 镜像窗口已断开，请重新连接。")
                    }
                    return
                }
                missingMirrorChecks = 0
                if let blocker = Self.mirrorConnectionBlocker(window) {
                    interruptConnection(at: .openPhoneMirror, reason: blocker)
                    return
                }
                guard store.mirror.controlEnabled else {
                    interruptConnection(at: .connectPlayback, reason: "镜像播放控制不可用，请重新连接。")
                    return
                }
            }
        }
        guard store.listening else {
            interruptConnection(at: .startListening, reason: "AI 状态监听已停止，请重新连接。")
            return
        }
        if let selected = store.selectedWindow,
           NSRunningApplication(processIdentifier: selected.pid)?.isTerminated != false {
            interruptConnection(at: .openAIClient, reason: "所选 AI 应用已退出，请选择其他窗口。")
        }
    }

    func tick() {
        checkConnectionHealth()
        guard isStarted, keepTogether, autoArrangeWindows, !following, !arranging,
              Date().timeIntervalSince1970 - lastFollow > 1,
              let store, let agent = store.selectedWindow, let mirror = store.mirror.window else { return }
        following = true
        lastFollow = Date().timeIntervalSince1970
        let generation = flow.generation
        followTask = Task { [weak self] in
            guard let self else { return }
            defer { self.following = false }
            guard self.flow.generation == generation, self.isStarted, self.keepTogether,
                  self.autoArrangeWindows, !Task.isCancelled else { return }
            let signature = NSScreen.screens.map { "\($0.frame)-\($0.visibleFrame)" }.joined(separator: ";")
            let screensChanged = !self.screenSignature.isEmpty && self.screenSignature != signature
            self.screenSignature = signature
            var result = screensChanged
                ? await store.dock.layoutSideBySide(agent: agent, mirror: mirror)
                : await store.dock.followMirror(beside: agent, mirror: mirror)
            guard self.flow.generation == generation, self.keepTogether,
                  self.autoArrangeWindows, !Task.isCancelled else { return }
            if !result.success, !screensChanged {
                // A second change inside the debounce interval waits for the
                // next tick instead of permanently disabling attachment.
                guard Date().timeIntervalSince1970 - self.lastRelayout > 5 else { return }
                self.lastRelayout = Date().timeIntervalSince1970
                result = await store.dock.layoutSideBySide(agent: agent, mirror: mirror)
            }
            if !result.success, !Task.isCancelled, self.flow.generation == generation {
                self.keepTogether = false
                self.detail = result.message + ""
            }
        }
    }

    func rearrange() {
        guard !isBusy, !arranging, !following, let store, let agent = store.selectedWindow,
              let mirror = store.dock.mirrorWindows().first ?? store.mirror.window else { return }
        store.mirror.window = mirror
        arranging = true
        rearrangeTask = Task { [weak self] in
            guard let self else { return }
            defer { self.arranging = false }
            // Keep the mirror's size when it still fits; after a display change
            // (e.g. unplugging a large monitor) it may not, so re-fit the
            // mirror to the new screen instead of refusing.
            var result = await store.dock.layoutSideBySide(agent: agent, mirror: mirror, preserveMirrorSize: true)
            if !result.success, !Task.isCancelled {
                store.refreshWindows()
                if let freshAgent = store.selectedWindow,
                   let freshMirror = store.dock.mirrorWindows().first {
                    store.mirror.window = freshMirror
                    result = await store.dock.layoutSideBySide(agent: freshAgent, mirror: freshMirror, preserveMirrorSize: false)
                }
            }
            self.detail = result.message
            store.message = result.message
            if result.success { self.screenSignature = ""; store.onTickCompanion?() }
        }
    }

    private func run(_ first: LaunchStepCommand) {
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            var next: LaunchStepCommand? = first
            while let command = next, !Task.isCancelled, self.flow.canExecute(command) {
                self.detail = self.stepTitle(command.step)
                let failure = await self.execute(command)
                guard !Task.isCancelled, self.flow.canExecute(command) else { return }
                if let failure {
                    let recovery = self.recoveryStep(for: command.step)
                    if recovery != command.step {
                        self.interruptConnection(at: recovery, reason: failure)
                        return
                    }
                    _ = self.flow.block(command, reason: failure)
                    self.detail = failure
                    self.store?.onNeedsGuidance?()
                    return
                }
                next = self.flow.succeed(command)
            }
            if self.isStarted {
                self.detail = "在 AI 应用发送一条消息。"
                self.store?.onWorkspaceReady?()
            }
        }
    }

    private func execute(_ command: LaunchStepCommand) async -> String? {
        guard let store else { return "应用尚未准备好，请重新开启。" }
        switch command.step {
        case .grantPermissions:
            guard Self.meetsSystemRequirements else {
                return "需要 macOS 15 及以上，且为 Apple 芯片或 T2 芯片的 Mac，才能使用 iPhone 镜像。"
            }
            store.permissions.refresh()
            guard store.permissions.accessibilityGranted else {
                return "在系统设置中允许“Vibe Fishing”使用辅助功能。"
            }
        case .openAIClient:
            // Require at least one on-screen AI window. Minimized or hidden
            // windows cannot be scanned or arranged and must not silently
            // auto-pass; with none visible the step stays at the picker so the
            // user can open or restore one.
            store.refreshWindows()
            let visible = store.windows.filter { $0.liveFrame != nil }
            if visible.isEmpty {
                return "选择要使用的 AI 应用。"
            }
            if store.selectedWindowID.isEmpty || !visible.contains(where: { $0.id == store.selectedWindowID }) {
                let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
                let pick = visible.first(where: { $0.pid == frontPID }) ?? visible.first
                store.selectedWindowID = pick?.id ?? ""
            }
            if let pid = store.selectedWindow?.pid {
                agentApp = NSRunningApplication(processIdentifier: pid)
            }
        case .openPhoneMirror:
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ScreenContinuity") else {
                return "未找到 iPhone 镜像。需要 macOS 15 及以上。"
            }
            do {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                configuration.createsNewApplicationInstance = false
                configuration.promptsUserIfNeeded = false
                _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            } catch { return "未能打开 iPhone 镜像：\(error.localizedDescription)" }
            guard flow.canExecute(command), !Task.isCancelled else { return nil }
            guard AccessibilityProbe.isTrusted else { return "请先允许辅助功能。" }
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline, !Task.isCancelled, flow.canExecute(command) {
                if let window = store.dock.mirrorWindows().first {
                    if let blocker = Self.mirrorConnectionBlocker(window) { return blocker }
                    store.mirror.window = window
                    return nil
                }
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
            return "锁定 iPhone，在镜像中完成连接。若首次使用：确认两台设备登录同一 Apple 账户、连同一 Wi-Fi、蓝牙已开启。iPhone 重启后需先解锁一次再锁屏。"
        case .arrangeWindows:
            guard AccessibilityProbe.isTrusted else { return "请先允许辅助功能。" }
            guard let agentApp else { return "请打开 AI 应用或 Claude Code 所在的终端窗口，再重新连接。" }
            var candidates: [ClientWindow] = []
            for _ in 0..<5 {
                guard flow.canExecute(command), !Task.isCancelled else { return nil }
                store.refreshWindows()
                candidates = store.windows.filter { $0.pid == agentApp.processIdentifier }
                if !candidates.isEmpty { break }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            guard let initial = candidates.first(where: { $0.id == store.selectedWindowID }) ?? candidates.first else {
                return "无法读取 AI 或终端窗口。请确认辅助功能已授权。"
            }
            var selected = initial
            store.selectedWindowID = selected.id
            // A minimized agent window has no on-screen frame and cannot be
            // arranged; restoring it here keeps the step from blocking forever.
            if selected.liveFrame == nil {
                AXUIElementSetAttributeValue(selected.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                for _ in 0..<15 {
                    guard flow.canExecute(command), !Task.isCancelled else { return nil }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    store.refreshWindows()
                    if let fresh = store.windows.first(where: { $0.id == selected.id }), fresh.liveFrame != nil {
                        selected = fresh
                        break
                    }
                }
                guard selected.liveFrame != nil else {
                    return "AI 应用窗口是最小化的，自动恢复没有成功。点一下它在 Dock 里的图标显示窗口，再点继续。"
                }
            }
            guard let mirror = store.mirror.window else { return "镜像窗口已关闭。" }
            if autoArrangeWindows {
                let result = await store.dock.layoutSideBySide(agent: selected, mirror: mirror)
                if !result.success { return result.message }
            }
        case .openPreferredPhoneApp:
            if manuallyOpened { return nil }
            guard let window = store.mirror.window else { return "镜像窗口已断开，请重新连接。" }
            if let blocker = Self.mirrorConnectionBlocker(window) { return blocker }
            return "在镜像中打开竖屏短视频信息流，并开启自动连播。播放状态通过媒体音频信号判断；完全无声的视频可能无法在 AI 完成时自动暂停。"
        case .connectPlayback:
            if store.playback.kind == .local {
                guard store.playback.hasLocalVideos else { return "选择一部或多集本地视频。播放与暂停由播放器直接执行，状态由播放器自身回报。" }
                return nil
            }
            guard let window = store.mirror.window, window.liveFrame != nil else { return "镜像已断开，请重新连接。" }
            guard videoPageConfirmed else {
                return "请先打开短视频信息流。"
            }
            store.playback.changeKind(.mirror)
            store.mirror.supportsAutomaticPlayback = true
            store.mirror.useVideoCenter()
            store.mirror.setObservationEnabled(true)
            store.mirror.controlEnabled = true
            guard store.mirror.controlEnabled else { return store.mirror.message }
        case .startListening:
            if store.playback.kind == .mirror {
                guard let window = store.mirror.window, window.liveFrame != nil else { return "镜像已断开，请重新连接。" }
                if let blocker = Self.mirrorConnectionBlocker(window) { return blocker }
                store.mirror.setObservationEnabled(true)
                store.mirror.controlEnabled = true
            }
            if store.mode != .hooks { store.changeMode(.hooks) }
            store.hookSource = "codex"
            store.prepareConnectionPlayback()
            store.startListening()
            if !store.listening { return store.message }
        }
        return nil
    }

    /// iPhone Mirroring exists only on macOS 15+, and only on Apple Silicon
    /// or T2 Macs. Older systems fail early with one clear sentence.
    static var meetsSystemRequirements: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15
    }

    private static func codexURL() -> URL? {
        let bundleID = "com.openai.codex"
        for path in ["/Applications/Codex.app", "/Applications/ChatGPT.app"] {
            let named = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: named.path),
               let bundle = Bundle(url: named), bundle.bundleIdentifier == bundleID { return named }
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    /// Only the mirror's native connection/error chrome is read here. Phone
    /// content is not exposed through this AX tree and is not used as proof.
    private static func mirrorConnectionBlocker(_ window: ClientWindow) -> String? {
        let app = AXUIElementCreateApplication(window.pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var queue: [(AXUIElement, Int)] = [(app, 0)]
        var visited = 0
        while !queue.isEmpty && visited < 80 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            for key in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                var raw: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, key as CFString, &raw) == .success, let text = raw as? String {
                    if text.contains("iPhone使用中") || text.contains("iPhone 使用中") || text.contains("锁定iPhone") || text.localizedCaseInsensitiveContains("iPhone in use") {
                        return "请把 iPhone 锁屏，并在镜像中点连接，然后回来继续。"
                    }
                    let connectionEnded = ["连接超时", "连接已超时", "连接已中断", "连接已断开", "连接中断", "连接已结束", "已断开连接", "connection timed out", "connection ended", "connection interrupted", "disconnected"].contains { text.localizedCaseInsensitiveContains($0) }
                    if connectionEnded {
                        return "iPhone 镜像连接已中断或超时，请在镜像窗口重新连接。"
                    }
                    if text.contains("无法连接") || text.localizedCaseInsensitiveContains("unable to connect") {
                        return "iPhone 镜像暂时无法连接，请先在镜像窗口处理连接提示。"
                    }
                    if text.contains("镜像已锁定") || text.contains("使用触控ID") || text.localizedCaseInsensitiveContains("mirroring is locked") {
                        return "请在 iPhone 镜像中完成 Touch ID 解锁，然后回来继续。"
                    }
                }
            }
            if depth < 4 {
                var raw: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &raw) == .success, let children = raw as? [AXUIElement] {
                    queue.append(contentsOf: children.prefix(25).map { ($0, depth + 1) })
                }
            }
        }
        return nil
    }
}
