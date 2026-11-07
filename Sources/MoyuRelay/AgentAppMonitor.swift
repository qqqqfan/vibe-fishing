import AppKit
import ApplicationServices
import Foundation
import RelayCore

/// Watches every supported desktop AI client window at once and reports whole-turn
/// transitions. It reads only button names (title / description / help) and
/// enabled state. Message text, text fields and static text are never read.
/// All Accessibility IPC runs on a background queue so a slow client cannot
/// stall the interface or the playback sensor.
final class AgentAppMonitor: @unchecked Sendable {
    struct Client: Equatable {
        let bundleID: String
        let name: String
    }

    struct Target: Equatable {
        let pid: pid_t
        let bundleID: String
        let name: String
    }

    static let standardClients: [Client] = [
        Client(bundleID: "com.openai.codex", name: "ChatGPT / Codex"),
        Client(bundleID: "com.openai.chat", name: "ChatGPT"),
        Client(bundleID: "com.anthropic.claudefordesktop", name: "Claude"),
        Client(bundleID: "com.todesktop.230313mzl4w4u92", name: "Cursor")
    ]

    /// Apps the user added themselves. They are scanned for generation state
    /// like the built-ins, but the button vocabulary is not calibrated for them:
    /// detection may not work until their stop-button labels are learned.
    var customClients: [Client] {
        let ids = UserDefaults.standard.stringArray(forKey: "customClientBundleIDs.v1") ?? []
        return ids.compactMap { bundleID in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
                  let bundle = Bundle(url: url) else { return nil }
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? bundleID
            return Client(bundleID: bundleID, name: name)
        }
    }

    var clients: [Client] { Self.standardClients + customClients }
    static let sourcePrefix = "app:"

    /// Delivered on the main queue.
    var onEvent: ((AgentEvent) -> Void)?
    var onWindowGone: ((_ source: String, _ sessionID: String) -> Void)?
    var onStatus: ((String) -> Void)?

    private let queue = DispatchQueue(label: "moyu.relay.agent-monitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let dataDirectory: URL
    // Queue-confined state.
    private var scanning = false
    private var detectors: [String: GenerationDetector] = [:]
    private var lastSeen: [String: TimeInterval] = [:]
    private var windowBundles: [String: String] = [:]
    private var webAreas: [String: AXUIElement] = [:]
    private var prepared = Set<pid_t>()
    private var prepareAttempts: [pid_t: TimeInterval] = [:]
    private var vocabulary = ControlVocabulary.standard
    private var vocabularyStamp: Date?
    private var lastVocabularyCheck: TimeInterval = 0
    private var calibrationLabels: [String: String] = [:]
    private var lastStats: TimeInterval = 0
    private var calibration: FileHandle?
    /// Control-name logging, only when the user creates this file for support.
    private var debugLogging = false

    init(dataDirectory: URL) {
        self.dataDirectory = dataDirectory
    }

    deinit { timer?.cancel() }

    var isRunning: Bool { timer != nil }

    @MainActor
    func start() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + 0.1, repeating: 0.5, leeway: .milliseconds(80))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // Collected on the main thread; the scan itself runs on the queue.
            let ids = Set(clients.map(\.bundleID))
            let targets = NSWorkspace.shared.runningApplications.compactMap { app -> Target? in
                guard let bundle = app.bundleIdentifier, ids.contains(bundle), !app.isTerminated else { return nil }
                let name = self.clients.first { $0.bundleID == bundle }?.name ?? (app.localizedName ?? bundle)
                return Target(pid: app.processIdentifier, bundleID: bundle, name: name)
            }
            self.queue.async { self.scan(targets) }
        }
        timer = source
        source.resume()
    }

    @MainActor
    func stop() {
        timer?.cancel()
        timer = nil
        queue.async {
            self.detectors.removeAll()
            self.lastSeen.removeAll()
            self.webAreas.removeAll()
            self.calibrationLabels.removeAll()
        }
    }

    // MARK: - Queue

    private func scan(_ targets: [Target]) {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        guard AXIsProcessTrusted() else { return }
        let now = ProcessInfo.processInfo.systemUptime
        reloadVocabularyIfNeeded(now)
        let writeStats = now - lastStats >= 60
        if writeStats { lastStats = now }
        var seen = Set<String>()
        for target in targets {
            let app = AXUIElementCreateApplication(target.pid)
            AXUIElementSetMessagingTimeout(app, 0.25)
            if !prepared.contains(target.pid),
               now - (prepareAttempts[target.pid] ?? -.infinity) >= 2 {
                // Chromium-based clients build their accessibility tree only
                // when asked. A freshly launched app often answers
                // "cannot complete"; keep retrying until it succeeds, or the
                // stop button stays invisible and AI start is never detected.
                prepareAttempts[target.pid] = now
                let status = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                if status == .attributeUnsupported {
                    // Some Chromium shells (e.g. ChatGPT/Codex) ignore the
                    // manual flag and only expose web content to
                    // AXEnhancedUserInterface; without it no stop button is seen.
                    let enhanced = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
                    log("prepare \(target.bundleID) pid=\(target.pid) manual=\(status.rawValue) enhanced=\(enhanced.rawValue)")
                    // Any definite answer ends the retries; only "cannot
                    // complete" (app not ready yet) is worth retrying.
                    if enhanced != .cannotComplete { prepared.insert(target.pid) }
                } else {
                    log("prepare \(target.bundleID) pid=\(target.pid) manual=\(status.rawValue)")
                    if status == .success { prepared.insert(target.pid) }
                }
            }
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw) == .success,
                  let windows = raw as? [AXUIElement] else { continue }
            for window in windows.prefix(8) {
                AXUIElementSetMessagingTimeout(window, 0.2)
                let key = "\(target.pid):\(CFHash(window))"
                seen.insert(key)
                lastSeen[key] = now
                windowBundles[key] = target.bundleID
                let result = observe(window, key: key, target: target)
                if writeStats {
                    log("stats \(target.bundleID) \(key) method=\(result.method) nodes=\(result.nodes) buttons=\(result.buttons) ms=\(Int(result.ms)) readable=\(result.observation.readable)")
                }
                var detector = detectors[key] ?? GenerationDetector()
                let change = detector.observe(result.observation, at: now)
                detectors[key] = detector
                if let change {
                    let event = AgentEvent(id: UUID().uuidString, source: Self.sourcePrefix + target.bundleID,
                                           sessionID: key, turnID: detector.turnID, state: change,
                                           timestamp: Date().timeIntervalSince1970)
                    log("turn \(target.bundleID) \(key) -> \(change.rawValue)")
                    DispatchQueue.main.async { self.onEvent?(event) }
                }
            }
        }
        // A window that has been gone for a while cannot finish its turn.
        for (key, time) in lastSeen where !seen.contains(key) && now - time > 5 {
            let bundle = windowBundles.removeValue(forKey: key)
            lastSeen[key] = nil
            detectors[key] = nil
            webAreas[key] = nil
            calibrationLabels[key] = nil
            if let bundle {
                DispatchQueue.main.async { self.onWindowGone?(Self.sourcePrefix + bundle, key) }
            }
        }
        let alive = Set(targets.map(\.pid))
        prepared = prepared.filter(alive.contains)
        prepareAttempts = prepareAttempts.filter { alive.contains($0.key) }
        let status = targets.isEmpty ? "未检测到 AI 应用"
            : "已检测到 \(Set(targets.map(\.name)).sorted().joined(separator: "、"))"
        DispatchQueue.main.async { self.onStatus?(status) }
    }

    private struct ScanResult {
        var observation = GenerationDetector.Observation(readable: false, stopVisible: false, approvalVisible: false)
        var method = "none"
        var nodes = 0
        var buttons = 0
        var ms = 0.0
    }

    private func observe(_ window: AXUIElement, key: String, target: Target) -> ScanResult {
        var result = ScanResult()
        let started = ProcessInfo.processInfo.systemUptime
        defer { result.ms = (ProcessInfo.processInfo.systemUptime - started) * 1000 }
        var labels: [(String, Bool)] = []
        var complete = false
        if let area = webAreas[key], let found = searchButtons(in: area) {
            result.method = "search"
            labels = found
            complete = true
        } else {
            let walked = walk(window)
            result.method = "walk"
            result.nodes = walked.nodes
            labels = walked.labels
            complete = walked.complete
            if let area = walked.webArea, let found = searchButtons(in: area) {
                webAreas[key] = area
                result.method = "walk+search"
                labels = found
                complete = true
            }
        }
        result.buttons = labels.count
        var stop = false
        var approval = false
        var names = Set<String>()
        for (label, enabled) in labels {
            let normalized = ControlVocabulary.normalize(label)
            if Self.isControlName(normalized) { names.insert(normalized + (enabled ? "" : "[off]")) }
            guard enabled else { continue }
            if vocabulary.isStop(normalized) { stop = true }
            if vocabulary.isApproval(normalized) { approval = true }
        }
        if debugLogging { recordCalibration(key: key, bundle: target.bundleID, names: names) }
        // Absence of a stop control only counts when the scan was complete.
        result.observation = GenerationDetector.Observation(readable: complete || stop || approval,
                                                            stopVisible: stop, approvalVisible: approval)
        return result
    }

    /// Chromium answers this in one call instead of thousands of tree hops.
    private func searchButtons(in area: AXUIElement) -> [(String, Bool)]? {
        let query: [String: Any] = ["AXSearchKey": "AXButtonSearchKey", "AXResultsLimit": 600,
                                    "AXDirection": "AXDirectionNext", "AXVisibleOnly": false,
                                    "AXImmediateDescendantsOnly": false]
        var raw: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(area, "AXUIElementsForSearchPredicate" as CFString,
                                                                query as CFDictionary, &raw)
        guard status == .success, let buttons = raw as? [AXUIElement] else { return nil }
        return buttons.flatMap(Self.buttonLabels)
    }

    private struct Walk {
        var labels: [(String, Bool)] = []
        var nodes = 0
        var complete = true
        var webArea: AXUIElement?
    }

    /// Bounded breadth-first walk, newest content first (composers sit at the end).
    private func walk(_ root: AXUIElement) -> Walk {
        var walk = Walk()
        let deadline = ProcessInfo.processInfo.systemUptime + 0.08
        var queue: [AXUIElement] = [root]
        var index = 0
        let skip: Set<String> = [kAXStaticTextRole as String, kAXTextAreaRole as String,
                                 kAXTextFieldRole as String, kAXImageRole as String]
        while index < queue.count {
            guard walk.nodes < 3_000, ProcessInfo.processInfo.systemUptime < deadline else {
                walk.complete = false
                break
            }
            let node = queue[index]
            index += 1
            walk.nodes += 1
            let role = Self.string(node, kAXRoleAttribute as String) ?? ""
            if role == "AXWebArea", walk.webArea == nil { walk.webArea = node }
            if role == kAXButtonRole as String || role == kAXMenuButtonRole as String {
                walk.labels += Self.buttonLabels(node)
            }
            if skip.contains(role) { continue }
            var raw: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &raw)
            if status == .success, let children = raw as? [AXUIElement] {
                queue.append(contentsOf: children.reversed())
            } else if status != .noValue && status != .attributeUnsupported {
                walk.complete = false
            }
        }
        return walk
    }

    private static func buttonLabels(_ node: AXUIElement) -> [(String, Bool)] {
        let enabled = bool(node, kAXEnabledAttribute as String) ?? true
        return [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
            .compactMap { string(node, $0 as String) }
            .filter { !$0.isEmpty && $0.count <= 40 }
            .map { ($0, enabled) }
    }

    /// Names worth recording for calibration: short and control-like only, so
    /// conversation titles that happen to be buttons are never written down.
    private static let controlPattern = try! NSRegularExpression(
        pattern: "stop|cancel|abort|interrupt|send|submit|allow|approve|deny|reject|run|停止|取消|中止|中断|终止|发送|提交|允许|批准|拒绝|运行")
    private static func isControlName(_ label: String) -> Bool {
        guard label.count <= 24 else { return false }
        return controlPattern.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)) != nil
    }

    private func recordCalibration(key: String, bundle: String, names: Set<String>) {
        let line = names.sorted().joined(separator: " | ")
        guard calibrationLabels[key] != line else { return }
        calibrationLabels[key] = line
        log("controls \(bundle) \(key) [\(line)]")
    }

    private func reloadVocabularyIfNeeded(_ now: TimeInterval) {
        guard now - lastVocabularyCheck >= 10 else { return }
        lastVocabularyCheck = now
        debugLogging = FileManager.default.fileExists(atPath: dataDirectory.appendingPathComponent("debug-controls").path)
        let url = dataDirectory.appendingPathComponent("agent-controls.json")
        let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard stamp != vocabularyStamp else { return }
        vocabularyStamp = stamp
        guard let stamp, let data = try? Data(contentsOf: url),
              let extra = try? JSONDecoder().decode(ControlVocabulary.self, from: data) else {
            vocabulary = .standard
            return
        }
        vocabulary = ControlVocabulary.standard.merged(with: extra)
        log("vocabulary reloaded \(stamp.timeIntervalSince1970) stop=\(extra.stop.count) approval=\(extra.approval.count)")
    }

    /// Local, rotating and content-free: control names, timings and transitions.
    private func log(_ text: String) {
        let url = dataDirectory.appendingPathComponent("agent-monitor.log")
        if calibration == nil {
            try? FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            calibration = try? FileHandle(forWritingTo: url)
            _ = try? calibration?.seekToEnd()
        }
        guard let calibration else { return }
        let line = String(format: "%.1f ", Date().timeIntervalSince1970) + text + "\n"
        try? calibration.write(contentsOf: Data(line.utf8))
        if let size = try? calibration.offset(), size > 512 * 1024 {
            try? calibration.close()
            self.calibration = nil
            let previous = dataDirectory.appendingPathComponent("agent-monitor.previous.log")
            try? FileManager.default.removeItem(at: previous)
            try? FileManager.default.moveItem(at: url, to: previous)
        }
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return raw as? String
    }

    private static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success, let raw,
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var value = CGPoint.zero
        return AXValueGetValue(raw as! AXValue, .cgPoint, &value) ? value : nil
    }

    private static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success, let raw,
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var value = CGSize.zero
        return AXValueGetValue(raw as! AXValue, .cgSize, &value) ? value : nil
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return raw as? Bool
    }
}
