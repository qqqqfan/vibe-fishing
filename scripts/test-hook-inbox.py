#!/usr/bin/env python3
"""Exercise the production hook inbox watcher against isolated directories.

No real hook inbox, hook configuration, application UI, or agent events are used.
The runner extracts HookInboxDirectoryWatcher from RelayStore.swift and only
relaxes private visibility in its generated copy. Tests exercise real Dispatch
filesystem notifications, cancellation, and descriptor ownership. The queued
callback case uses the production enqueue method to reproduce a pending callback
before a session switch. All generated files and scratch directories stay under
.build/hook-inbox-tests; each run removes its isolated scratch directories.

Usage: python3 scripts/test-hook-inbox.py
"""

from __future__ import annotations

import os
from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Sources/MoyuRelay/RelayStore.swift"
BUILD = ROOT / ".build/hook-inbox-tests"

HARNESS = r'''
@main
struct InboxWatcherChecks {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
            .appendingPathComponent("filesystem-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var count = 0
        func check(_ valid: @autoclosure () -> Bool, _ label: String) {
            guard valid() else { fatalError("FAIL: \(label)") }
            count += 1
            print("PASS \(label)")
        }
        func folder(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        func write(_ file: URL) throws { try Data("{}".utf8).write(to: file, options: .atomic) }
        func pause() async { try? await Task.sleep(nanoseconds: 100_000_000) }
        func eventually(_ predicate: @escaping @MainActor () -> Bool) async -> Bool {
            for _ in 0..<100 {
                if predicate() { return true }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return predicate()
        }

        do {
            let dir = try folder("delivery")
            try write(dir.appendingPathComponent("existing.json"))
            let watcher = HookInboxDirectoryWatcher()
            var changes = 0, unavailable = 0, names: Set<String> = []
            try watcher.start(at: dir) { change in
                switch change {
                case .contentsChanged:
                    changes += 1
                    names.formUnion((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
                case .directoryUnavailable: unavailable += 1
                }
            }
            check(names.contains("existing.json"), "initial read sees existing entry")
            check(changes == 1, "initial read occurs once synchronously after install")
            let temporary = dir.appendingPathComponent("arriving.tmp")
            try write(temporary)
            try fm.moveItem(at: temporary, to: dir.appendingPathComponent("arriving.json"))
            let delivered = await eventually { names.contains("arriving.json") }
            check(delivered, "atomic rename triggers a delivery")
            await pause()
            let settled = changes
            await pause()
            check(changes == settled, "no periodic reads while idle")
            check(unavailable == 0, "normal entry writes keep directory watch alive")
            let fd = watcher.descriptor!
            watcher.stop()
            let closed = await eventually { fcntl(fd, F_GETFD) == -1 && errno == EBADF }
            check(closed, "stop cancellation closes descriptor")
            try write(dir.appendingPathComponent("after-stop.json"))
            await pause()
            check(changes == settled, "stopped watcher ignores later writes")
        }
        do {
            let first = try folder("old-session"), next = try folder("new-session")
            let watcher = HookInboxDirectoryWatcher()
            var oldCalls = 0, newCalls = 0
            try watcher.start(at: first) { _ in oldCalls += 1 }
            watcher.enqueue(.write, generation: watcher.generation) // A main-actor delivery is pending, not yet run.
            watcher.stop()
            try watcher.start(at: next) { _ in newCalls += 1 }
            await pause()
            check(oldCalls == 1, "cancelled pending delivery cannot reach old session")
            check(newCalls == 1, "cancelled pending delivery cannot read new session")
            try write(first.appendingPathComponent("old-file.json"))
            await pause()
            check(oldCalls == 1 && newCalls == 1, "old directory events cannot wake new session")
            watcher.stop()
        }
        do {
            let dir = try folder("rename")
            let watcher = HookInboxDirectoryWatcher()
            var changes = 0, unavailable = 0
            try watcher.start(at: dir) { change in
                switch change {
                case .contentsChanged: changes += 1
                case .directoryUnavailable: unavailable += 1
                }
            }
            try fm.moveItem(at: dir, to: root.appendingPathComponent("renamed-away"))
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let invalidated = await eventually { unavailable == 1 }
            check(invalidated, "renamed/replaced directory invalidates watch")
            check(watcher.descriptor == nil, "invalidated watcher has stopped")
            try write(dir.appendingPathComponent("replacement.json"))
            await pause()
            check(changes == 1 && unavailable == 1, "replacement does not automatically retry or reattach")
        }
        do {
            let dir = try folder("delete")
            let watcher = HookInboxDirectoryWatcher()
            var unavailable = 0
            try watcher.start(at: dir) { change in
                if case .directoryUnavailable = change { unavailable += 1 }
            }
            try fm.removeItem(at: dir)
            let invalidated = await eventually { unavailable == 1 }
            check(invalidated, "deleted directory invalidates watch")
            await pause()
            check(unavailable == 1, "deleted directory reports once without retry")
        }
        do {
            let watcher = HookInboxDirectoryWatcher()
            var callbacks = 0, didThrow = false
            do { try watcher.start(at: root.appendingPathComponent("missing")) { _ in callbacks += 1 } }
            catch { didThrow = true }
            await pause()
            check(didThrow && callbacks == 0 && watcher.descriptor == nil, "missing directory fails without scheduling retries")
        }
        print("PASS: \(count) isolated directory watcher checks")
    }
}
'''


def main() -> None:
    if sys.platform != "darwin":
        raise SystemExit("These checks require macOS and Apple Command Line Tools.")
    BUILD.mkdir(parents=True, exist_ok=True)
    source = SOURCE.read_text(encoding="utf-8")
    marker = "@MainActor\nprivate final class HookInboxDirectoryWatcher {"
    if source.count(marker) != 1:
        raise SystemExit("Cannot uniquely locate the production inbox watcher.")
    # This helper is the last declaration in RelayStore.swift. Its implementation
    # stays verbatim; visibility alone changes for lifecycle assertions.
    watcher = marker + source.split(marker, 1)[1]
    watcher = re.sub(r"\bprivate(?:\(set\))?\s+", "", watcher)
    generated = BUILD / "InboxWatcherChecks.swift"
    generated.write_text("import Foundation\nimport Darwin\nimport Dispatch\n\n"
                         + watcher + "\n" + HARNESS, encoding="utf-8")
    executable = BUILD / "inbox-watcher-checks"
    environment = os.environ.copy()
    environment["DEVELOPER_DIR"] = "/Library/Developer/CommandLineTools"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
        "-module-cache-path", str(BUILD / "ModuleCache"), str(generated),
        "-o", str(executable),
    ], check=True, env=environment)
    subprocess.run([str(executable), str(BUILD)], check=True, env=environment)


if __name__ == "__main__":
    main()
