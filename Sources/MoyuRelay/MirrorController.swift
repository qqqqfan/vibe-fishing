import AppKit
import ApplicationServices
import Combine
import RelayCore

/// Local, content-free operation log. Holds timings and signal numbers only.
@MainActor
enum RelayTraceLog {
    private static let maximumBytes: UInt64 = 512 * 1024
    private static var handle: FileHandle?
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MoyuRelay/relay-trace.jsonl")

    static func write(_ entry: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        if handle == nil { open() }
        guard let handle else { return }
        try? handle.write(contentsOf: data + Data([0x0A]))
        if let size = try? handle.offset(), size > maximumBytes {
            try? handle.close()
            self.handle = nil
            let previous = url.deletingPathExtension().appendingPathExtension("previous.jsonl")
            try? FileManager.default.removeItem(at: previous)
            try? FileManager.default.moveItem(at: url, to: previous)
        }
    }

    private static func open() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }
}

@MainActor
final class MirrorController: ObservableObject {
    static let automaticControlAvailable = true
    enum KnownState: String { case unknown = "读取中", playing = "播放中", paused = "已暂停" }
    @Published var window: ClientWindow? {
        didSet {
            if oldValue?.id != window?.id {
                supportsAutomaticPlayback = false
                invalidateControl(reason: "镜像绑定已变化，请确认已打开视频页")
                refreshSensor()
            }
        }
    }
    @Published private(set) var knownState: KnownState = .unknown
    @Published var point: CGPoint? {
        didSet { if oldValue != point { invalidateControl(reason: "触点已更新") } }
    }
    @Published var countdown = 0
    @Published var message = ""
    @Published var supportsAutomaticPlayback = false {
        didSet {
            if oldValue && !supportsAutomaticPlayback {
                controlEnabled = false
                invalidateControl(reason: "视频页面尚未确认，自动播控已停止")
            }
        }
    }
    @Published var controlEnabled = false {
        didSet {
            if controlEnabled && (!Self.automaticControlAvailable || !observationEnabled || !AccessibilityProbe.isTrusted || !supportsAutomaticPlayback || point == nil || window == nil) {
                controlEnabled = false
                invalidateControl(reason: "请先确认视频页、设置触点，并开启辅助功能")
            } else if oldValue && !controlEnabled {
                invalidateControl(reason: "自动播控已关闭")
            }
        }
    }
    @Published private(set) var observationEnabled = false
    @Published private(set) var isInspecting = false
    @Published private(set) var audioHealth: MirrorPlaybackSensor.AudioHealth = .unknown
    @Published private(set) var observationReason = "连接后持续读取镜像的声音与画面流强度，不截图"
    @Published private(set) var desiredState: KnownState?
    private(set) var lastInputDiagnostics = ""
    /// Set by the store: at least one AI turn is running and playback is wanted.
    var agentWorking = false
    /// The video stopped by itself while AI is working (usually no auto-next).
    var onPlaybackStalled: (() -> Void)?
    private var lastManualMirrorInputAt: TimeInterval = -.infinity
    private var lastKeyDownAt: TimeInterval = -.infinity
    private var stallReportedFor: TimeInterval = -.infinity
    /// Resume attempts in a row that produced no sound. Two in a row mean the
    /// stored audio-permission proof is probably stale.
    private var silentResumes = 0
    private var operationTrace: [[String: String]] = []
    private var lastObservation: [String: String] = [:]
    var onPauseHandled: (() -> Void)?

    private let dock = WindowDock()
    private let sensor = MirrorPlaybackSensor()
    private var calibrationTimer: Timer?
    private var toggle = MirrorToggleState()
    private var interactionTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var inputMonitor: Any?
    private var functionKeyMonitor: Any?
    private var localFunctionKeyMonitor: Any?
    private var functionKeyDown = false
    @Published var recordingShortcut = false
    @Published private(set) var shortcutLabel = UserDefaults.standard.string(forKey: "playbackShortcut.label") ?? "Fn"

    func savePlaybackShortcut(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 { recordingShortcut = false; return true }
        if event.keyCode == 51 {
            UserDefaults.standard.set(-1, forKey: "playbackShortcut.key")
            shortcutLabel = "未设置"
        } else if event.keyCode == 63 && event.modifierFlags.contains(.function) {
            UserDefaults.standard.removeObject(forKey: "playbackShortcut.key")
            shortcutLabel = "Fn"
        } else {
            guard event.type == .keyDown, !event.isARepeat else { return false }
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard !flags.intersection([.command, .control, .option]).isEmpty else { return false }
            UserDefaults.standard.set(Int(event.keyCode), forKey: "playbackShortcut.key")
            UserDefaults.standard.set(Int(flags.rawValue), forKey: "playbackShortcut.flags")
            UserDefaults.standard.set(event.charactersIgnoringModifiers, forKey: "playbackShortcut.characters")
            shortcutLabel = PlaybackShortcutLabel.format(code: event.keyCode, flags: flags.rawValue, characters: event.charactersIgnoringModifiers)
        }
        UserDefaults.standard.set(shortcutLabel, forKey: "playbackShortcut.label")
        recordingShortcut = false
        functionKeyDown = false
        return true
    }

    func restorePlaybackShortcut() {
        UserDefaults.standard.removeObject(forKey: "playbackShortcut.key")
        UserDefaults.standard.set("Fn", forKey: "playbackShortcut.label")
        shortcutLabel = "Fn"
        recordingShortcut = false
    }
    private var lastClickAt: TimeInterval = -.infinity
    private var manualInputDuringRequest = false
    /// Latest playback intent received while the mirror is minimized/hidden.
    private var deferredTarget: KnownState?
    /// True while the user appears to be using the mirrored phone for
    /// something other than the video feed: playback clicks are skipped,
    /// attention reminders still fire. Cleared as soon as audio returns.
    @Published private(set) var userTakeover = false
    private var takeoverProbe: Task<Void, Never>?
    private var takeoverWatch: Task<Void, Never>?
    private static let syntheticEventTag: Int64 = 0x4D4F5955
    /// Douyin treats two quick taps as a like. Also lets the previous tap's
    /// effect reach the signals before a new decision reads them.
    private static let clickSpacing: TimeInterval = 1.0
    private static let decisionTimeout: TimeInterval = 2.7
    private static let verificationTimeout: TimeInterval = 2.0
    private static let stallDelay: TimeInterval = 3.0
    private static let stallExplainedWithin: TimeInterval = 3.0
    /// Taking focus mid-sentence would swallow characters and move the
    /// cursor. Defer until the user truly finishes composing: either they
    /// send the message (Enter / Shift+Enter) or stop typing for a real
    /// break. Long cap so a lengthy composition doesn't lose the pause.
    private static let typingQuietPeriod: TimeInterval = 2.0
    private static let typingMaximumWait: TimeInterval = 15.0
    /// Set when the last key the user pressed was Enter/Return — the
    /// "message sent" signal that means it's safe to take focus.
    private var lastKeyWasEnter = false

    init() {
        let defaults = UserDefaults.standard
        if let code = defaults.object(forKey: "playbackShortcut.key") as? Int,
           let key = UInt16(exactly: code) {
            let fallback = (defaults.string(forKey: "playbackShortcut.label") ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "⌃⌥⇧⌘"))
            shortcutLabel = PlaybackShortcutLabel.format(code: key, flags: UInt(defaults.integer(forKey: "playbackShortcut.flags")), characters: defaults.string(forKey: "playbackShortcut.characters") ?? fallback)
            defaults.set(shortcutLabel, forKey: "playbackShortcut.label")
        }
        installInputMonitorIfNeeded()
        sensor.onChange = { [weak self] reading in self?.sensorChanged(reading) }
        sensor.onAudioHealthChange = { [weak self] health in self?.audioHealth = health }
    }

    /// A bare Fn press toggles only while mirror automation is connected. The
    /// monitor is passive: macOS may also perform the Fn action configured in
    /// Keyboard settings.
    private func handleFunctionKey(_ event: NSEvent) {
        guard !recordingShortcut else { return }
        let defaults = UserDefaults.standard
        if let key = defaults.object(forKey: "playbackShortcut.key") as? Int {
            guard key >= 0, event.type == .keyDown, !event.isARepeat, Int(event.keyCode) == key else { return }
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard Int(flags.rawValue) == defaults.integer(forKey: "playbackShortcut.flags") else { return }
        } else {
            guard event.keyCode == 63 else { return }
            let pressed = event.modifierFlags.contains(.function)
            defer { functionKeyDown = pressed }
            guard pressed, !functionKeyDown, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return }
        }
        guard controlEnabled, !toggle.hasActiveRequest, !isInspecting else { return }
        let target: KnownState
        switch sensor.reading.state {
        case .playing: target = .paused
        case .paused: target = .playing
        case .unknown:
            message = "播放状态读取中"
            return
        }
        // An explicit playback shortcut is the user's direct override.
        // Clear a stale takeover first; otherwise silent/muted video can keep
        // takeover active forever and block both this shortcut and later AI events.
        clearTakeover()
        _ = request(target)
    }

    /// Accessibility may be granted after the app launches (for example after
    /// a TCC reset). Reinstall global/local shortcut monitors at that point.
    func accessibilityTrustDidChange() {
        guard AccessibilityProbe.isTrusted else { return }
        installInputMonitorIfNeeded()
    }

    private func installInputMonitorIfNeeded() {
        guard Self.automaticControlAvailable else { return }
        guard inputMonitor == nil, AccessibilityProbe.isTrusted else { return }
        inputMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .scrollWheel, .keyDown]) { [weak self] event in
            // Capture focus when the event arrives, before queued actor work or
            // an activation changes it. Mouse-up covers the activation click.
            let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            MainActor.assumeIsolated { self?.handleExternalInput(event, frontPID: frontPID) }
        }
        functionKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handleFunctionKey(event) }
        }
        // Global monitors do not receive events from this app itself.
        localFunctionKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            let consume: Bool = MainActor.assumeIsolated {
                guard let self else { return false }
                if self.recordingShortcut {
                    _ = self.savePlaybackShortcut(event)
                    return event.type == .keyDown
                }
                self.handleFunctionKey(event)
                return false
            }
            return consume ? nil : event
        }
    }

    deinit {
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        if let functionKeyMonitor { NSEvent.removeMonitor(functionKeyMonitor) }
        if let localFunctionKeyMonitor { NSEvent.removeMonitor(localFunctionKeyMonitor) }
        calibrationTimer?.invalidate()
        interactionTask?.cancel()
    }

    /// Read the observed media state, not the requested playback intent.
    var isObservedVideoPlaying: Bool {
        controlEnabled && !userTakeover && sensor.reading.state == .playing
    }

    var stateLabel: String {
        if isInspecting { return "切换中" }
        return knownState.rawValue
    }

    func setObservationEnabled(_ enabled: Bool) {
        guard enabled else {
            observationEnabled = false
            controlEnabled = false
            invalidateControl(reason: "播放状态读取已关闭，自动播控已停止")
            refreshSensor()
            return
        }
        observationEnabled = true
        observationReason = "持续读取镜像的声音与画面流强度；不截图、不录音、不保存"
        refreshSensor()
    }

    private func refreshSensor() {
        if observationEnabled, let window { sensor.start(pid: window.pid) }
        else {
            sensor.stop()
            knownState = .unknown
        }
    }

    private func sensorChanged(_ reading: MirrorPlaybackSensor.Reading) {
        let state = Self.uiState(reading.state)
        if state != knownState {
            knownState = state
            RelayTraceLog.write(sensorEntry("sensor_state"))
        }
    }

    /// Vertical feeds toggle playback on a tap anywhere near the centre.
    func useVideoCenter() {
        guard window != nil else { findWindow(); return }
        point = CGPoint(x: 0.5, y: 0.47)
    }

    /// A pause that no click and no manual input explains, lasting seconds while
    /// AI works, means the video itself stopped. Reported once; never clicked,
    /// because a tap on a finished video can do something other than resume.
    private func checkForStall() {
        guard agentWorking, observationEnabled, !mirrorIsTucked, !isInspecting, !toggle.hasActiveRequest else { return }
        let reading = sensor.reading
        guard reading.state == .paused, !reading.settling, reading.strong,
              reading.changedAt != stallReportedFor else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - reading.changedAt >= Self.stallDelay,
              reading.changedAt - lastClickAt > Self.stallExplainedWithin,
              reading.changedAt - lastManualMirrorInputAt > Self.stallExplainedWithin else { return }
        stallReportedFor = reading.changedAt
        trace("playback_stalled", details: sensor.summary)
        onPlaybackStalled?()
    }

    func tick() {
        if mirrorIsTucked {
            if toggle.hasActiveRequest, let pending = desiredState {
                deferredTarget = pending
                invalidateControl(reason: "镜像已收起，恢复后继续播放控制")
            }
            return
        }
        if let pending = deferredTarget {
            deferredTarget = nil
            _ = request(pending)
            return
        }
        checkForStall()
        guard isInspecting || toggle.hasActiveRequest else { return }
        let now = Date().timeIntervalSince1970
        if (controlEnabled || isInspecting), !AccessibilityProbe.isTrusted {
            controlEnabled = false
            invalidateControl(reason: "辅助功能授权失效，自动控制已停止")
            return
        }
        if let window, window.liveFrame == nil {
            invalidateControl(reason: "镜像窗口已失效，未继续点击")
            return
        }
        let hadRequest = toggle.hasActiveRequest
        _ = toggle.tick(now: now)
        if hadRequest && !toggle.hasActiveRequest {
            invalidateControl(reason: "切换超时")
        }
    }

    func findWindow() {
        calibrationTimer?.invalidate()
        countdown = 0
        invalidateControl(reason: "正在寻找镜像窗口")
        window = dock.mirrorWindows().first
        point = nil
        controlEnabled = false
        message = window == nil ? "还没找到镜像窗口：\(dock.lastMirrorDiagnostics)" : "已找到镜像窗口，请校准播放／暂停触点"
    }

    func calibrate() {
        guard window != nil else { findWindow(); return }
        invalidateControl(reason: "把鼠标移到播放器的播放／暂停触点，3 秒后记录位置")
        calibrationTimer?.invalidate()
        countdown = 3
        calibrationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                self.countdown -= 1
                if self.countdown <= 0 {
                    timer.invalidate()
                    self.capturePoint()
                }
            }
        }
    }

    private func currentFrame(_ window: ClientWindow) -> CGRect? {
        guard let frame = window.liveFrame, frame.width > 50, frame.height > 50 else { return nil }
        return frame
    }

    private func capturePoint() {
        guard let window, let frame = currentFrame(window) else { message = "镜像窗口不可用，请重新连接"; return }
        let mouse = NSEvent.mouseLocation
        let originHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let location = CGPoint(x: mouse.x, y: originHeight - mouse.y)
        guard frame.insetBy(dx: 8, dy: 28).contains(location) else {
            message = "鼠标不在镜像内容区域，请重新校准"
            return
        }
        point = CGPoint(x: (location.x - frame.minX) / frame.width, y: (location.y - frame.minY) / frame.height)
        invalidateControl(reason: "触点已记录；请确认已打开视频页")
    }

    /// True while iPhone Mirroring is minimized or its app is hidden.
    private var mirrorIsTucked: Bool {
        guard let window,
              let app = NSRunningApplication(processIdentifier: window.pid), !app.isTerminated else { return false }
        if app.isHidden { return true }
        var minimized: CFTypeRef?
        return AXUIElementCopyAttributeValue(window.element, kAXMinimizedAttribute as CFString, &minimized) == .success
            && (minimized as? Bool) == true
    }

    private func canObserve() -> Bool {
        guard Self.automaticControlAvailable else {
            message = "镜像使用手动播放；不会自动点击" 
            return false
        }
        guard supportsAutomaticPlayback else { message = "请先确认镜像已打开视频页"; return false }
        guard observationEnabled else { message = "播放状态读取尚未开启"; return false }
        guard let window, point != nil, currentFrame(window) != nil else {
            invalidateControl(reason: "镜像窗口或触点不可用，请重新连接")
            return false
        }
        return true
    }

    /// Edge-triggered: called once per Codex transition, never to keep enforcing
    /// a state, so a video you pause by hand stays paused until the next event.
    /// An opposite intent cancels older work; the latest intent always wins.
    /// Scrolls down at the feed center to advance to the next video.
    /// Uses a burst of scroll-wheel events (not a drag) to simulate a
    /// decisive flick with momentum, matching how users navigate the
    /// mirrored feed with a real trackpad. Direction adapts to the
    /// system's natural-scrolling preference.
    @discardableResult
    func swipeUpToNext() async -> Bool {
        guard controlEnabled else {
            message = "播放控制未开启"
            return false
        }
        guard !userTakeover else {
            message = "手动使用镜像中，已跳过操作"
            return false
        }
        guard let window, let normalized = point, let frame = currentFrame(window) else {
            message = "镜像窗口不在可控状态"
            return false
        }
        let center = CGPoint(x: frame.minX + normalized.x * frame.width,
                              y: frame.minY + normalized.y * frame.height)
        // macOS delivers scroll events to the window under the mouse cursor.
        // When the user clicks "下一条", the mouse is over the companion strip,
        // not the mirror — so the events never reach the mirror.
        // Fix: move the mouse to the mirror center, send scroll events, move back.
        let source = CGEventSource(stateID: .hidSystemState)
        let savedMouse = CGEvent(source: nil)?.location ?? NSEvent.mouseLocation
        // Move mouse to the mirror video center.
        if let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                               mouseCursorPosition: center, mouseButton: .left) {
            move.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventTag)
            move.post(tap: .cghidEventTap)
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        // Send the scroll burst while the cursor is over the mirror.
        // Per-step ~55pt (the value that moved), more steps for distance.
        let steps = 22
        let perStep = Int32(frame.height) / 15
        for index in 0..<steps {
            guard let scroll = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                                        wheelCount: 1, wheel1: -perStep, wheel2: 0, wheel3: 0) else { continue }
            scroll.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            let phase: Int64 = index == 0 ? 1 : (index == steps - 1 ? 4 : 2)
            scroll.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            scroll.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventTag)
            scroll.post(tap: .cghidEventTap)
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
        // Move the mouse back to where it was.
        if let moveBack = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                   mouseCursorPosition: savedMouse, mouseButton: .left) {
            moveBack.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventTag)
            moveBack.post(tap: .cghidEventTap)
        }
        trace("scroll_cursor", details: ["steps": String(steps), "perStep": String(perStep)])
        return true
    }

    @discardableResult
    func request(_ desired: KnownState) -> Bool {
        guard desired != .unknown else { return false }
        guard controlEnabled else { message = "自动播控尚未开启；当前只显示接力提醒"; return false }
        guard AccessibilityProbe.isTrusted else { return false }
        installInputMonitorIfNeeded()
        guard inputMonitor != nil else { message = "无法监听手动操作，未启动自动播控"; return false }
        guard !userTakeover else {
            message = "手动使用镜像中，自动播控已暂挂"
            trace("skip_takeover")
            return false
        }
        guard let window, let normalized = point else { return false }
        let target = Self.coreState(desired)
        if mirrorIsTucked {
            deferredTarget = desired
            message = "镜像已收起，恢复后继续播放控制"
            trace("deferred_\(target.rawValue)")
            return true
        }
        guard canObserve() else { return false }
        if toggle.hasActiveRequest && toggle.desiredState == target { return false }
        invalidateControl(reason: "切换中")
        _ = toggle.request(target, now: Date().timeIntervalSince1970)
        syncState()
        trace("request_\(target.rawValue)", details: sensor.summary)
        let token = generation
        let receivedAt = ProcessInfo.processInfo.systemUptime
        manualInputDuringRequest = false
        isInspecting = true
        interactionTask = Task { [weak self] in
            guard let self else { return }
            defer { self.cleanupWorkflow(token) }
            await self.reconcile(target: target, window: window, normalized: normalized,
                                 token: token, receivedAt: receivedAt)
        }
        return false
    }

    /// Reads the live state, clicks only on a real mismatch, then confirms from
    /// the same signals. One further click is allowed only when strong evidence
    /// shows the first had no effect, for example when it was consumed by focus.
    private func reconcile(target: MirrorPlaybackState, window: ClientWindow, normalized: CGPoint,
                           token: UInt64, receivedAt: TimeInterval) async {
        for attempt in 0..<2 {
            let wait = lastClickAt + Self.clickSpacing - ProcessInfo.processInfo.systemUptime
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            guard isCurrent(token, window: window), controlEnabled else { return }
            if attempt > 0 {
                toggle.invalidate()
                _ = toggle.request(target, now: Date().timeIntervalSince1970)
                syncState()
            }
            let decisionEpoch = toggle.epoch
            let before = await sensor.settled(timeout: Self.decisionTimeout)
            guard isCurrent(token, window: window), controlEnabled else { return }
            let observed: MirrorPlaybackState = before.settling ? .unknown : before.state
            record(before, phase: "before", receivedAt: receivedAt)
            let command = toggle.observe(observed, epoch: decisionEpoch, now: Date().timeIntervalSince1970)
            syncState()
            guard let command else {
                let matched = toggle.evidence == .observed && toggle.state == target
                finish(token, message: matched ? "" : "无法读取播放状态")
                if matched && target == .paused { onPauseHandled?() }
                return
            }
            let typingDeadline = ProcessInfo.processInfo.systemUptime + Self.typingMaximumWait
            // Skip the wait entirely when the last key was Enter — the user
            // has sent their message and is done composing.
            if !lastKeyWasEnter {
                while ProcessInfo.processInfo.systemUptime - lastKeyDownAt < Self.typingQuietPeriod,
                      ProcessInfo.processInfo.systemUptime < typingDeadline, !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 30_000_000)
                }
            }
            guard isCurrent(token, window: window), controlEnabled else { return }
            guard let clickedAt = await click(command, window: window, normalized: normalized, token: token) else { return }
            trace("clicked", details: ["attempt": String(attempt),
                                       "latencyMs": String(format: "%.0f", (clickedAt - receivedAt) * 1000)])
            let verificationEpoch = toggle.epoch
            let after = await sensor.wait(for: target, after: clickedAt, timeout: Self.verificationTimeout)
            guard isCurrent(token, window: window), controlEnabled else { return }
            record(after, phase: "after", receivedAt: receivedAt)
            let confirmed = after.state == target && !after.settling && after.changedAt >= clickedAt
            if confirmed {
                if target == .playing { silentResumes = 0 }
                _ = toggle.observe(target, epoch: verificationEpoch, now: Date().timeIntervalSince1970)
                syncState()
                trace("target_observed")
                finish(token, message: "")
                if target == .paused { onPauseHandled?() }
                return
            }
            let clickHadNoEffect = !after.settling && after.strong && after.state == command.from
            guard attempt == 0, clickHadNoEffect, !manualInputDuringRequest else {
                noteFailedResume(target)
                trace("verification_inconclusive", details: sensor.summary)
                toggle.invalidate()
                syncState()
                finish(token, message: "未确认切换结果")
                return
            }
            trace("click_had_no_effect", details: sensor.summary)
        }
        noteFailedResume(target)
        toggle.invalidate()
        syncState()
        finish(token, message: "点击未生效。请确认镜像停留在短视频页面。")
    }

    /// Takes focus only for the click itself, then hands focus and the pointer
    /// back so the conversation in Codex is not interrupted.
    private func click(_ command: MirrorToggleCommand, window: ClientWindow, normalized: CGPoint,
                       token: UInt64) async -> TimeInterval? {
        let front = NSWorkspace.shared.frontmostApplication
        let previous = front?.processIdentifier == window.pid ? nil : front
        let cursor = CGEvent(source: nil)?.location
        let focused = await dock.focusForInteraction(window, normalizedPoint: normalized)
        guard isCurrent(token, window: window), controlEnabled else {
            dock.returnFocus(to: previous, from: window, cursor: cursor)
            return nil
        }
        guard focused, let frame = currentFrame(window) else {
            trace("target_not_exposed", details: ["focus": dock.lastFocusDiagnostics])
            dock.returnFocus(to: previous, from: window, cursor: cursor)
            invalidateControl(reason: "镜像被遮挡，未点击")
            return nil
        }
        guard post(command, window: window, normalized: normalized, observedFrame: frame) else {
            dock.returnFocus(to: previous, from: window, cursor: cursor)
            return nil
        }
        let clickedAt = ProcessInfo.processInfo.systemUptime
        lastClickAt = clickedAt
        // Let the mirror take the mouse-up before it stops being frontmost.
        try? await Task.sleep(nanoseconds: 60_000_000)
        dock.returnFocus(to: previous, from: window, cursor: cursor)
        return clickedAt
    }

    /// No await is allowed between the final checks and this single event pair.
    private func post(_ command: MirrorToggleCommand, window: ClientWindow, normalized: CGPoint, observedFrame: CGRect) -> Bool {
        guard controlEnabled, observationEnabled, supportsAutomaticPlayback, AccessibilityProbe.isTrusted else {
            invalidateControl(reason: "控制开关或权限已变化，本次没有点击")
            return false
        }
        guard self.window?.id == window.id, let frame = currentFrame(window) else {
            invalidateControl(reason: "镜像绑定或窗口已变化，本次没有点击")
            return false
        }
        guard
              abs(frame.minX - observedFrame.minX) <= 2, abs(frame.minY - observedFrame.minY) <= 2,
              abs(frame.width - observedFrame.width) <= 2, abs(frame.height - observedFrame.height) <= 2 else {
            invalidateControl(reason: "镜像位置或尺寸变化，本次没有点击")
            return false
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid else {
            invalidateControl(reason: "点击前镜像失去前台焦点，本次没有点击")
            return false
        }
        guard (0.2...0.8).contains(normalized.x), (0.2...0.8).contains(normalized.y) else {
            invalidateControl(reason: "播放触点超出视频中央区域，本次没有点击")
            return false
        }
        let location = CGPoint(x: frame.minX + normalized.x * frame.width, y: frame.minY + normalized.y * frame.height)
        var hitElement: AXUIElement?
        var hitPID: pid_t = 0
        let hitStatus = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(location.x), Float(location.y), &hitElement)
        guard hitStatus == .success, let hitElement,
              AXUIElementGetPid(hitElement, &hitPID) == .success, hitPID == window.pid else {
            invalidateControl(reason: "播放触点被其他窗口遮挡，本次没有点击")
            return false
        }
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: location, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: location, mouseButton: .left) else {
            invalidateControl(reason: "无法创建点击事件，本次没有点击")
            return false
        }
        for event in [down, up] {
            event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventTag)
            event.setIntegerValueField(.mouseEventClickState, value: 1)
        }
        let now = Date().timeIntervalSince1970
        guard toggle.canPost(command, now: now) else {
            invalidateControl(reason: "本次操作已失效，没有点击")
            return false
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        guard toggle.didPost(command, now: now) else {
            invalidateControl(reason: "点击已投递但无法继续验证，状态保持不确定")
            return false
        }
        syncState()
        trace("posted_\(command.target.rawValue)")
        message = "切换中"
        return true
    }

    private func noteFailedResume(_ target: MirrorPlaybackState) {
        guard target == .playing, sensor.latestLevelIsSilent else { return }
        silentResumes += 1
        if silentResumes >= 2 {
            silentResumes = 0
            sensor.withdrawAudioTrust()
            trace("audio_trust_withdrawn")
        }
    }

    private func isCurrent(_ token: UInt64, window: ClientWindow) -> Bool {
        !Task.isCancelled && generation == token && self.window?.id == window.id
            && observationEnabled && supportsAutomaticPlayback
    }

    private func cleanupWorkflow(_ token: UInt64) {
        guard generation == token else { return }
        if isInspecting {
            toggle.invalidate()
            syncState()
            message = "未确认切换结果"
        }
        isInspecting = false
        interactionTask = nil
    }

    private func finish(_ token: UInt64, message: String) {
        guard generation == token else { return }
        isInspecting = false
        interactionTask = nil
        self.message = message
    }

    private func record(_ reading: MirrorPlaybackSensor.Reading, phase: String, receivedAt: TimeInterval) {
        if reading.reason == .sound { clearTakeover() }
        observationReason = Self.describe(reading)
        lastObservation = sensor.summary
        lastObservation["phase"] = phase
        lastObservation["sinceRequestMs"] = String(format: "%.0f", (ProcessInfo.processInfo.systemUptime - receivedAt) * 1000)
        trace("observed_\(phase)_\(reading.state.rawValue)", details: lastObservation)
    }

    private static func describe(_ reading: MirrorPlaybackSensor.Reading) -> String {
        switch reading.reason {
        case .sound: return "镜像有声音"
        case .silentAndStill: return "镜像无声且画面流静止"
        case .silentVideo: return "镜像无声，但画面流持续运动"
        case .silentLightMotion: return "镜像无声，仅有少量界面变化"
        case .streamMoving: return "未读到声音；画面流在运动"
        case .streamStill: return "未读到声音；画面流静止"
        case .silenceOnly: return "镜像无声；未读到画面流"
        case .settling, .noEvidence: return "信号还不足以判断"
        }
    }

    func cancelPendingRequest() {
        invalidateControl(reason: "")
    }

    private func invalidateControl(reason: String) {
        generation &+= 1
        interactionTask?.cancel()
        interactionTask = nil
        toggle.invalidate()
        isInspecting = false
        syncState()
        trace("invalidated", details: ["reason": reason])
        message = reason
    }

    /// Manual use of the mirrored phone. A pause tap happens while sound
    /// plays, so it is not a takeover. Silent input only counts as a takeover
    /// when no sound appears: a manual resume tap brings audio back quickly.
    private func noteManualMirrorUse() {
        // Video state is a pure function of the agent state: thinking = play,
        // anything else = pause. Manual use of the phone never suspends that.
        return
        guard !userTakeover else { return }
        takeoverProbe?.cancel()
        takeoverProbe = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            let atInput = await self.sensor.settled(timeout: 0.25)
            guard !Task.isCancelled else { return }
            if atInput.reason == .sound { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, !self.userTakeover else { return }
            let later = await self.sensor.settled(timeout: 0.3)
            guard !Task.isCancelled, !self.userTakeover else { return }
            if later.reason == .sound { return }
            self.userTakeover = true
            self.trace("takeover_on", details: ["reason": "镜像静默期间检测到手动使用"])
            self.syncState()
            self.beginTakeoverWatch()
        }
    }

    /// While taken over, watch for sound returning (user back on the feed).
    private func beginTakeoverWatch() {
        takeoverWatch?.cancel()
        takeoverWatch = Task { [weak self] in
            while let self, !Task.isCancelled, self.userTakeover {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let reading = await self.sensor.settled(timeout: 0.25)
                if reading.reason == .sound { self.clearTakeover(); return }
            }
        }
    }

    private func clearTakeover() {
        guard userTakeover else { return }
        userTakeover = false
        takeoverWatch?.cancel()
        takeoverWatch = nil
        trace("takeover_off", details: ["reason": "镜像重新有声音"])
        syncState()
    }

    /// Manual input needs no state reset: the sensor sees its effect directly.
    /// Only a request in flight has to stop, so it cannot fight the user.
    private func handleExternalInput(_ event: NSEvent, frontPID: pid_t?) {
        guard let window else { return }
        if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventTag { return }
        let now = ProcessInfo.processInfo.systemUptime
        if event.type == .keyDown {
            lastKeyDownAt = now
            // Enter / Return is the "send" signal: the user is done composing.
            let keyCode = event.cgEvent?.getIntegerValueField(.keyboardEventKeycode) ?? 0
            lastKeyWasEnter = keyCode == 36 || keyCode == 76  // ANSI Enter / KP Enter
        }
        if frontPID == window.pid { lastManualMirrorInputAt = now }
        // Always-on takeover signal: manual use of the mirrored phone while
        // it stays silent means the user is doing something else on it.
        let takeoverLocation = event.cgEvent?.location
        let takeoverInside = takeoverLocation.flatMap { point in currentFrame(window).map { $0.contains(point) } } ?? false
        let takeoverKeyboard = event.type == .keyDown && frontPID == window.pid
        if takeoverInside || takeoverKeyboard { noteManualMirrorUse() }
        guard toggle.hasActiveRequest || isInspecting else { return }
        let rawTarget = event.cgEvent?.getIntegerValueField(.eventTargetUnixProcessID) ?? 0
        let targetPID = rawTarget > 0 && rawTarget <= Int64(Int32.max) ? pid_t(rawTarget) : nil
        // Command-Tab only switches applications; it does not change the video.
        if event.type == .keyDown, event.keyCode == 48, event.modifierFlags.contains(.command) { return }
        let location = event.cgEvent?.location
        let inside = location.flatMap { point in currentFrame(window).map { $0.contains(point) } } ?? false
        let hit = event.type == .keyDown ? nil : location.flatMap { topmostWindow(at: $0) }
        let hitMirror = hit.map { $0.pid == window.pid && (window.cgWindowID == nil || window.cgWindowID == $0.id) } ?? false
        let targetsMirror = MirrorInputPolicy.affectsMirror(isKeyboard: event.type == .keyDown,
            routedToMirror: targetPID == window.pid, mirrorIsFrontmost: frontPID == window.pid,
            pointInsideMirror: inside, topmostHitIsMirror: hitMirror)
        lastInputDiagnostics = "type=\(event.type.rawValue) routedToMirror=\(targetPID == window.pid) frontMirror=\(frontPID == window.pid) inside=\(inside) hitMirror=\(hitMirror)"
        if targetsMirror {
            manualInputDuringRequest = true
            trace("manual_mirror_input")
            invalidateControl(reason: "检测到手动操作，已取消本次切换")
        }
    }

    private func topmostWindow(at location: CGPoint) -> (pid: pid_t, id: CGWindowID)? {
        guard location.x.isFinite, location.y.isFinite,
              let records = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        // WindowServer returns front-to-back order. Stop at the first visible
        // covering window instead of treating every overlapping rectangle as a hit.
        for record in records {
            guard let pid = (record[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid > 0,
                  let id = (record[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  ((record[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0.01,
                  ((record[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0) >= 0,
                  let bounds = record[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width > 1, frame.height > 1, frame.contains(location) else { continue }
            // Our decorative panels may deliberately pass mouse events through.
            if pid == ProcessInfo.processInfo.processIdentifier,
               NSApp.windows.first(where: { $0.windowNumber == Int(id) })?.ignoresMouseEvents == true { continue }
            return (pid, id)
        }
        return nil
    }

    private func syncState() {
        desiredState = toggle.desiredState.map(Self.uiState)
    }

    private func sensorEntry(_ operation: String) -> [String: String] {
        var entry = sensor.summary
        entry["time"] = String(Date().timeIntervalSince1970)
        entry["operation"] = operation
        return entry
    }

    private func trace(_ operation: String, details: [String: String] = [:]) {
        var entry = ["time": String(Date().timeIntervalSince1970), "operation": operation,
            "state": toggle.state.rawValue, "evidence": toggle.evidence.rawValue,
            "desired": toggle.desiredState?.rawValue ?? "none"]
        for (key, value) in details { entry["observation_\(key)"] = value }
        operationTrace.append(entry)
        operationTrace = Array(operationTrace.suffix(40))
        RelayTraceLog.write(entry)
    }

    var diagnosticSummary: [String: Any] {
        ["state": knownState.rawValue, "controlEnabled": controlEnabled, "observationEnabled": observationEnabled,
         "isInspecting": isInspecting, "supportedProfileConfirmed": supportsAutomaticPlayback,
         "sensor": sensor.summary, "lastObservation": lastObservation,
         "lastInputMetadata": lastInputDiagnostics, "lastFocus": dock.lastFocusDiagnostics,
         "recentOperations": operationTrace]
    }

    private static func coreState(_ state: KnownState) -> MirrorPlaybackState {
        switch state { case .unknown: return .unknown; case .playing: return .playing; case .paused: return .paused }
    }

    private static func uiState(_ state: MirrorPlaybackState) -> KnownState {
        switch state { case .unknown: return .unknown; case .playing: return .playing; case .paused: return .paused }
    }
}
