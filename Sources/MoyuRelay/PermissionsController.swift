import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation

/// Displays system-reported authorization. Toggles are entry points to the
/// system permission UI, never local switches pretending to grant or revoke it.
@MainActor
final class PermissionsController: ObservableObject {
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var accessibilitySettingsOpened = false
    @Published private(set) var screenCaptureGranted = false
    @Published private(set) var audioCaptureGranted = false
    @Published private(set) var message = ""

    let accessibilityExplanation = "用于窗口并排、轮廓提醒，以及向镜像视频发送一次播放或暂停点击。"
    let screenCaptureExplanation = "只在任务事件到达时读取镜像画面，常规两帧、静止时补一帧；不保存、不上传。"

    private var activationObserver: NSObjectProtocol?
    private let readAccessibility: () -> Bool
    private let readScreenCapture: () -> Bool
    private let readAudioCapture: () -> Bool
    private let openURL: (URL) -> Bool

    init(
        readAccessibility: @escaping () -> Bool = { AXIsProcessTrusted() },
        readScreenCapture: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
        readAudioCapture: @escaping () -> Bool = { false },
        openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.readAccessibility = readAccessibility
        self.readScreenCapture = readScreenCapture
        self.readAudioCapture = readAudioCapture
        self.openURL = openURL
        refresh()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    /// Both preflight functions read current process authorization without a prompt.
    func refresh() {
        let accessibility = readAccessibility()
        let screenCapture = readScreenCapture()
        if accessibilityGranted != accessibility { accessibilityGranted = accessibility }
        if screenCaptureGranted != screenCapture { screenCaptureGranted = screenCapture }
        let audioCapture = readAudioCapture()
        if audioCaptureGranted != audioCapture { audioCaptureGranted = audioCapture }
    }

    /// One explicit action opens one settings route, without a second OS prompt.
    /// Opening that route never substitutes for current process authorization.
    func requestAccessibility() {
        refresh()
        guard !accessibilityGranted else {
            message = "辅助功能授权已生效。"
            return
        }
        _ = openAccessibilitySettings()
    }

    /// Re-check without opening or changing any system UI.
    @discardableResult
    func checkAccessibility() -> Bool {
        refresh()
        message = accessibilityGranted
            ? "辅助功能授权已生效。"
            : "尚未检测到辅助功能授权。请在系统设置中允许“\(applicationName)”，然后再次检查授权。"
        return accessibilityGranted
    }

    /// Helps the user identify this installed copy when managing system access.
    func revealCurrentApplication() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    /// Like Accessibility, use exactly one settings route. Do not combine a
    /// system permission alert with a second independently opened settings pane.
    func requestScreenCapture() {
        refresh()
        guard !screenCaptureGranted else {
            message = "屏幕录制授权已生效。"
            return
        }
        _ = openScreenCaptureSettings()
    }

    func setAccessibilityRequested(_ requested: Bool) {
        if requested {
            requestAccessibility()
        } else {
            if openAccessibilitySettings() {
                message = "请在系统设置中关闭辅助功能授权。开关显示系统实际状态，返回应用时会重新检查。"
            }
            refresh()
        }
    }

    func setScreenCaptureRequested(_ requested: Bool) {
        if requested {
            requestScreenCapture()
        } else {
            if openScreenCaptureSettings() {
                message = "请在系统设置中关闭屏幕录制授权。开关显示系统实际状态，返回应用时会重新检查。"
            }
            refresh()
        }
    }

    @discardableResult
    func openAccessibilitySettings() -> Bool {
        let opened = openPrivacySettings(
            pane: "Privacy_Accessibility",
            title: "辅助功能",
            instruction: "请在系统设置的辅助功能权限页管理“\(applicationName)”授权；返回应用后会重新检查实际状态。"
        )
        if opened { accessibilitySettingsOpened = true }
        return opened
    }

    @discardableResult
    func openAudioCaptureSettings() -> Bool {
        openPrivacySettings(
            pane: "Privacy_AudioCapture",
            title: "系统音频录制",
            instruction: "请在系统设置的音频录制权限页管理“\(applicationName)”授权；返回应用后会重新检查实际状态。"
        )
    }

    @discardableResult
    func openScreenCaptureSettings() -> Bool {
        openPrivacySettings(
            pane: "Privacy_ScreenCapture",
            title: "屏幕录制",
            instruction: "请在系统设置的屏幕录制权限页管理“\(applicationName)”授权；如系统要求重新打开应用，请按系统提示操作。"
        )
    }

    private var applicationName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "Vibe Fishing"
    }

    @discardableResult
    private func openPrivacySettings(pane: String, title: String, instruction: String) -> Bool {
        // Best-effort deep links: acceptance of a URL is not proof that a
        // particular settings pane was displayed on every macOS version.
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"),
              openURL(url) else {
            message = "无法打开\(title)设置。请手动进入“系统设置 → 隐私与安全性 → \(title)”。"
            refresh()
            return false
        }
        message = instruction
        refresh()
        return true
    }
}
