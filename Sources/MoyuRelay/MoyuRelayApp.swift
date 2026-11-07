import AppKit
import Combine
import SwiftUI
import RelayCore

@main
struct MoyuRelayApp: App {
    @NSApplicationDelegateAdaptor(RelayAppDelegate.self) private var delegate
    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class RelayAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var store: RelayStore!
    private var window: NSWindow!
    private var companion: NSPanel?
    /// True while the strip is tucked away because the mirror window is
    /// minimized (or its app hidden); it returns with the mirror.
    private var companionHiddenWithMirror = false
    private var status: NSStatusItem!
    private var flowSubscription: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // Ensure the Dock shows the brand icon even when LaunchServices has a
        // stale cache entry for this bundle path.
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        store = RelayStore()
        let content = RelayMainView(store: store)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 650), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Vibe Fishing"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.contentView = NSHostingView(rootView: content)
        window.minSize = NSSize(width: 420, height: 620)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        setupMenu()
        store.onToggleCompanion = { [weak self] in self?.toggleCompanion() }
        store.onTickCompanion = { [weak self] in self?.positionCompanion() }
        store.onShowDetails = { [weak self] in self?.showMain() }
        store.onHideDetails = { [weak self] in self?.window.performClose(nil) }
        store.onWorkspaceReady = {}
        store.onNeedsGuidance = { [weak self] in self?.showMain() }
        flowSubscription = store.launch.$flow
            .map { $0.status == .ready }
            .removeDuplicates()
            .sink { [weak self] ready in
                Task { @MainActor in
                    guard let self, ready else { return }
                    self.store.detailsVisible = false
                    self.window?.orderOut(nil)
                    if !self.store.companionVisible { self.toggleCompanion() }
                }
            }

    }

    private func setupMenu() {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = VFBrandAssets.menuBarIcon()
        let menu = NSMenu()
        let show = NSMenuItem(title: "打开 Vibe Fishing", action: #selector(showMain), keyEquivalent: "")
        show.target = self; menu.addItem(show)
        let start = NSMenuItem(title: "连接", action: #selector(startRelay), keyEquivalent: "")
        start.target = self; menu.addItem(start)
        menu.addItem(.separator())
        let pause = NSMenuItem(title: "断开连接", action: #selector(stopRelay), keyEquivalent: "")
        pause.target = self; menu.addItem(pause)
        let arrange = NSMenuItem(title: "重新并排", action: #selector(rearrangeLayout), keyEquivalent: "")
        arrange.target = self; menu.addItem(arrange)
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Vibe Fishing", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        status.menu = menu
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于 Vibe Fishing", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "卸载 Vibe Fishing…", action: #selector(uninstall), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Vibe Fishing", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑"); editItem.submenu = editMenu
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    @objc private func showMain() {
        store.detailsVisible = true
        companion?.orderOut(nil)
        store.companionVisible = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        store.detailsVisible = false
        store.mirror.recordingShortcut = false
        if store.launch.isStarted && !store.companionVisible { toggleCompanion() }
    }
    @objc private func uninstall() { store.uninstallEverything() }
    @objc private func startRelay() { showMain(); store.launch.startOrRetry() }
    @objc private func stopRelay() { store.launch.stop() }
    @objc private func rearrangeLayout() { showMain(); store.launch.rearrangeLayout() }
    @objc private func toggleCompanion() {
        guard !store.detailsVisible else { return }
        if let companion, companion.isVisible {
            companion.orderOut(nil)
            store.companionVisible = false
            return
        }
        if companion == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 276, height: 440), styleMask: [.titled, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "Vibe Fishing"
            panel.contentView = NSHostingView(rootView: CompanionView(store: store))
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isFloatingPanel = true
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.center()
            companion = panel
        }
        companion?.orderFrontRegardless()
        store.companionVisible = true
        positionCompanion()
    }

    private func positionCompanion() {
        guard let companion else { return }
        if companionHiddenWithMirror {
            if mirrorTucked() { return }
            companionHiddenWithMirror = false
            guard !store.detailsVisible else { return }
            companion.orderFrontRegardless()
        }
        guard companion.isVisible else { return }
        // The strip rides with the mirror: when the mirror window is minimized
        // or its app hidden, tuck the strip away instead of letting it float
        // above unrelated apps like Chrome.
        if mirrorTucked() {
            companionHiddenWithMirror = true
            companion.orderOut(nil)
            return
        }
        if let mirror = store.mirror.window {
            store.dock.moveCompanionAbove(companion, above: mirror)
        } else if let target = store.selectedWindow {
            store.dock.moveCompanion(companion, beside: target)
        }
    }

    /// The mirror window is minimized or its app is hidden.
    private func mirrorTucked() -> Bool {
        guard let mirror = store.mirror.window,
              let app = NSRunningApplication(processIdentifier: mirror.pid), !app.isTerminated else { return false }
        var minimized: CFTypeRef?
        if AXUIElementCopyAttributeValue(mirror.element, kAXMinimizedAttribute as CFString, &minimized) == .success,
           (minimized as? Bool) == true {
            return true
        }
        return app.isHidden
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMain()
        return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        store?.stopListening()
    }
}
