import AppKit
import ApplicationServices
import QuartzCore
import RelayCore

/// A click-through outline belonging to this app. It neither activates nor
/// changes the target window, and never asks for keyboard or mouse focus.
@MainActor
final class AttentionPresenter {
    private var panel: AttentionPanel?
    private var geometryTimer: Timer?
    private var previewTimeout: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var localEscapeMonitor: Any?
    private var globalEscapeMonitor: Any?
    private var targetPID: pid_t?
    private var targetWindowID: CGWindowID?
    private var currentWindowFrame: NSRect?
    private var shownAtUptime: TimeInterval = 0
    private var generation = UUID()
    private(set) var isVisible = false

    /// Only a uniquely identified, visible target gets an outline. The outline
    /// stays until the user returns, the target disappears, or a new turn starts.
    @discardableResult
    func show(kind: AgentState, target: ClientWindow?, allowSound: Bool) -> Bool {
        dismiss()
        guard [.completed, .needsInput, .failed, .cancelled].contains(kind),
              let target,
              let app = NSRunningApplication(processIdentifier: target.pid),
              !app.isTerminated, !app.isHidden else { return false }
        // Bound this one-time AX lookup; subsequent geometry updates read only
        // Window Server metadata, without scanning the AI app's controls.
        AXUIElementSetMessagingTimeout(target.element, 0.08)
        guard let identifier = resolveWindowID(target),
              let frame = windowFrame(identifier, pid: target.pid) else { return false }
        targetPID = target.pid
        targetWindowID = identifier
        present(frame: frame, kind: kind, allowSound: allowSound)
        installReturnObservers()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateGeometry() }
        }
        geometryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        return true
    }

    /// Preview uses the middleware's own window, in AppKit screen coordinates.
    /// It needs no AI window or Accessibility permission.
    func preview(frame: NSRect, allowSound: Bool) {
        dismiss()
        guard AttentionOutlineGeometry.isUsable(frame) else { return }
        present(frame: frame, kind: .completed, allowSound: allowSound)
        let token = generation
        previewTimeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
            guard self?.generation == token else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        generation = UUID()
        geometryTimer?.invalidate()
        geometryTimer = nil
        previewTimeout?.cancel()
        previewTimeout = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        for monitor in [localMouseMonitor, globalMouseMonitor, localEscapeMonitor, globalEscapeMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        localMouseMonitor = nil
        globalMouseMonitor = nil
        localEscapeMonitor = nil
        globalEscapeMonitor = nil
        panel?.orderOut(nil)
        panel = nil
        targetPID = nil
        targetWindowID = nil
        currentWindowFrame = nil
        isVisible = false
    }

    private func present(frame: NSRect, kind: AgentState, allowSound: Bool) {
        generation = UUID()
        shownAtUptime = ProcessInfo.processInfo.systemUptime
        currentWindowFrame = frame
        let outline = AttentionPanel(contentRect: AttentionOutlineGeometry.panelFrame(for: frame),
                                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        outline.isReleasedWhenClosed = false
        outline.isOpaque = false
        outline.backgroundColor = .clear
        outline.hasShadow = false
        outline.level = .normal
        outline.hidesOnDeactivate = false
        outline.becomesKeyOnlyIfNeeded = true
        outline.ignoresMouseEvents = true
        outline.isMovable = false
        outline.isExcludedFromWindowsMenu = true
        outline.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        outline.title = "Vibe Fishing · 窗口轮廓提醒"
        let accent = kind == .completed
            ? NSColor(srgbRed: 0.05, green: 0.78, blue: 0.70, alpha: 1)
            : NSColor(srgbRed: 1.0, green: 0.63, blue: 0.22, alpha: 1)
        outline.contentView = AttentionOutlineView(accent: accent)
        panel = outline
        isVisible = true
        orderAboveTarget()
        installEscapeObservers()
        if allowSound { NSSound(named: NSSound.Name(kind == .needsInput ? "Pop" : "Glass"))?.play() }
    }

    private func orderAboveTarget() {
        guard let panel else { return }
        if let targetWindowID {
            // Only the reminder panel is ordered; the AI window is untouched.
            panel.order(.above, relativeTo: Int(targetWindowID))
        } else {
            panel.orderFrontRegardless()
        }
    }

    private func updateGeometry() {
        guard let pid = targetPID, let identifier = targetWindowID,
              let app = NSRunningApplication(processIdentifier: pid),
              !app.isTerminated, !app.isHidden,
              let frame = windowFrame(identifier, pid: pid) else {
            dismiss()
            return
        }
        if currentWindowFrame != frame {
            currentWindowFrame = frame
            panel?.setFrame(AttentionOutlineGeometry.panelFrame(for: frame), display: true)
        }
        orderAboveTarget()
    }

    private func installReturnObservers() {
        let token = generation
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let activatedPID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            Task { @MainActor in
                guard let self, self.generation == token, let targetPID = self.targetPID,
                      activatedPID == targetPID, self.targetIsFrontWindow() else { return }
                self.dismiss()
            }
        }
        // Activating an already-frontmost AI app emits no activation notification.
        // A subsequent click inside its selected window still acknowledges it.
        let mouseMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseMask) { [weak self] event in
            let timestamp = event.timestamp
            let point = NSEvent.mouseLocation
            Task { @MainActor in self?.handleClick(at: point, timestamp: timestamp, generation: token) }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseMask) { [weak self] event in
            self?.handleClick(at: NSEvent.mouseLocation, timestamp: event.timestamp, generation: token)
            return event
        }
    }

    private func handleClick(at point: NSPoint, timestamp: TimeInterval, generation token: UUID) {
        guard generation == token, timestamp >= shownAtUptime,
              let pid = targetPID, let frame = currentWindowFrame,
              AttentionOutlineGeometry.acknowledgesReturn(point: point, targetFrame: frame,
                targetPID: pid, frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier),
              targetIsFrontWindow(at: point) else { return }
        dismiss()
    }

    private func targetIsFrontWindow(at point: CGPoint? = nil) -> Bool {
        guard let identifier = targetWindowID, let pid = targetPID,
              let primary = NSScreen.screens.first,
              let records = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        for record in records {
            guard (record[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let owner = (record[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  owner != ProcessInfo.processInfo.processIdentifier,
                  let windowID = (record[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
            if let point {
                guard let bounds = record[kCGWindowBounds as String] as? [String: Any],
                      let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                      let appKitFrame = AttentionOutlineGeometry.appKitFrame(forAX: frame, primaryTop: primary.frame.maxY),
                      appKitFrame.contains(point) else { continue }
            } else if owner != pid { continue }
            return owner == pid && windowID == identifier
        }
        return false
    }

    private func installEscapeObservers() {
        let token = generation
        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, self?.generation == token { self?.dismiss() }
            return event
        }
        if AXIsProcessTrusted() {
            globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53 else { return }
                Task { @MainActor in
                    if self?.generation == token { self?.dismiss() }
                }
            }
        }
    }

    private func resolveWindowID(_ target: ClientWindow) -> CGWindowID? {
        if let identifier = target.cgWindowID {
            return windowFrame(identifier, pid: target.pid) == nil ? nil : identifier
        }
        guard let current = target.liveFrame,
              let records = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let candidates = records.compactMap { record -> CGWindowID? in
            guard (record[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == target.pid,
                  (record[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let identifier = (record[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds = record[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  AttentionOutlineGeometry.framesMatch(frame, current) else { return nil }
            return identifier
        }
        // Never guess between overlapping windows from the same client.
        return candidates.count == 1 ? candidates.first : nil
    }

    private func windowFrame(_ identifier: CGWindowID, pid: pid_t) -> NSRect? {
        guard let primary = NSScreen.screens.first,
              let records = CGWindowListCopyWindowInfo(.optionIncludingWindow, identifier) as? [[String: Any]],
              let record = records.first(where: {
                  ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == identifier
                      && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
              }),
              (record[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
              let bounds = record[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              let converted = AttentionOutlineGeometry.appKitFrame(forAX: frame, primaryTop: primary.frame.maxY),
              NSScreen.screens.contains(where: { $0.frame.intersects(converted) }) else { return nil }
        return converted
    }

    deinit {
        geometryTimer?.invalidate()
        previewTimeout?.cancel()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        for monitor in [localMouseMonitor, globalMouseMonitor, localEscapeMonitor, globalEscapeMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

private final class AttentionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class AttentionOutlineView: NSView {
    private let stroke = CAShapeLayer()
    private let glow = CAShapeLayer()

    init(accent: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(false)
        for shape in [glow, stroke] {
            shape.fillColor = NSColor.clear.cgColor
            shape.strokeColor = accent.cgColor
            shape.lineWidth = 2.5
            shape.lineJoin = .round
            layer?.addSublayer(shape)
        }
        glow.shadowColor = accent.cgColor
        glow.shadowOffset = .zero
        glow.shadowOpacity = 0.85
        glow.shadowRadius = 7
        glow.opacity = 0.70
        stroke.opacity = 0.95
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let breathing = CABasicAnimation(keyPath: "opacity")
            breathing.fromValue = 0.35
            breathing.toValue = 0.90
            breathing.duration = 1.6
            breathing.autoreverses = true
            breathing.repeatCount = .infinity
            breathing.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            glow.add(breathing, forKey: "breathing")
        }
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let rect = AttentionOutlineGeometry.outlineRect(in: bounds)
        let path = CGPath(roundedRect: rect, cornerWidth: 12, cornerHeight: 12, transform: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shape in [glow, stroke] {
            shape.frame = bounds
            shape.path = path
        }
        // Shadow the thin ring, not the whole transparent window interior.
        glow.shadowPath = path.copy(strokingWithWidth: 2.5, lineCap: .round, lineJoin: .round, miterLimit: 4)
        CATransaction.commit()
    }
}
