import AppKit
import Combine
import Darwin
import Dispatch
import Foundation
import RelayCore
import UniformTypeIdentifiers

enum SignalMode: String, CaseIterable, Identifiable {
    case hooks = "官方事件", accessibility = "界面探针", demo = "体验演示"
    var id: String { rawValue }
}

struct SignalRecord: Identifiable {
    let id = UUID()
    let date = Date()
    let state: AgentState
    let description: String
}

extension AgentState {
    var displayName: String {
        switch self {
        case .idle: return "等待生成"
        case .running: return "生成中"
        case .needsInput: return "等待确认"
        case .completed: return "已完成"
        case .failed: return "出错"
        case .cancelled: return "已取消"
        case .unknown: return "状态未知"
        }
    }
    var symbol: String {
        switch self {
        case .running: return "sparkles"
        case .needsInput: return "hand.raised.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "stop.circle"
        case .unknown: return "questionmark.circle"
        case .idle: return "moon.zzz"
        }
    }
}

@MainActor
final class RelayStore: ObservableObject {
    @Published var activeTab = 0
    @Published var mode: SignalMode = .hooks
    @Published var hookSource = "codex"
    @Published var state: AgentState = .idle
    @Published var listening = false
    @Published var windows: [ClientWindow] = []
    @Published var selectedWindowID = ""
    @Published var records: [SignalRecord] = []
    @Published var message = ""
    @Published var hookStatus = "尚未收到客户端事件"
    @Published var boundSession = ""
    @Published var probeReason = "未开始检测"
    @Published var probeControls: [String] = []
    @Published var trusted = false
    @Published var manuallyPaused = false
    @Published var strongReminder = UserDefaults.standard.object(forKey: "strongReminder") as? Bool ?? true {
        didSet { UserDefaults.standard.set(strongReminder, forKey: "strongReminder"); if !strongReminder { attention.dismiss() } }
    }
    @Published var soundReminder = UserDefaults.standard.bool(forKey: "soundReminder") {
        didSet { UserDefaults.standard.set(soundReminder, forKey: "soundReminder") }
    }
    @Published var companionVisible = false
    @Published var detailsVisible = true
    /// Session stats shown in the companion status strip.
    @Published private(set) var completedTurns = 0
    @Published private(set) var fishingSeconds: TimeInterval = 0
    private var videoPlaybackDuration = VideoPlaybackDuration()
    private var wasListening = false
    private var lastWindowsRefresh: TimeInterval = 0
    @Published var attachToWindow = true
    @Published var setupNotice = ""
    @Published var monitorStatus = "未检测到 AI 应用"
    let playback = PlaybackController()
    let mirror = MirrorController()
    let probe = AccessibilityProbe()
    let dock = WindowDock()
    let launch = LaunchCoordinator()
    let permissions = PermissionsController(readAudioCapture: { AudioCaptureVerification.isVerified })
    let attention = AttentionPresenter()
    let dataDirectory: URL
    let inbox: URL
    var onToggleCompanion: (() -> Void)?
    var onTickCompanion: (() -> Void)?
    /// Show the detail window from the companion strip.
    var onShowDetails: (() -> Void)?
    /// Close the detail window and return to the companion strip.
    var onHideDetails: (() -> Void)?
    var onWorkspaceReady: (() -> Void)?
    var onNeedsGuidance: (() -> Void)?
    private var hub = AgentActivityHub()
    private(set) var agentMonitor: AgentAppMonitor!
    private(set) var hooks: HookInstaller!
    private var attentionTarget: ClientWindow?
    private var clock: Timer?
    private var subscriptions = Set<AnyCancellable>()
    /// Auto-switches the connected AI when the user focuses another one.
    private var activationObserver: NSObjectProtocol?
    private var listenSince: TimeInterval = 0
    private var demoTurn = UUID().uuidString
    private var probeTurn = UUID().uuidString
    private var lastProbeState: AgentState = .idle
    private var lastPermissionCheck: TimeInterval = 0
    private var processedIDs = Set<String>()
    private let inboxWatcher = HookInboxDirectoryWatcher()
    private var inboxWatchGeneration: UInt64 = 0

    init() {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--data-dir"), args.indices.contains(i + 1) {
            dataDirectory = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        } else if let path = ProcessInfo.processInfo.environment["MOYU_RELAY_DATA_DIR"] {
            dataDirectory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            dataDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MoyuRelay", isDirectory: true)
        }
        inbox = ProcessInfo.processInfo.environment["MOYU_RELAY_INBOX"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? dataDirectory.appendingPathComponent("inbox", isDirectory: true)
        do { try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { setupNotice = "无法创建本地事件目录：\(error.localizedDescription)" }
        trusted = AccessibilityProbe.isTrusted
        agentMonitor = AgentAppMonitor(dataDirectory: dataDirectory)
        hooks = HookInstaller(dataDirectory: dataDirectory)
        hooks.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        agentMonitor.onEvent = { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.listening, self.mode != .demo else { return }
                self.consume(event)
            }
        }
        agentMonitor.onWindowGone = { [weak self] source, session in
            MainActor.assumeIsolated {
                self?.hub.remove(source: source, sessionID: session)
                self?.syncMirrorExpectation()
            }
        }
        agentMonitor.onStatus = { [weak self] status in
            MainActor.assumeIsolated { if self?.monitorStatus != status { self?.monitorStatus = status } }
        }
        launch.store = self
        launch.observePermissionChanges()
        launch.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        permissions.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        playback.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        mirror.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        playback.onEnded = { [weak self] in self?.message = "视频队列已播放完毕，下一次任务从第一集播放。" }
        playback.onFailure = { [weak self] text in self?.message = text }
        probe.onSample = { [weak self] sample in self?.receiveProbe(sample) }
        mirror.onPlaybackStalled = { [weak self] in
            guard let self else { return }
            self.message = "视频已停止。请在手机 App 中开启自动连播。"
        }
        clock = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        clock?.tolerance = 0.10
        refreshWindows()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, self.launch.isStarted,
                      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self.autoSwitchFocus(to: app)
            }
        }
    }

    var selectedWindow: ClientWindow? { windows.first { $0.id == selectedWindowID } }
    var sessionCaption: String { boundSession.isEmpty ? "下一次新任务将绑定到这里" : "已绑定会话 · \(boundSession.prefix(8))" }
    var needsAttention: Bool { [.completed, .needsInput, .failed, .cancelled].contains(state) }

    /// Extra desktop windows may be allowed locally for layout without being
    /// advertised or monitored as supported products. This keeps internal apps
    /// out of external builds while letting their own CLI hooks drive playback.
    var extraLayoutBundleIDs: [String] {
        let url = dataDirectory.appendingPathComponent("layout-clients.json")
        guard let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return values.filter { $0.contains(".") && !$0.contains("/") && !$0.contains(" ") }
    }

    /// Known window hosts for command-line agents; extra app bundle IDs are
    /// user-local configuration and are never added to the public AI monitor.
    var appWindowBundleIDs: [String] {
        let standard = AgentAppMonitor.standardClients.map(\.bundleID) + ["com.openai.ChatGPT", "com.apple.Terminal", "com.googlecode.iterm2"]
        let custom = agentMonitor.customClients.map(\.bundleID)
        return Array(Set(standard + custom + extraLayoutBundleIDs)).sorted()
    }

    func refreshWindows() {
        trusted = AccessibilityProbe.isTrusted
        guard trusted else { windows = []; return }
        let currentID = selectedWindowID
        windows = probe.windows(bundleIDs: appWindowBundleIDs)
        if windows.contains(where: { $0.id == currentID }) { selectedWindowID = currentID }
        else { selectedWindowID = windows.count == 1 ? windows[0].id : "" }
    }

    /// One click in the picker: pick this window and immediately continue
    /// the blocked step. No second click needed.
    func selectRelayWindow(_ id: String) {
        guard launch.flow.status == .blocked, launch.flow.currentStep == .openAIClient else { return }
        selectedWindowID = id
        bringSelectedClientForward()
        launch.advanceCurrentStep()
    }

    /// Picking a window should put that app on screen right away, with the
    /// Vibe Fishing window staying above it.
    private func bringSelectedClientForward() {
        guard let window = windows.first(where: { $0.id == selectedWindowID }),
              let app = NSRunningApplication(processIdentifier: window.pid) else { return }
        app.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Adds any installed app the user chooses. It joins window layout and
    /// generation scanning; its stop-button labels are unknown until tested.
    func addCustomClient() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.application]
        panel.message = "选择要接入的 AI 应用"
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        var ids = UserDefaults.standard.stringArray(forKey: "customClientBundleIDs.v1") ?? []
        guard !ids.contains(bundleID) else { return }
        ids.append(bundleID)
        UserDefaults.standard.set(ids, forKey: "customClientBundleIDs.v1")
        refreshWindows()
    }

    func removeCustomClient(bundleID: String) {
        var ids = UserDefaults.standard.stringArray(forKey: "customClientBundleIDs.v1") ?? []
        ids.removeAll { $0 == bundleID }
        UserDefaults.standard.set(ids, forKey: "customClientBundleIDs.v1")
        refreshWindows()
    }

    func requestAccessibility() {
        permissions.requestAccessibility()
        message = "在系统设置中允许“Vibe Fishing”，然后回来点刷新"
    }

    /// Every source listens at once: official hooks from command-line agents
    /// and the window observer for ChatGPT / Codex, Claude and Cursor.
    /// The user never has to say which app or mode a message was sent from.
    func startListening() {
        stopListening()
        listenSince = Date().timeIntervalSince1970
        boundSession = ""
        state = .idle
        listening = true
        launch.listeningChanged(true)
        if mode == .demo {
            message = "演示已就绪，点“AI 开工”体验接力"
            return
        }
        startInboxWatcher()
        agentMonitor.start()
        message = "等待 AI 生成"
        // Video state is a pure function of agent state from the first second:
        // give the monitor one scan to see an agent that is already thinking
        // (that fires .play itself); if nothing is thinking, force a pause.
        let session = listenSince
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.listening, self.listenSince == session else { return }
            self.reconcilePlayback()
        }
    }

    func stopListening() {
        inboxWatchGeneration &+= 1
        inboxWatcher.stop()
        attention.dismiss()
        probe.stop()
        agentMonitor.stop()
        listening = false
        mirror.cancelPendingRequest()
        launch.listeningChanged(false)
        apply(hub.reset())
        playback.pause()
        state = .idle
        manuallyPaused = hub.manuallyPaused
        syncMirrorExpectation()
    }

    func changeMode(_ newMode: SignalMode) {
        stopListening()
        mode = newMode
        boundSession = ""
        message = newMode == .demo ? "虚构分镜用于验证体验，不代表已接通客户端" : "选择信号来源后开始监听"
    }

    func simulate(_ next: AgentState) {
        if mode != .demo { changeMode(.demo) }
        if !listening { startListening() }
        if next == .running, state != .needsInput, state != .unknown { demoTurn = UUID().uuidString }
        consume(AgentEvent(id: UUID().uuidString, source: "demo", sessionID: "demo-session", turnID: demoTurn, state: next, timestamp: Date().timeIntervalSince1970))
    }

    func toggleUserPause() {
        let pause = !manuallyPaused
        apply(hub.setManualPaused(pause))
        manuallyPaused = hub.manuallyPaused
        if pause { playback.pause() }
        message = pause ? "已暂停自动播放" : "已恢复自动播放"
    }

    func choosePlayback(_ kind: PlaybackKind) {
        guard kind != playback.kind else { return }
        launch.stop()
        playback.changeKind(kind)
        apply(hub.setManualPaused(true))
        manuallyPaused = true
        message = "已切换播放器，点击连接重新准备"
    }

    /// Clicking Connect explicitly begins a fresh automatic playback session.
    /// There is no play side effect until a new accepted running event arrives.
    func prepareConnectionPlayback() {
        if playback.kind == .mirror { _ = hub.reset() } else { apply(hub.reset()) }
        _ = hub.setManualPaused(false)
        manuallyPaused = false
    }

    private func receiveProbe(_ sample: ProbeSample) {
        // The single-window probe is superseded by AgentAppMonitor; samples are
        // kept only as diagnostics.
        probeReason = sample.reason
        probeControls = sample.controls
    }

    func consume(_ event: AgentEvent) {
        let key = AgentActivityHub.Key(source: event.source, sessionID: event.sessionID)
        let before = hub.entries[key]
        let actions = hub.consume(event, now: Date().timeIntervalSince1970)
        let after = hub.entries[key]
        // Duplicates, stale tails and other rejected events change nothing visible.
        guard let after, after != before, after.state == event.state,
              before?.state != after.state || before?.turnID != after.turnID else { return }
        let name = Self.sourceName(event.source)
        state = focusedAgentState
        boundSession = name
        manuallyPaused = hub.manuallyPaused
        if mode != .demo { launch.recordAgentEvent() }
        if event.state == .running { attention.dismiss() }
        if [.completed, .needsInput, .failed].contains(event.state) {
            attentionTarget = window(for: event.source, sessionID: event.sessionID)
        }
        records.insert(SignalRecord(state: event.state, description: mode == .demo ? "演示信号" : name), at: 0)
        records = Array(records.prefix(12))
        switch event.state {
        case .running:
            message = "\(name) 生成中"
        case .needsInput:
            message = "\(name) 等待确认"
        case .completed:
            message = "\(name) 已完成"
        case .failed:
            message = "\(name) 出错"
        default:
            message = event.state.displayName
        }
        // Reminders still come from every app; play/pause only from the agent
        // the user is looking at.
        apply(actions.filter { if case .requestAttention = $0 { return true }; return false })
        reconcilePlayback()
    }

    /// Video follows exactly one agent: the selected AI app, which follows
    /// focus. Command-line hook sources have no window and always count.
    private func countsForPlayback(_ source: String) -> Bool {
        guard source.hasPrefix(AgentAppMonitor.sourcePrefix),
              let bundle = selectedWindow?.bundleID, !bundle.isEmpty else { return true }
        return source == AgentAppMonitor.sourcePrefix + bundle
    }

    var focusedAgentRunning: Bool {
        !hub.manuallyPaused && hub.entries.contains { countsForPlayback($0.key.source) && $0.value.state == .running }
    }

    private var focusedAgentState: AgentState {
        let relevant = hub.entries.filter { countsForPlayback($0.key.source) }
        if relevant.values.contains(where: { $0.state == .running }) { return .running }
        return relevant.values.max { $0.updatedAt < $1.updatedAt }?.state ?? .idle
    }

    /// The absolute rule: focused agent thinking = play, otherwise pause.
    /// Called on every accepted event, focus switch and connection start.
    func reconcilePlayback() {
        guard listening else { return }
        state = focusedAgentState
        apply([focusedAgentRunning ? .play : .pause])
        syncMirrorExpectation()
    }

    /// Removes everything the app added outside its bundle, then moves the app
    /// to the Trash. Config backups (`*.moyu-backup-*`) are kept: they are the
    /// user's own settings.
    func uninstallEverything() {
        let alert = NSAlert()
        alert.messageText = "卸载 Vibe Fishing"
        alert.informativeText = "将移除命令行工具中的接力设置、本地数据和系统授权记录，并把应用移到废纸篓。"
        alert.addButton(withTitle: "卸载")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        launch.stop()
        let failures = hooks.uninstallAll()
        let standard = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MoyuRelay", isDirectory: true)
        if dataDirectory.standardizedFileURL == standard.standardizedFileURL {
            try? FileManager.default.removeItem(at: dataDirectory)
        }
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
            for service in ["Accessibility", "AudioCapture", "ScreenCapture"] {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
                process.arguments = ["reset", service, bundleID]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try? process.run()
                process.waitUntilExit()
            }
        }
        if !failures.isEmpty {
            let warning = NSAlert()
            warning.messageText = "部分设置未能移除"
            warning.informativeText = "请手动检查：" + failures.joined(separator: "、")
            warning.runModal()
        }
        NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    static func sourceName(_ source: String) -> String {
        if source.hasPrefix(AgentAppMonitor.sourcePrefix) {
            let bundle = String(source.dropFirst(AgentAppMonitor.sourcePrefix.count))
            let name = AgentAppMonitor.standardClients.first { $0.bundleID == bundle }?.name
                ?? (NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
                    .flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String })
                ?? "AI 应用"
            return name
        }
        switch source {
        case "codex": return "Codex"
        case "claude": return "Claude Code"
        case "demo": return "演示"
        default: return source
        }
    }

    /// The window that finished, so the reminder points at the right app.
    private func window(for source: String, sessionID: String) -> ClientWindow? {
        let bundle: String?
        if source.hasPrefix(AgentAppMonitor.sourcePrefix) {
            bundle = String(source.dropFirst(AgentAppMonitor.sourcePrefix.count))
            if let exact = windows.first(where: { $0.id == sessionID }) { return exact }
            refreshWindows()
            if let exact = windows.first(where: { $0.id == sessionID }) { return exact }
        } else {
            bundle = source == "codex" ? "com.openai.codex" : nil
        }
        guard let bundle else { return nil }
        if let selected = selectedWindow, selected.bundleID == bundle { return selected }
        if !windows.contains(where: { $0.bundleID == bundle }) { refreshWindows() }
        return windows.first { $0.bundleID == bundle }
    }

    /// One-line stats strip for the companion panel.
    var companionStatsLine: String {
        let minutes = Int(fishingSeconds) / 60, seconds = Int(fishingSeconds) % 60
        return "已摸鱼 \(String(format: "%d:%02d", minutes, seconds)) · \(completedTurns) 轮"
    }

    /// Switch the connected AI window from the companion strip at any time.
    func switchRelayWindow(_ id: String) {
        guard id != selectedWindowID, windows.contains(where: { $0.id == id }) else { return }
        selectedWindowID = id
        bringSelectedClientForward()
        launch.rearrangeLayout()
        reconcilePlayback()
    }

    /// When the user focuses another connected AI app, follow silently:
    /// update the anchor without moving any windows.
    private func autoSwitchFocus(to app: NSRunningApplication) {
        guard let window = windows.first(where: { $0.pid == app.processIdentifier }),
              window.id != selectedWindowID else { return }
        let previousBundle = selectedWindow?.bundleID
        selectedWindowID = window.id
        if window.bundleID != previousBundle { reconcilePlayback() }
    }

    /// Lets the mirror tell a finished video apart from a pause it asked for.
    private func syncMirrorExpectation() {
        mirror.agentWorking = listening && focusedAgentRunning
    }

    private func apply(_ actions: [RelayAction]) {
        for action in actions {
            switch action {
            case .play:
                if playback.kind == .mirror {
                    if listening { mirror.request(.playing) }
                } else { playback.play() }
            case .pause:
                if playback.kind == .mirror {
                    if listening { mirror.request(.paused) }
                } else { playback.pause() }
            case .requestAttention:
                completedTurns += 1
                if strongReminder { presentAttention() }
            }
        }
    }

    /// Preview is deliberately isolated from playback and AI window operations.
    func previewAttention() {
        guard let window = NSApp.windows.first(where: { !($0 is NSPanel) && $0.isVisible }) else { return }
        attention.preview(frame: window.frame, allowSound: soundReminder)
    }

    private func presentAttention() {
        if mode == .demo { previewAttention(); return }
        if !attention.show(kind: state, target: attentionTarget ?? selectedWindow, allowSound: soundReminder) {
            message = "AI 窗口不可见，未显示提醒"
        }
    }

    func returnToClient() {
        attention.dismiss()
        guard let target = attentionTarget ?? selectedWindow else { message = "请先绑定一个客户端窗口"; return }
        Task { [weak self] in
            guard let self else { return }
            if !(await self.dock.focusForInteraction(target)) {
                self.message = "未能返回目标窗口，请检查窗口是否仍打开"
            }
        }
    }

    private func tick() {
        playback.tick()
        mirror.tick()
        launch.tick()
        let now = Date().timeIntervalSince1970
        if listening && !wasListening {
            completedTurns = 0
            videoPlaybackDuration.reset()
            fishingSeconds = 0
        }
        wasListening = listening
        fishingSeconds = videoPlaybackDuration.sample(
            playing: listening && launch.isStarted && mirror.isObservedVideoPlaying,
            uptime: ProcessInfo.processInfo.systemUptime
        )
        if launch.isStarted && !detailsVisible && !companionVisible { onToggleCompanion?() }
        if launch.isStarted, now - lastWindowsRefresh > 5 {
            lastWindowsRefresh = now
            refreshWindows()
        }
        if now - lastPermissionCheck > 2 {
            permissions.refresh()
            let newTrust = AccessibilityProbe.isTrusted
            if newTrust != trusted {
                trusted = newTrust
                refreshWindows()
                mirror.accessibilityTrustDidChange()
            }
            lastPermissionCheck = now
        }
        if listening {
            hub.tick(now: now)
            syncMirrorExpectation()
        }
        onTickCompanion?()
    }

    private func startInboxWatcher() {
        inboxWatchGeneration &+= 1
        let generation = inboxWatchGeneration
        do {
            // An explicit retry can restore a removed inbox. There is no
            // background recreation loop after the watcher reports a loss.
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // The directory source is installed before the initial read. Later
            // reads happen only when entries change, never from the UI timer.
            try inboxWatcher.start(at: inbox) { [weak self] change in
                guard let self, self.inboxWatchGeneration == generation,
                      self.listening, self.mode == .hooks else { return }
                switch change {
                case .contentsChanged:
                    self.readInbox()
                case .directoryUnavailable:
                    self.stopListening()
                    self.hookStatus = "事件目录已移动、删除或不可用，监听已停止"
                    self.message = "请恢复事件目录后重新开启监听；不会自动反复重试"
                    self.launch.interruptConnection(at: .startListening, reason: "任务信号中断，接力已暂停。请在这里重试连接；恢复后会重新验证一次真实任务。")
                }
            }
        } catch {
            stopListening()
            hookStatus = "无法监听本地事件目录"
            message = "事件目录不可用，请检查后重新开启监听（\(error.localizedDescription)）"
        }
    }

    private func readInbox() {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { return }
        var events: [(URL, AgentEvent)] = []
        for url in urls.filter({ $0.pathExtension == "json" }).prefix(256) {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true,
                  (values.fileSize ?? Int.max) <= 16_384,
                  let data = try? Data(contentsOf: url), let event = try? JSONDecoder().decode(AgentEvent.self, from: data) else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            events.append((url, event))
        }
        for (url, event) in events.sorted(by: { $0.1.timestamp < $1.1.timestamp }) {
            defer { try? FileManager.default.removeItem(at: url) }
            // Any agent bridged through relayctl counts; the user does not pick one.
            guard event.timestamp >= listenSince, event.source != "demo", !processedIDs.contains(event.id) else { continue }
            processedIDs.insert(event.id)
            if processedIDs.count > 2000 { processedIDs = [event.id] }
            hookStatus = "已收到事件 · \(Date().formatted(date: .omitted, time: .standard))"
            consume(event)
        }
    }

    func revealHookInstructions() {
        let readme = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/HOOKS.md")
        if FileManager.default.fileExists(atPath: readme.path) { NSWorkspace.shared.open(readme) }
        else { setupNotice = "接入说明在发布目录的“开始使用.txt”与源代码 docs/HOOKS.md 中" }
    }

    func revealInbox() { NSWorkspace.shared.open(inbox) }

    func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "VibeFishing-诊断.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let payload: [String: Any] = ["version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development", "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development", "mode": mode.rawValue, "state": state.rawValue,
            "playbackKind": playback.kind.rawValue, "playbackObservedState": playback.observedStateCaption,
            "accessibilityGranted": trusted, "clientBundle": selectedWindow?.bundleID ?? "", "probeReason": probeReason,
            "controls": probeControls, "eventCount": records.count, "mirrorState": mirror.stateLabel,
            "mirrorControl": mirror.diagnosticSummary,
            "recentAgentStates": records.map { ["time": String($0.date.timeIntervalSince1970), "state": $0.state.rawValue] },
            "containsChatContent": false]
        do { try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic); message = "诊断已导出，不包含聊天正文" }
        catch { message = "导出失败：\(error.localizedDescription)" }
    }

    deinit {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }
}

/// Owns only a directory descriptor and its Dispatch source. No repeating timer,
/// capture, or application interaction is involved. Kept separate from the store
/// so the actual watcher can be exercised against an isolated temporary folder.
@MainActor
private final class HookInboxDirectoryWatcher {
    enum Change { case contentsChanged, directoryUnavailable }

    private var source: DispatchSourceFileSystemObject?
    private var descriptor: Int32?
    private var directory: URL?
    private var callback: ((Change) -> Void)?
    private var generation: UInt64 = 0
    private var pendingEvents: DispatchSource.FileSystemEvent = []
    private var deliveryTask: Task<Void, Never>?

    func start(at directory: URL, onChange: @escaping (Change) -> Void) throws {
        stop()
        let fd = open(directory.path, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var details = stat()
        guard fstat(fd, &details) == 0, (details.st_mode & S_IFMT) == S_IFDIR else {
            close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTDIR))
        }
        let watcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .revoke], queue: .main)
        let token = generation
        watcher.setEventHandler { [weak self, weak watcher] in
            guard let events = watcher?.data else { return }
            // The source explicitly targets DispatchQueue.main. Read its data
            // in the handler, before Dispatch resets the coalesced event bits.
            MainActor.assumeIsolated { self?.enqueue(events, generation: token) }
        }
        // Closing on cancellation, rather than immediately in stop(), ensures
        // Dispatch cannot refer to a descriptor already reused by a new watcher.
        watcher.setCancelHandler { close(fd) }
        descriptor = fd
        self.directory = directory
        callback = onChange
        source = watcher
        watcher.resume()
        deliver([], generation: token)
    }

    func stop() {
        generation &+= 1
        deliveryTask?.cancel()
        deliveryTask = nil
        pendingEvents = []
        source?.cancel()
        source = nil
        descriptor = nil
        directory = nil
        callback = nil
    }

    private func enqueue(_ events: DispatchSource.FileSystemEvent, generation token: UInt64) {
        guard generation == token, source != nil else { return }
        pendingEvents.formUnion(events)
        guard deliveryTask == nil else { return }
        deliveryTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, self.generation == token else { return }
            let events = self.pendingEvents
            self.pendingEvents = []
            self.deliveryTask = nil
            self.deliver(events, generation: token)
        }
    }

    private func deliver(_ events: DispatchSource.FileSystemEvent, generation token: UInt64) {
        guard generation == token, source != nil, let callback else { return }
        if !events.intersection([.rename, .delete, .revoke]).isEmpty || !isSameDirectory() {
            stop()
            callback(.directoryUnavailable)
        } else {
            callback(.contentsChanged)
        }
    }

    /// Also catches replacement between source installation and its first event;
    /// never read a new directory through a watcher bound to the old inode.
    private func isSameDirectory() -> Bool {
        guard let descriptor, let directory else { return false }
        var opened = stat(), current = stat()
        return fstat(descriptor, &opened) == 0 && lstat(directory.path, &current) == 0
            && (current.st_mode & S_IFMT) == S_IFDIR
            && opened.st_dev == current.st_dev && opened.st_ino == current.st_ino
    }

    deinit {
        deliveryTask?.cancel()
        source?.cancel()
    }
}
