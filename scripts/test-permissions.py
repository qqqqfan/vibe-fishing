#!/usr/bin/env python3
"""Exercise the production permission controller with injected OS boundaries.

These isolated checks neither read nor change actual permissions and never open
system settings, Finder, a permission prompt, a phone, or an AI application.
The production source is compiled unchanged alongside the generated harness.
Generated artifacts stay under .build/permissions-tests.
"""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / ".build/permissions-tests"
SOURCE = ROOT / "Sources/MoyuRelay/PermissionsController.swift"

HARNESS = r'''
import AppKit
import Combine
import Foundation

@main
struct PermissionChecks {
    @MainActor static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            precondition(condition(), label)
            checks += 1
            print("PASS \(label)")
        }

        var accessibility = false
        var capture = false
        var openedURLs: [URL] = []
        let controller = PermissionsController(
            readAccessibility: { accessibility },
            readScreenCapture: { capture },
            openURL: { openedURLs.append($0); return true }
        )
        var changes: [Bool] = []
        let subscription = controller.$accessibilityGranted.sink { changes.append($0) }
        defer { subscription.cancel() }
        check(!controller.accessibilityGranted && !controller.screenCaptureGranted
            && !controller.accessibilitySettingsOpened && openedURLs.isEmpty,
            "initial reads do not open settings or imply authorization")

        controller.requestAccessibility()
        check(openedURLs.count == 1
            && openedURLs[0].absoluteString == "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "one unauthorized request opens exactly the accessibility settings route")
        check(controller.accessibilitySettingsOpened && !controller.accessibilityGranted && changes == [false],
            "opening settings records the visit without granting access or publishing true")

        check(!controller.checkAccessibility(), "checking denied access returns false")
        check(openedURLs.count == 1 && controller.message.contains("尚未检测到辅助功能授权"),
            "checking denied access explains the result without reopening settings")
        controller.refresh()
        check(changes == [false], "repeated unchanged refresh does not republish authorization")

        accessibility = true
        check(controller.checkAccessibility() && controller.accessibilityGranted,
            "checking a newly granted OS state updates current authorization")
        check(changes == [false, true] && controller.message == "辅助功能授权已生效。",
            "a real grant publishes true and reports that it took effect")
        check(openedURLs.count == 1, "a successful authorization check has no settings side effect")

        accessibility = false
        controller.refresh()
        check(!controller.accessibilityGranted && changes == [false, true, false],
            "revocation updates and publishes false")
        check(controller.accessibilitySettingsOpened,
            "a prior settings visit is independent of current authorization")

        accessibility = true
        controller.requestAccessibility()
        check(controller.accessibilityGranted && changes == [false, true, false, true],
            "request reads actual authorization even when the cached state was false")
        check(openedURLs.count == 1 && controller.message == "辅助功能授权已生效。",
            "already authorized request does not reopen settings")

        capture = true
        controller.refresh()
        check(controller.screenCaptureGranted && controller.accessibilityGranted && openedURLs.count == 1,
            "screen capture preflight remains independent and does not open settings")
        controller.requestScreenCapture()
        check(openedURLs.count == 1 && controller.message == "屏幕录制授权已生效。",
            "authorized capture request does not launch settings or a permission alert")
        capture = false
        controller.requestScreenCapture()
        check(!controller.screenCaptureGranted && openedURLs.count == 2
            && openedURLs.last?.absoluteString == "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "unauthorized capture request opens only its settings route")
        controller.refresh()
        check(!controller.screenCaptureGranted && openedURLs.count == 2,
            "returning without a grant does not infer permission or reopen UI")
        capture = true
        controller.refresh()
        check(controller.screenCaptureGranted && openedURLs.count == 2,
            "a real capture grant updates authorization without opening UI")

        var failedOpens = 0
        let failed = PermissionsController(
            readAccessibility: { false }, readScreenCapture: { false },
            openURL: { _ in failedOpens += 1; return false }
        )
        failed.requestAccessibility()
        check(failedOpens == 1 && !failed.accessibilitySettingsOpened && !failed.accessibilityGranted,
            "failed settings launch does not mark settings opened or access granted")
        check(failed.message.contains("无法打开辅助功能设置"),
            "failed settings launch retains an actionable error")
        check(!failed.checkAccessibility() && failedOpens == 1,
            "checking after a failed launch never retries the URL implicitly")

        var directOpens = 0
        let direct = PermissionsController(
            readAccessibility: { false }, readScreenCapture: { false },
            openURL: { _ in directOpens += 1; return true }
        )
        check(direct.openAccessibilitySettings() && direct.accessibilitySettingsOpened
            && directOpens == 1 && !direct.accessibilityGranted,
            "direct settings management also records a successful visit without granting access")
        print("\(checks) isolated permission checks passed.")
    }
}
'''


def main() -> None:
    if sys.platform != "darwin":
        raise SystemExit("These checks require macOS and Apple Command Line Tools.")
    BUILD.mkdir(parents=True, exist_ok=True)
    harness = BUILD / "PermissionChecks.swift"
    harness.write_text(HARNESS, encoding="utf-8")
    executable = BUILD / "permission-checks"
    environment = os.environ.copy()
    environment["DEVELOPER_DIR"] = "/Library/Developer/CommandLineTools"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
        "-module-cache-path", str(BUILD / "ModuleCache"),
        str(SOURCE), str(harness), "-o", str(executable),
    ], check=True, env=environment)
    subprocess.run([str(executable)], check=True, env=environment)


if __name__ == "__main__":
    main()
