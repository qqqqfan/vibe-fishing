import AppKit
import ApplicationServices

@MainActor
final class WindowDock {
    private(set) var lastMirrorDiagnostics = ""
    private(set) var lastFocusDiagnostics = ""
    private(set) var lastLayoutDiagnostics = ""
    private var layoutInFlight = false

    struct LayoutResult {
        let success: Bool
        let message: String
        /// Fresh, global top-left (AX) frames, including on a partial failure.
        let agentFrame: CGRect?
        let mirrorFrame: CGRect?
    }

    struct LayoutPlan {
        let agentFrame: CGRect
        let mirrorFrame: CGRect
    }

    struct LayoutFailure: Error {
        let message: String
    }

    /// Use the whole work area, with the portrait as tall as the available height
    /// and minimum AI width permit. The real app may enforce discrete sizes;
    /// fittedPlan always replans around the dimensions it actually accepts.
    /// Space reserved above the mirror for the companion strip plus a
    /// hover buffer so the mirror's top-edge menu stays reachable.
    nonisolated static let companionHeight: CGFloat = 58
    nonisolated static let hoverBuffer: CGFloat = 32
    nonisolated static let stripAllowance: CGFloat = companionHeight + hoverBuffer

    nonisolated static func sideBySidePlan(mirrorFrame: CGRect, visibleFrame: CGRect) -> Result<LayoutPlan, LayoutFailure> {
        guard validFrame(mirrorFrame), validFrame(visibleFrame), mirrorFrame.height > mirrorFrame.width else {
            return .failure(LayoutFailure(message: "镜像窗口不是可用的竖屏窗口，请先打开手机视频"))
        }
        let minimumAIWidth: CGFloat = visibleFrame.width >= 1120 ? 640 : 560
        let phoneSpace = visibleFrame.width - minimumAIWidth
        let phoneHeight = visibleFrame.height - stripAllowance
        let scale = min(phoneHeight / mirrorFrame.height, phoneSpace / mirrorFrame.width)
        guard visibleFrame.height >= 360, scale > 0,
              mirrorFrame.width * scale > 100, mirrorFrame.height * scale > 200 else {
            return .failure(LayoutFailure(message: "屏幕可用空间不足；请在显示设置中增加可用空间，或连接更大屏幕"))
        }
        // Avoid a floating-point overshoot at an exact screen boundary.
        let size = CGSize(width: min(phoneSpace, mirrorFrame.width * scale),
                          height: min(phoneHeight, mirrorFrame.height * scale))
        let agentWidth = visibleFrame.width - size.width
        let agent = CGRect(x: visibleFrame.minX, y: visibleFrame.minY,
                           width: agentWidth, height: visibleFrame.height)
        let mirror = CGRect(x: agent.maxX, y: visibleFrame.minY + stripAllowance,
                            width: min(size.width, visibleFrame.maxX - agent.maxX), height: size.height)
        return .success(LayoutPlan(agentFrame: agent, mirrorFrame: mirror))
    }

    /// Replan using the system's actual accepted phone size; never pretend an
    /// unavailable size was applied. A compact AI window still needs 560 points.
    nonisolated static func fittedPlan(mirrorFrame: CGRect, visibleFrame: CGRect) -> Result<LayoutPlan, LayoutFailure> {
        let agentWidth = visibleFrame.width - mirrorFrame.width
        let phoneHeight = visibleFrame.height - stripAllowance
        guard validFrame(mirrorFrame), validFrame(visibleFrame), mirrorFrame.height > mirrorFrame.width,
              agentWidth >= 560, visibleFrame.height >= 360, min(mirrorFrame.height, phoneHeight) >= 200 else {
            return .failure(LayoutFailure(message: "镜像已到系统允许的尺寸仍放不下；请在显示设置中增加可用空间，或连接更大屏幕"))
        }
        let fitHeight = min(mirrorFrame.height, phoneHeight)
        let fitWidth = mirrorFrame.width * (fitHeight / mirrorFrame.height)
        let agent = CGRect(x: visibleFrame.minX, y: visibleFrame.minY, width: visibleFrame.width - fitWidth, height: visibleFrame.height)
        let mirror = CGRect(x: agent.maxX, y: visibleFrame.minY + stripAllowance, width: fitWidth, height: fitHeight)
        return .success(LayoutPlan(agentFrame: agent, mirrorFrame: mirror))
    }

    /// Pure geometry for follow mode. It never moves/resizes the AI window and
    /// stops when there is no longer space on its right on the same display.
    nonisolated static func followPlan(agentFrame: CGRect, mirrorFrame: CGRect,
                                      visibleFrame: CGRect) -> Result<LayoutPlan, LayoutFailure> {
        guard validFrame(agentFrame), validFrame(mirrorFrame), validFrame(visibleFrame),
              mirrorFrame.height > mirrorFrame.width else {
            return .failure(LayoutFailure(message: "窗口位置或竖屏尺寸不可用，请重新排布"))
        }
        guard contains(visibleFrame, agentFrame), mirrorFrame.height <= visibleFrame.height,
              agentFrame.maxX + mirrorFrame.width <= visibleFrame.maxX else {
            return .failure(LayoutFailure(message: "AI 窗口右侧空间不足，已停止跟随；可重新并排排布"))
        }
        let mirror = CGRect(x: agentFrame.maxX,
                            y: min(max(agentFrame.minY, visibleFrame.minY), visibleFrame.maxY - mirrorFrame.height),
                            width: mirrorFrame.width, height: mirrorFrame.height)
        return .success(LayoutPlan(agentFrame: agentFrame, mirrorFrame: mirror))
    }

    /// Only call after the user enables docking. No activation, simulated clicks,
    /// or permission prompts occur here. Both AX windows must pass preflight before
    /// any mutation; CG discovery alone does not establish that a window moves.
    func layoutSideBySide(agent: ClientWindow, mirror: ClientWindow, preserveMirrorSize: Bool = false) async -> LayoutResult {
        guard !layoutInFlight else { return layoutResult(false, "正在排布窗口，请稍候", agent, mirror) }
        layoutInFlight = true
        defer { layoutInFlight = false }
        guard AccessibilityProbe.isTrusted else {
            return layoutResult(false, "需要辅助功能权限才能排布窗口", agent, mirror)
        }
        guard agent.pid != mirror.pid, mirror.bundleID == "com.apple.ScreenContinuity",
              let agentFrame = agent.liveFrame, let mirrorFrame = mirror.liveFrame,
              let visible = visibleAXFrame(for: agentFrame) else {
            return layoutResult(false, "目标窗口或屏幕已失效，请重新选择", agent, mirror)
        }
        var plan: LayoutPlan
        let geometry = preserveMirrorSize
            ? Self.fittedPlan(mirrorFrame: mirrorFrame, visibleFrame: visible)
            : Self.sideBySidePlan(mirrorFrame: mirrorFrame, visibleFrame: visible)
        switch geometry {
        case .success(let value): plan = value
        case .failure(let error): return layoutResult(false, error.message, agent, mirror)
        }
        do {
            // Resolve the mirror first: it is frequently discoverable through CG
            // yet does not expose any writable AXWindow to third-party apps.
            let mirrorAX = try writableWindow(mirror, frame: mirrorFrame, resize: false)
            let agentAX = try writableWindow(agent, frame: agentFrame, resize: true)
            guard !Task.isCancelled else { return layoutResult(false, "排布已取消", agent, mirror) }
            guard AccessibilityProbe.isTrusted,
                  let currentAgent = agent.liveFrame, let currentMirror = mirror.liveFrame,
                  Self.framesMatch(currentAgent, agentFrame), Self.framesMatch(currentMirror, mirrorFrame) else {
                return layoutResult(false, "预检期间窗口或权限已变化，未发送布局操作；请重试", agent, mirror)
            }
            if abs(plan.mirrorFrame.width - mirrorFrame.width) > 1 || abs(plan.mirrorFrame.height - mirrorFrame.height) > 1 {
                let resized = try await resizeMirrorToFit(mirror, element: mirrorAX, targetSize: plan.mirrorFrame.size,
                                                     visibleFrame: visible)
                plan = try Self.fittedPlan(mirrorFrame: resized, visibleFrame: visible).get()
            }
            guard !Task.isCancelled, AccessibilityProbe.isTrusted,
                  let unchangedAgent = agent.liveFrame, Self.framesMatch(unchangedAgent, agentFrame),
                  let currentVisible = visibleAXFrame(for: unchangedAgent), Self.framesMatch(currentVisible, visible),
                  let liveMirror = mirror.liveFrame,
                  abs(liveMirror.width - plan.mirrorFrame.width) <= 4,
                  abs(liveMirror.height - plan.mirrorFrame.height) <= 4 else {
                return layoutResult(false, "调整镜像期间窗口或权限已变化，已停止排布；AI 窗口未移动", agent, mirror)
            }
            try setSize(plan.agentFrame.size, of: agentAX)
            try setPosition(plan.agentFrame.origin, of: agentAX)
            try setPosition(plan.mirrorFrame.origin, of: mirrorAX)
            return await verify(plan, agent: agent, mirror: mirror,
                                successMessage: "已贴合并排；AI 使用左侧全部空间，镜像保持实际比例")
        } catch let failure as LayoutFailure {
            return layoutResult(false, failure.message, agent, mirror)
        } catch {
            return layoutResult(false, "未完成排布，请检查窗口位置后重试", agent, mirror)
        }
    }

    /// One follow step. The caller controls timer lifetime and should stop on a
    /// failure; this class never installs a background timer by itself.
    func followMirror(beside agent: ClientWindow, mirror: ClientWindow) async -> LayoutResult {
        guard !layoutInFlight else { return layoutResult(false, "正在排布窗口，请稍候", agent, mirror) }
        layoutInFlight = true
        defer { layoutInFlight = false }
        guard AccessibilityProbe.isTrusted else {
            return layoutResult(false, "辅助功能权限已失效，跟随已停止", agent, mirror)
        }
        guard agent.pid != mirror.pid, mirror.bundleID == "com.apple.ScreenContinuity",
              let agentFrame = agent.liveFrame, let mirrorFrame = mirror.liveFrame,
              let visible = visibleAXFrame(for: agentFrame) else {
            return layoutResult(false, "窗口已关闭或不可见，跟随已停止", agent, mirror)
        }
        let plan: LayoutPlan
        switch Self.followPlan(agentFrame: agentFrame, mirrorFrame: mirrorFrame, visibleFrame: visible) {
        case .success(let value): plan = value
        case .failure(let error): return layoutResult(false, error.message, agent, mirror)
        }
        if Self.framesMatch(mirrorFrame, plan.mirrorFrame) {
            return layoutResult(true, "两窗已并排", agent, mirror)
        }
        do {
            let mirrorAX = try writableWindow(mirror, frame: mirrorFrame, resize: false)
            guard !Task.isCancelled else { return layoutResult(false, "跟随已取消", agent, mirror) }
            guard AccessibilityProbe.isTrusted,
                  let currentAgent = agent.liveFrame, let currentMirror = mirror.liveFrame,
                  Self.framesMatch(currentAgent, agentFrame), Self.framesMatch(currentMirror, mirrorFrame) else {
                return layoutResult(false, "预检期间窗口或权限已变化，跟随已停止", agent, mirror)
            }
            try setPosition(plan.mirrorFrame.origin, of: mirrorAX)
            return await verify(plan, agent: agent, mirror: mirror, successMessage: "手机已跟随 AI 窗口")
        } catch let failure as LayoutFailure {
            return layoutResult(false, failure.message, agent, mirror)
        } catch {
            return layoutResult(false, "无法继续跟随，请重新排布", agent, mirror)
        }
    }

    private func layoutResult(_ success: Bool, _ message: String,
                              _ agent: ClientWindow, _ mirror: ClientWindow) -> LayoutResult {
        lastLayoutDiagnostics = message
        return LayoutResult(success: success, message: message,
                            agentFrame: agent.liveFrame, mirrorFrame: mirror.liveFrame)
    }

    private func visibleAXFrame(for frame: CGRect) -> CGRect? {
        guard let primary = NSScreen.screens.first else { return nil }
        let appKitFrame = CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY,
                                width: frame.width, height: frame.height)
        guard let screen = NSScreen.screens.max(by: {
            Self.intersectionArea($0.frame, appKitFrame) < Self.intersectionArea($1.frame, appKitFrame)
        }), Self.intersectionArea(screen.frame, appKitFrame) > 0 else { return nil }
        let visible = screen.visibleFrame
        return CGRect(x: visible.minX, y: primary.frame.maxY - visible.maxY,
                      width: visible.width, height: visible.height)
    }

    /// Resolve identity independently of move/resize support; raising a window
    /// does not require its position or size attributes to be writable.
    private func accessibilityWindow(_ target: ClientWindow, frame: CGRect) throws -> AXUIElement {
        guard let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated else {
            throw LayoutFailure(message: "目标应用已退出，未能排布")
        }
        var candidates: [AXUIElement] = []
        func append(_ element: AXUIElement) {
            AXUIElementSetMessagingTimeout(element, 0.8)
            var pid: pid_t = 0
            var role: CFTypeRef?
            guard AXUIElementGetPid(element, &pid) == .success, pid == target.pid,
                  AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
                  (role as? String) == kAXWindowRole as String,
                  !candidates.contains(where: { CFEqual($0, element) }) else { return }
            candidates.append(element)
        }
        // A known AX window retains identity even if another window overlaps it.
        if target.cgWindowID == nil { append(target.element) }
        if candidates.isEmpty {
            AccessibilityProbe.windows(for: app).forEach { append($0.element) }
            // Some apps expose main/focused even when AXWindows is empty, or
            // leave their remote video window out of an otherwise nonempty list.
            let application = AXUIElementCreateApplication(target.pid)
            AXUIElementSetMessagingTimeout(application, 0.8)
            for key in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
                var raw: CFTypeRef?
                if AXUIElementCopyAttributeValue(application, key as CFString, &raw) == .success,
                   let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() {
                    append(unsafeBitCast(raw, to: AXUIElement.self))
                }
            }
            // There is no public AX->CG window ID conversion. Require a unique
            // PID + current-frame match instead of guessing the first AX window.
            candidates = candidates.filter {
                guard let current = AccessibilityProbe.rect(of: $0) else { return false }
                return Self.framesMatch(current, frame)
            }
        }
        guard candidates.count == 1, let element = candidates.first else {
            throw LayoutFailure(message: "\(target.appName) 没有唯一可控制的辅助功能窗口（AX匹配=\(candidates.count)）")
        }
        AXUIElementSetMessagingTimeout(element, 0.8)
        return element
    }

    private func writableWindow(_ target: ClientWindow, frame: CGRect, resize: Bool) throws -> AXUIElement {
        let element = try accessibilityWindow(target, frame: frame)
        for key in [kAXMinimizedAttribute, "AXFullScreen"] {
            var raw: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(element, key as CFString, &raw)
            if (raw as? Bool) == true {
                throw LayoutFailure(message: "\(target.appName) 已最小化或全屏，请先恢复普通窗口")
            }
        }
        for key in resize ? [kAXPositionAttribute, kAXSizeAttribute] : [kAXPositionAttribute] {
            var settable = DarwinBoolean(false)
            let status = AXUIElementIsAttributeSettable(element, key as CFString, &settable)
            guard status == .success, settable.boolValue else {
                throw LayoutFailure(message: "\(target.appName) 不允许自动调整\(key == kAXSizeAttribute ? "尺寸" : "位置")，请手动并排（AX=\(status.rawValue)）")
            }
        }
        guard target.liveFrame != nil, AccessibilityProbe.isTrusted else {
            throw LayoutFailure(message: "窗口或辅助功能权限已变化，未发送布局操作")
        }
        return element
    }

    private func setPosition(_ position: CGPoint, of element: AXUIElement) throws {
        var value = position
        guard let boxed = AXValueCreate(.cgPoint, &value) else { throw LayoutFailure(message: "无法创建窗口位置") }
        let status = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, boxed)
        guard status == .success else {
            throw LayoutFailure(message: "设置窗口位置失败（AX=\(status.rawValue)）；部分窗口可能已改变，请检查后重试")
        }
    }

    /// First request the proportional target using a writable AXSize. If a fixed
    /// size already fits, keep it. Only an oversized mirror uses the existing
    /// observed shrink-menu fallback; no new enlargement/menu automation is added.
    /// Each action is followed by a fresh frame read; no blind repeated toggles.
    private func resizeMirrorToFit(_ mirror: ClientWindow, element: AXUIElement, targetSize: CGSize,
                              visibleFrame: CGRect) async throws -> CGRect {
        guard mirror.bundleID == "com.apple.ScreenContinuity", let initial = mirror.liveFrame else {
            throw LayoutFailure(message: "镜像已失效，无法调整尺寸")
        }
        var settable = DarwinBoolean(false)
        let writable = AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &settable)
        if writable == .success, settable.boolValue {
            do {
                try setSize(targetSize, of: element, name: "镜像")
            } catch {
                // A fixed-size app may report AXSize writable yet reject a new
                // size. Keep its actual usable frame rather than blocking layout.
                if let actual = mirror.liveFrame,
                   case .success = Self.fittedPlan(mirrorFrame: actual, visibleFrame: visibleFrame) { return actual }
                throw error
            }
            guard let actual = await waitForSizeChange(mirror, from: initial) else {
                throw LayoutFailure(message: "镜像调整尺寸后已不可见，排布已停止")
            }
            if case .success = Self.fittedPlan(mirrorFrame: actual, visibleFrame: visibleFrame) { return actual }
        }
        for _ in 0..<5 {
            guard !Task.isCancelled, AccessibilityProbe.isTrusted, let before = mirror.liveFrame else {
                throw LayoutFailure(message: "镜像或授权已变化，已停止缩小")
            }
            if case .success = Self.fittedPlan(mirrorFrame: before, visibleFrame: visibleFrame) { return before }
            try pressMirrorSmaller(pid: mirror.pid)
            guard let after = await waitForSizeChange(mirror, from: before) else {
                throw LayoutFailure(message: "镜像窗口已失效，排布已停止")
            }
            guard after.width < before.width - 1, after.height < before.height - 1 else {
                throw LayoutFailure(message: "系统没有进一步缩小镜像；请在显示设置中增加可用空间，或连接更大屏幕")
            }
            if case .success = Self.fittedPlan(mirrorFrame: after, visibleFrame: visibleFrame) { return after }
        }
        throw LayoutFailure(message: "镜像仍超出可用空间；请在显示设置中增加可用空间，或连接更大屏幕")
    }

    private func waitForSizeChange(_ window: ClientWindow, from previous: CGRect) async -> CGRect? {
        var last: CGRect?
        for _ in 0..<6 {
            do { try await Task.sleep(nanoseconds: 120_000_000) } catch { return nil }
            guard let current = window.liveFrame else { return nil }
            if let last, abs(current.width - last.width) < 1, abs(current.height - last.height) < 1,
               abs(current.width - previous.width) > 1 || abs(current.height - previous.height) > 1 { return current }
            last = current
        }
        return last
    }

    private func pressMirrorSmaller(pid: pid_t) throws {
        guard NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.ScreenContinuity" else {
            throw LayoutFailure(message: "镜像应用已退出，未发送菜单操作")
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.8)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            throw LayoutFailure(message: "镜像不允许直接改尺寸，且官方菜单不可读取；请手动选择“显示 → 缩小”")
        }
        let menuBar = unsafeBitCast(raw, to: AXUIElement.self)
        let displays = menuChildren(menuBar).filter { menuTitle($0) == "显示" }
        guard displays.count == 1, let display = displays.first else {
            throw LayoutFailure(message: "未找到已适配的“显示”菜单；请手动缩小镜像后重试")
        }
        // Exact path observed on this macOS installation: 显示 → 缩小.
        // Do not guess translated labels or traverse phone content.
        let menus = menuChildren(display)
        let items = menus.flatMap { menuChildren($0) }
        let smaller = items.filter { menuTitle($0) == "缩小" }
        guard smaller.count == 1, let item = smaller.first else {
            throw LayoutFailure(message: "官方“显示 → 缩小”菜单暂不可用；请手动缩小镜像后重试")
        }
        var enabled: CFTypeRef?
        let enabledStatus = AXUIElementCopyAttributeValue(item, kAXEnabledAttribute as CFString, &enabled)
        guard enabledStatus == .success, let isEnabled = enabled as? Bool else {
            throw LayoutFailure(message: "无法确认“缩小”菜单是否可用，未发送操作（AX=\(enabledStatus.rawValue)）")
        }
        guard isEnabled else {
            throw LayoutFailure(message: "镜像已到系统允许的最小尺寸；请增加屏幕可用空间，或连接更大屏幕")
        }
        let status = AXUIElementPerformAction(item, kAXPressAction as CFString)
        guard status == .success else {
            throw LayoutFailure(message: "系统未接受“缩小”菜单操作（AX=\(status.rawValue)）；请手动缩小后重试")
        }
    }

    private func menuChildren(_ element: AXUIElement) -> [AXUIElement] {
        AXUIElementSetMessagingTimeout(element, 0.8)
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count) == .success,
              count > 0, count <= 50 else { return [] }
        var raw: CFArray?
        guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, count, &raw) == .success,
              let values = raw as? [AnyObject] else { return [] }
        return values.compactMap { value in
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(value, to: AXUIElement.self)
        }
    }

    private func menuTitle(_ element: AXUIElement) -> String? {
        AXUIElementSetMessagingTimeout(element, 0.8)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &raw) == .success else { return nil }
        return raw as? String
    }

    private func setSize(_ size: CGSize, of element: AXUIElement, name: String = "AI") throws {
        var value = size
        guard let boxed = AXValueCreate(.cgSize, &value) else { throw LayoutFailure(message: "无法创建窗口尺寸") }
        let status = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, boxed)
        guard status == .success else {
            throw LayoutFailure(message: "设置\(name)窗口尺寸失败（AX=\(status.rawValue)）；请检查窗口后重试")
        }
    }

    private func verify(_ plan: LayoutPlan, agent: ClientWindow, mirror: ClientWindow,
                        successMessage: String) async -> LayoutResult {
        for attempt in 0..<6 {
            guard !Task.isCancelled else { return layoutResult(false, "布局等待已取消，请检查窗口位置", agent, mirror) }
            if let agentFrame = agent.liveFrame, let mirrorFrame = mirror.liveFrame,
               Self.framesMatch(agentFrame, plan.agentFrame), Self.framesMatch(mirrorFrame, plan.mirrorFrame) {
                return layoutResult(true, successMessage, agent, mirror)
            }
            if attempt < 5 { try? await Task.sleep(nanoseconds: 120_000_000) }
        }
        return layoutResult(false, "应用未接受目标布局，或窗口仍在变化；已停止自动调整，请检查两窗位置", agent, mirror)
    }

    nonisolated private static func validFrame(_ frame: CGRect) -> Bool {
        frame.minX.isFinite && frame.minY.isFinite && frame.width.isFinite && frame.height.isFinite
            && frame.width > 0 && frame.height > 0
    }

    nonisolated private static func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 4 && abs(lhs.minY - rhs.minY) <= 4
            && abs(lhs.width - rhs.width) <= 4 && abs(lhs.height - rhs.height) <= 4
    }

    nonisolated private static func contains(_ outer: CGRect, _ inner: CGRect) -> Bool {
        inner.minX >= outer.minX && inner.minY >= outer.minY
            && inner.maxX <= outer.maxX && inner.maxY <= outer.maxY
    }
    /// Move only our companion panel. The target AI and mirror windows are untouched.
    func moveCompanion(_ panel: NSWindow, beside target: ClientWindow) {
        guard let axFrame = target.liveFrame else { return }
        guard let primary = NSScreen.screens.first else { return }
        let targetFrame = CGRect(x: axFrame.minX, y: primary.frame.maxY - axFrame.maxY,
                                 width: axFrame.width, height: axFrame.height)
        let screen = NSScreen.screens.max { a, b in
            Self.intersectionArea(a.frame, targetFrame) < Self.intersectionArea(b.frame, targetFrame)
        } ?? primary
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let width = min(panel.frame.width, visible.width)
        let height = min(panel.frame.height, visible.height)
        let gap: CGFloat = 12
        var x = targetFrame.maxX + gap
        if x + width > visible.maxX { x = targetFrame.minX - gap - width }
        x = min(max(x, visible.minX), visible.maxX - width)
        let y = min(max(targetFrame.maxY - height, visible.minY), visible.maxY - height)
        let proposed = NSRect(x: x, y: y, width: width, height: height)
        if !panel.frame.equalTo(proposed) { panel.setFrame(proposed, display: true, animate: false) }
    }

    /// Places the companion strip above the target window with a hover
    /// buffer gap, so the mirror's top-edge menu remains accessible.
    func moveCompanionAbove(_ panel: NSWindow, above target: ClientWindow) {
        guard let axFrame = target.liveFrame else { return }
        guard let primary = NSScreen.screens.first else { return }
        let targetFrame = CGRect(x: axFrame.minX, y: primary.frame.maxY - axFrame.maxY,
                                 width: axFrame.width, height: axFrame.height)
        let screen = NSScreen.screens.max { a, b in
            Self.intersectionArea(a.frame, targetFrame) < Self.intersectionArea(b.frame, targetFrame)
        } ?? primary
        let visible = screen.visibleFrame
        let width = targetFrame.width
        let height = min(panel.frame.height, Self.companionHeight)
        // Strip bottom = mirror top + hoverBuffer (gap for the mirror's menu).
        let y = targetFrame.maxY + Self.hoverBuffer
        let x = targetFrame.minX
        let proposed = NSRect(x: x, y: y, width: width, height: height)
        if !panel.frame.equalTo(proposed) { panel.setFrame(proposed, display: true, animate: false) }
    }

    @discardableResult
    func focus(_ window: ClientWindow) -> Bool {
        focusRequest(window).accepted
    }

    /// AXFrontmost takes effect at once for a trusted process. Cooperative
    /// activation from a background app is often declined, which used to cost a
    /// full wait plus a LaunchServices round trip on every click.
    private func bringToFront(_ app: NSRunningApplication) -> Bool {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.2)
        let status = AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        lastFocusDiagnostics = "axFrontmost=\(status.rawValue)"
        if status == .success { return true }
        let activated: Bool
        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(to: app)
            activated = app.activate(from: .current, options: [])
        } else {
            activated = app.activate(options: [.activateIgnoringOtherApps])
        }
        lastFocusDiagnostics += "；activate=\(activated)"
        return activated
    }

    /// Undo the focus and pointer side effects of one click. Does nothing if the
    /// user has already moved to another app in the meantime.
    func returnFocus(to previous: NSRunningApplication?, from window: ClientWindow, cursor: CGPoint?) {
        if let cursor {
            CGWarpMouseCursorPosition(cursor)
            CGAssociateMouseAndMouseCursorPosition(1)
        }
        guard let previous, !previous.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid else { return }
        _ = bringToFront(previous)
    }

    private func focusRequest(_ window: ClientWindow, raise: Bool = true) -> (accepted: Bool, raised: Bool) {
        guard AccessibilityProbe.isTrusted,
              let app = NSRunningApplication(processIdentifier: window.pid), !app.isTerminated else { return (false, false) }
        let activated = bringToFront(app)
        let raised = raise ? raiseBoundWindow(window) : false
        let isFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid
        lastFocusDiagnostics += "；frontmost=\(isFrontmost)"
        return (activated || isFrontmost || raised, raised)
    }

    private func raiseBoundWindow(_ window: ClientWindow) -> Bool {
        guard !Task.isCancelled, AccessibilityProbe.isTrusted, let frame = window.liveFrame else { return false }
        do {
            let element = try accessibilityWindow(window, frame: frame)
            guard !Task.isCancelled, AccessibilityProbe.isTrusted,
                  let current = window.liveFrame, Self.framesMatch(current, frame) else { return false }
            var minimized: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &minimized)
            if (minimized as? Bool) == true {
                _ = AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            _ = AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
            let status = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            lastFocusDiagnostics += "；raise=\(status.rawValue)"
            return status == .success
        } catch let error as LayoutFailure {
            lastFocusDiagnostics += "；raise失败：\(error.message)"
            return false
        } catch {
            lastFocusDiagnostics += "；raise失败：未能解析绑定窗口"
            return false
        }
    }

    /// Activation requests are asynchronous on modern macOS. Only report ready
    /// after raising the bound window and verifying foreground plus the optional
    /// input point. LaunchServices reuses the existing app when activation fails.
    func focusForInteraction(_ window: ClientWindow, normalizedPoint: CGPoint? = nil) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard AccessibilityProbe.isTrusted, window.liveFrame != nil,
              let app = NSRunningApplication(processIdentifier: window.pid), !app.isTerminated else {
            lastFocusDiagnostics = "目标已退出、窗口不可见或辅助功能未授权"
            return false
        }
        guard !Task.isCancelled else { return false }
        // Mirroring rejects AXRaise, and resolving its AX window can block the
        // main actor, so try plain activation first. Readiness is proven by
        // foreground + hit testing, never by an accepted raise request.
        _ = focusRequest(window, raise: false)
        if await waitForInteraction(window, normalizedPoint: normalizedPoint, timeout: 0.2) { return true }
        guard !Task.isCancelled else { return false }
        // Being the frontmost application alone does not expose its bound window.
        _ = focusRequest(window)
        let initiallyReady = await waitForInteraction(window, normalizedPoint: normalizedPoint, timeout: 0.45)
        guard !Task.isCancelled else { return false }
        if initiallyReady { return true }
        // A cancelled playback click must not fall through to another activation
        // attempt after its foreground wait is interrupted.
        guard !Task.isCancelled else { return false }
        guard let applicationURL = app.bundleURL else {
            lastFocusDiagnostics += "；目标没有应用包URL，不能通过系统重新激活"
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        configuration.allowsRunningApplicationSubstitution = false
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        do {
            guard !Task.isCancelled else { return false }
            let activatedApp = try await NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration)
            guard !Task.isCancelled else { return false }
            guard activatedApp.processIdentifier == window.pid else {
                lastFocusDiagnostics += "；系统返回了不同PID，原绑定已失效"
                return false
            }
            _ = raiseBoundWindow(window)
            let ready = await waitForInteraction(window, normalizedPoint: normalizedPoint, timeout: 1.2)
            guard !Task.isCancelled else { return false }
            lastFocusDiagnostics += "；LaunchServices pid=\(activatedApp.processIdentifier) ready=\(ready)"
            return ready
        } catch {
            guard !Task.isCancelled else { return false }
            let nsError = error as NSError
            lastFocusDiagnostics += "；LaunchServices失败 \(nsError.domain):\(nsError.code)"
            return false
        }
    }

    /// Read-only input readiness check; it never activates or changes a window.
    func interactionTargetIsExposed(_ window: ClientWindow, normalizedPoint: CGPoint) -> Bool {
        guard AccessibilityProbe.isTrusted,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid,
              let frame = window.liveFrame,
              normalizedPoint.x.isFinite, normalizedPoint.y.isFinite,
              (0...1).contains(normalizedPoint.x), (0...1).contains(normalizedPoint.y) else { return false }
        let location = CGPoint(x: frame.minX + normalizedPoint.x * frame.width,
                               y: frame.minY + normalizedPoint.y * frame.height)
        var hitElement: AXUIElement?
        var hitPID: pid_t = 0
        return AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(location.x), Float(location.y), &hitElement) == .success
            && hitElement.map { AXUIElementGetPid($0, &hitPID) == .success && hitPID == window.pid } == true
    }

    private func waitForInteraction(_ window: ClientWindow, normalizedPoint: CGPoint?, timeout: TimeInterval) async -> Bool {
        func ready() -> Bool {
            guard !Task.isCancelled, AccessibilityProbe.isTrusted, window.liveFrame != nil,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid else { return false }
            return normalizedPoint.map { interactionTargetIsExposed(window, normalizedPoint: $0) } ?? true
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !Task.isCancelled && ProcessInfo.processInfo.systemUptime < deadline {
            if ready() { return true }
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
        return ready()
    }

    func mirrorWindows() -> [ClientWindow] {
        let probe = AccessibilityProbe()
        let windows = probe.windows(bundleIDs: ["com.apple.ScreenContinuity"])
        lastMirrorDiagnostics = probe.lastWindowDiagnostics
        if !windows.isEmpty { return windows }

        // Mirroring sometimes exposes AXWindows=[] while its remote video remains
        // onscreen. WindowServer metadata still supplies a precise window ID.
        let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "com.apple.ScreenContinuity" }
        let appsByPID = Dictionary(uniqueKeysWithValues: apps.map { ($0.processIdentifier, $0) })
        guard let records = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            lastMirrorDiagnostics += "；CG窗口元数据不可用"
            return []
        }
        var matches: [ClientWindow] = []
        for record in records {
            guard let pid = (record[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let app = appsByPID[pid],
                  (record[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (record[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
                  let windowID = (record[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds = record[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite,
                  frame.width > 100, frame.height > 200, frame.height > frame.width else { continue }
            let appElement = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appElement, 0.8)
            matches.append(ClientWindow(id: "\(pid):cg:\(windowID)", pid: pid,
                                        bundleID: "com.apple.ScreenContinuity", appName: app.localizedName ?? "iPhone 镜像",
                                        title: "iPhone 镜像 · \(windowID)", frame: frame,
                                        element: appElement, cgWindowID: windowID))
        }
        lastMirrorDiagnostics += "；CG主层竖屏窗口=\(matches.count)"
        // Never silently choose between multiple remote/video windows.
        guard matches.count == 1 else {
            if matches.count > 1 { lastMirrorDiagnostics += "（目标不唯一，未绑定）" }
            return []
        }
        return matches
    }

    private static func intersectionArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
}
