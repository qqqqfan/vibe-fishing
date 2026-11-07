import AppKit
import ApplicationServices
import RelayCore

/// `frame` uses the Accessibility API's global, top-left coordinate system.
struct ClientWindow: Identifiable {
    let id: String
    let pid: pid_t
    let bundleID: String
    let appName: String
    let title: String
    let frame: CGRect
    let element: AXUIElement
    let cgWindowID: CGWindowID?

    init(id: String, pid: pid_t, bundleID: String, appName: String, title: String,
         frame: CGRect, element: AXUIElement, cgWindowID: CGWindowID? = nil) {
        self.id = id
        self.pid = pid
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.frame = frame
        self.element = element
        self.cgWindowID = cgWindowID
    }

    /// Current global, top-left bounds. A missing, minimized, or replaced CG
    /// window is invalid; never reuse the discovery-time frame for an action.
    @MainActor var liveFrame: CGRect? {
        if let cgWindowID {
            guard let records = CGWindowListCopyWindowInfo(.optionIncludingWindow, cgWindowID) as? [[String: Any]],
                  let record = records.first(where: {
                      ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == cgWindowID
                          && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
                  }),
                  (record[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
                  let bounds = record[kCGWindowBounds as String] as? [String: Any],
                  let current = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  current.minX.isFinite, current.minY.isFinite,
                  current.width.isFinite, current.height.isFinite,
                  current.width > 0, current.height > 0 else { return nil }
            return current
        }
        return AccessibilityProbe.rect(of: element)
    }
}

struct ProbeSample {
    let state: AgentState
    let reason: String
    /// Only recognized control vocabulary and aggregate counts; never chat text.
    let controls: [String]
    let timestamp: TimeInterval
}

/// A conservative prototype adapter. It deliberately returns `unknown` when an
/// app's AX tree does not expose enough evidence, including hidden/background chats.
@MainActor
final class AccessibilityProbe {
    var onSample: ((ProbeSample) -> Void)?
    private(set) var lastWindowDiagnostics = "尚未查找窗口"
    /// Also available after WindowDock uses a short-lived probe for mirror lookup.
    private(set) static var latestWindowDiagnostics = "尚未查找窗口"
    private var boundWindow: ClientWindow?
    private var timer: Timer?
    private var sawRunning = false
    private var sendUnavailableWhileRunning = false
    private var resetFirstSeen: TimeInterval?
    private var completedAt: TimeInterval?

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Call only in response to the user's explicit permission-button click.
    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    func windows(bundleIDs: [String]) -> [ClientWindow] {
        guard Self.isTrusted else {
            lastWindowDiagnostics = "AX trusted=false；未发起窗口查询"
            Self.latestWindowDiagnostics = lastWindowDiagnostics
            return []
        }
        let allowed = Set(bundleIDs)
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier.map(allowed.contains) ?? false }
        var diagnostics = ["AX trusted=true；目标运行实例=\(apps.count)"]
        let result = apps.flatMap { app in
            Self.windows(for: app) { diagnostics.append($0) }
        }
            .sorted { ($0.appName, $0.title) < ($1.appName, $1.title) }
        diagnostics.append("可用窗口=\(result.count)")
        lastWindowDiagnostics = diagnostics.joined(separator: "；")
        Self.latestWindowDiagnostics = lastWindowDiagnostics
        return result
    }

    func bind(_ window: ClientWindow) {
        boundWindow = window
        sawRunning = false
        sendUnavailableWhileRunning = false
        resetFirstSeen = nil
        completedAt = nil
        AXUIElementSetMessagingTimeout(window.element, 0.08)
    }

    func start() {
        stop()
        onSample?(scanOnce())
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.onSample?(self.scanOnce())
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func scanOnce() -> ProbeSample {
        let now = Date().timeIntervalSince1970
        func sample(_ state: AgentState, _ reason: String, _ controls: [String] = []) -> ProbeSample {
            ProbeSample(state: state, reason: reason, controls: controls, timestamp: now)
        }
        guard Self.isTrusted else { return sample(.unknown, "尚未授权辅助功能；不会读取客户端状态") }
        guard let window = boundWindow else { return sample(.unknown, "请先绑定一个 AI 客户端窗口") }
        guard NSRunningApplication(processIdentifier: window.pid)?.isTerminated == false else {
            return sample(.unknown, "绑定的客户端已退出")
        }
        guard Self.rect(of: window.element) != nil else {
            return sample(.unknown, "绑定窗口已关闭或无法读取，请重新绑定")
        }
        if Self.bool(window.element, kAXMinimizedAttribute as CFString) == true {
            return sample(.unknown, "窗口已最小化；等待可验证的状态")
        }

        let evidence = collectEvidence(from: window.element)
        let diagnostics = evidence.tokens.sorted() + ["已检查 \(evidence.nodes) 个结构节点、\(evidence.buttons) 个按钮"]
        if evidence.approval {
            resetFirstSeen = nil
            completedAt = nil
            return sample(.needsInput, "发现明确的授权／审批控件", diagnostics)
        }
        if evidence.stopGeneration {
            sawRunning = true
            sendUnavailableWhileRunning = sendUnavailableWhileRunning || !evidence.enabledSend
            resetFirstSeen = nil
            completedAt = nil
            return sample(.running, "发现明确的停止生成控件", diagnostics)
        }
        // Neither an inaccessible tree nor a vanished stop button can prove that
        // work finished. A positive send-control reset after observed work is required.
        guard evidence.exhaustive else {
            resetFirstSeen = nil
            return sample(.unknown, "控件扫描达到时限或数量上限；无法确认完成", diagnostics)
        }
        if evidence.progress {
            resetFirstSeen = nil
            return sample(.unknown, "存在进度控件，但无法确认属于本轮 Agent 工作", diagnostics)
        }
        if let completedAt, now - completedAt < 3 {
            return sample(.completed, "已确认发送控件在工作后恢复", diagnostics)
        }
        if sawRunning && sendUnavailableWhileRunning && evidence.enabledSend {
            if let first = resetFirstSeen, now - first >= 0.65 {
                sawRunning = false
                sendUnavailableWhileRunning = false
                resetFirstSeen = nil
                completedAt = now
                return sample(.completed, "已见生成状态，随后发送控件连续恢复可用", diagnostics)
            }
            if resetFirstSeen == nil { resetFirstSeen = now }
            return sample(.unknown, "发送控件已恢复，正在等待再次确认", diagnostics)
        }
        resetFirstSeen = nil
        return sample(.unknown, sawRunning
            ? "生成控件已变化，但没有足够证据确认任务完成"
            : "尚未发现可确认的生成／审批控件；可用演示模式验证交互", diagnostics)
    }

    private struct Evidence {
        var stopGeneration = false
        var enabledSend = false
        var approval = false
        var progress = false
        var exhaustive = true
        var nodes = 0
        var buttons = 0
        var tokens = Set<String>()
    }

    private func collectEvidence(from root: AXUIElement) -> Evidence {
        var result = Evidence()
        let deadline = ProcessInfo.processInfo.systemUptime + 0.12
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0
        let maxNodes = 160
        let maxDepth = 10
        while index < queue.count && result.nodes < maxNodes {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                result.exhaustive = false
                break
            }
            let (node, depth) = queue[index]
            index += 1
            result.nodes += 1
            guard let role = Self.string(node, kAXRoleAttribute as CFString) else {
                result.exhaustive = false
                continue
            }
            if role == kAXButtonRole as String || role == kAXMenuButtonRole as String {
                result.buttons += 1
                // Only button metadata is inspected. AXValue, AXText and static
                // text are intentionally not read, retained, or logged.
                let labels = [Self.string(node, kAXTitleAttribute as CFString),
                              Self.string(node, kAXDescriptionAttribute as CFString)]
                    .compactMap { $0 }.map(Self.normalized)
                let enabled = Self.bool(node, kAXEnabledAttribute as CFString) == true
                if enabled && labels.contains(where: Self.isStopLabel) {
                    result.stopGeneration = true
                    result.tokens.insert("停止生成控件")
                }
                if enabled && labels.contains(where: Self.isApprovalLabel) {
                    result.approval = true
                    result.tokens.insert("授权／审批控件")
                }
                if labels.contains(where: Self.isSendLabel) {
                    result.enabledSend = result.enabledSend || enabled
                    result.tokens.insert(enabled ? "发送控件：可用" : "发送控件：不可用")
                }
            } else if role == kAXProgressIndicatorRole as String {
                result.progress = true
                result.tokens.insert("进度控件")
            }
            // Text fields, text areas and static text cannot contain relevant
            // structural controls. Prune them without inspecting their contents.
            if [kAXStaticTextRole as String, kAXTextAreaRole as String, kAXTextFieldRole as String,
                kAXImageRole as String].contains(role) { continue }
            var childCount: CFIndex = 0
            let countStatus = AXUIElementGetAttributeValueCount(node, kAXChildrenAttribute as CFString, &childCount)
            if countStatus == .attributeUnsupported || countStatus == .noValue { continue }
            guard countStatus == .success else {
                result.exhaustive = false
                continue
            }
            guard childCount > 0 else { continue }
            guard depth < maxDepth else { result.exhaustive = false; continue }
            let capacity = maxNodes - queue.count
            guard capacity > 0 else { result.exhaustive = false; continue }
            let take = min(childCount, min(40, capacity))
            if take < childCount { result.exhaustive = false }
            // Composers usually occur at the end of web-backed AX containers.
            // Read a bounded tail and head rather than allocating full chat trees.
            let tailCount = min(take, 24)
            let headCount = take - tailCount
            let ranges = [(max(0, childCount - tailCount), tailCount), (0, headCount)]
            for (offset, count) in ranges where count > 0 {
                var values: CFArray?
                let status = AXUIElementCopyAttributeValues(node, kAXChildrenAttribute as CFString, offset, count, &values)
                guard status == .success, let children = values as? [AXUIElement] else {
                    result.exhaustive = false
                    continue
                }
                queue.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }
        if index < queue.count { result.exhaustive = false }
        return result
    }

    private static func normalized(_ text: String) -> String {
        String(text.prefix(160)).lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func matches(_ label: String, _ phrases: [String]) -> Bool {
        phrases.contains { label == $0 || label.hasPrefix($0 + " (") || label.hasPrefix($0 + "（") }
    }

    private static func isStopLabel(_ label: String) -> Bool {
        matches(label, ["stop generating", "stop generation", "stop response", "stop responding", "stop streaming",
                        "停止生成", "停止响应", "停止回答", "停止输出", "取消生成", "中止生成"])
    }

    private static func isSendLabel(_ label: String) -> Bool {
        matches(label, ["send", "send message", "send prompt", "send now", "发送", "发送消息", "发送提示"])
    }

    private static func isApprovalLabel(_ label: String) -> Bool {
        matches(label, ["allow once", "allow this time", "approve", "approve once", "approve and continue",
                        "允许一次", "仅允许一次", "本次允许", "批准", "批准并继续", "允许此操作"])
    }

    static func windows(for app: NSRunningApplication, diagnostics: ((String) -> Void)? = nil) -> [ClientWindow] {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        // Enumeration is user-triggered and may initialize an app's AX provider.
        // Keep its timeout separate from the fast, bounded state scanner.
        let timeoutStatus = AXUIElementSetMessagingTimeout(appElement, 0.8)
        var raw: CFTypeRef?
        let started = ProcessInfo.processInfo.systemUptime
        let status = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &raw)
        let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1_000)
        let typeID = raw.map { String(CFGetTypeID($0)) } ?? "nil"
        diagnostics?("\(app.bundleIdentifier ?? "unknown") pid=\(app.processIdentifier) AXWindows=\(status.rawValue) \(elapsed)ms type=\(typeID) timeout=\(timeoutStatus.rawValue)")
        var elements: [AnyObject] = []
        if status == .success, let raw {
            if CFGetTypeID(raw) == CFArrayGetTypeID(), let array = raw as? [AnyObject] {
                elements = array
            } else {
                diagnostics?("窗口返回值不是可桥接CFArray；expectedType=\(CFArrayGetTypeID())")
            }
        }
        if elements.isEmpty {
            for attribute in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
                var candidate: CFTypeRef?
                let fallbackStatus = AXUIElementCopyAttributeValue(appElement, attribute as CFString, &candidate)
                diagnostics?("\(attribute)=\(fallbackStatus.rawValue)")
                guard fallbackStatus == .success, let candidate,
                      CFGetTypeID(candidate) == AXUIElementGetTypeID(),
                      !elements.contains(where: { CFEqual($0, candidate) }) else { continue }
                elements.append(candidate)
            }
        }
        var accepted: [ClientWindow] = []
        var badTypes = 0, rectFailures = 0, smallFrames = 0
        for (index, value) in elements.prefix(24).enumerated() {
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { badTypes += 1; continue }
            let element = unsafeBitCast(value, to: AXUIElement.self)
            AXUIElementSetMessagingTimeout(element, 0.8)
            guard let frame = rect(of: element, diagnostics: { diagnostics?("window[\(index)] \($0)") }) else {
                rectFailures += 1
                continue
            }
            guard frame.width > 80, frame.height > 80 else { smallFrames += 1; continue }
            accepted.append(ClientWindow(id: "\(app.processIdentifier):\(CFHash(element))", pid: app.processIdentifier,
                                         bundleID: app.bundleIdentifier ?? "", appName: app.localizedName ?? "AI 客户端",
                                         title: string(element, kAXTitleAttribute as CFString) ?? "未命名窗口",
                                         frame: frame, element: element))
        }
        diagnostics?("AX窗口数=\(elements.count) 类型失败=\(badTypes) rect失败=\(rectFailures) 小窗过滤=\(smallFrames)")
        return accepted
    }

    static func rect(of element: AXUIElement, diagnostics: ((String) -> Void)? = nil) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        let positionStatus = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position)
        let sizeStatus = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size)
        guard positionStatus == .success, sizeStatus == .success,
              let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else {
            diagnostics?("position=\(positionStatus.rawValue) size=\(sizeStatus.rawValue) posType=\(position.map { String(CFGetTypeID($0)) } ?? "nil") sizeType=\(size.map { String(CFGetTypeID($0)) } ?? "nil")")
            return nil
        }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else {
            diagnostics?("AXValue类型不是CGPoint/CGSize")
            return nil
        }
        return CGRect(origin: point, size: dimensions)
    }

    private static func string(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success else { return nil }
        return raw as? String
    }

    private static func bool(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success else { return nil }
        return raw as? Bool
    }
}
