#!/usr/bin/env python3
"""Exercise the production local controller with actual, silent AVPlayer items.

No screen capture, phone, UI, network, or AI events are used. The runner makes
two tiny silent PCM files in an isolated test folder; AVPlayer loads and plays
those files with muted output and without a view. This verifies transport and
queue behavior, not a particular video codec or video rendering. The production
source is copied verbatim except for private visibility so selection and stale
item handling can be exercised without a file picker. Generated artifacts stay
in .build/local-playback-tests.

Usage: python3 scripts/test-local-playback.py
"""

from __future__ import annotations

import os
from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Sources/MoyuRelay/PlaybackController.swift"
BUILD = ROOT / ".build/local-playback-tests"

HARNESS = r'''
@main
struct LocalPlaybackChecks {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
            .appendingPathComponent("media-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            precondition(condition(), label)
            checks += 1
            print("PASS \(label)")
        }
        func pause(_ seconds: Double = 0.1) async {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        func eventually(_ predicate: @escaping @MainActor () -> Bool) async -> Bool {
            for _ in 0..<500 {
                if predicate() { return true }
                await pause(0.01)
            }
            return predicate()
        }
        func makeClip(_ url: URL) throws {
            // Standard PCM needs no encoder service, camera, or audio capture.
            let sampleBytes: UInt32 = 8_000 * 2 * 3 / 2
            var data = Data()
            func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
            func little<T: FixedWidthInteger>(_ value: T) {
                var encoded = value.littleEndian
                withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
            }
            ascii("RIFF"); little(UInt32(36) + sampleBytes); ascii("WAVE")
            ascii("fmt "); little(UInt32(16)); little(UInt16(1)); little(UInt16(1))
            little(UInt32(8_000)); little(UInt32(16_000)); little(UInt16(2)); little(UInt16(16))
            ascii("data"); little(sampleBytes)
            data.append(Data(repeating: 0, count: Int(sampleBytes)))
            try data.write(to: url)
        }

        let firstURL = root.appendingPathComponent("episode-1.wav")
        let secondURL = root.appendingPathComponent("episode-2.wav")
        try makeClip(firstURL)
        try makeClip(secondURL)
        let controller = PlaybackController()
        controller.player.isMuted = true
        var ended = 0, failures = 0
        controller.onEnded = { ended += 1 }
        controller.onFailure = { _ in failures += 1 }
        controller.changeKind(.local)
        check(!controller.hasLocalVideos && controller.localState == .empty && !controller.isPlaying,
              "empty local player is observed as empty")
        check(controller.observedStateCaption == "尚未选择视频", "empty caption does not claim paused")
        controller.selectVideos([secondURL, firstURL])
        check(controller.hasLocalVideos && controller.videoNames == ["episode-1.wav", "episode-2.wav"],
              "selection keeps natural episode order")
        check(!controller.isPlaying, "loading a real item does not optimistically report playing")
        if controller.player.currentItem?.status == .unknown {
            check(controller.localState == .waiting, "unknown real item status is preparing, not paused")
        }
        let ready = await eventually { controller.localState == .paused }
        check(ready && controller.player.currentItem?.status == .readyToPlay,
              "real ready item plus paused transport establishes paused")
        let firstItem = controller.player.currentItem!
        controller.play()
        check(controller.isPlaying == (controller.player.timeControlStatus == .playing
            && firstItem.status == .readyToPlay), "play request reflects actual transport status immediately")
        controller.play()
        check(controller.player.currentItem === firstItem && controller.videoIndex == 0 && controller.wantsPlayback,
              "repeated play preserves the current episode and intent")
        let started = await eventually { controller.isPlaying }
        check(started && controller.player.timeControlStatus == .playing,
              "actual AVPlayer playback updates observed playing state")
        controller.pause()
        controller.pause()
        let paused = await eventually { controller.localState == .paused }
        check(paused && !controller.wantsPlayback && !controller.isPlaying,
              "repeated pause clears intent and observes paused transport")
        let pausedAt = firstItem.currentTime().seconds
        await pause(0.15)
        check(controller.player.currentItem === firstItem
            && abs(firstItem.currentTime().seconds - pausedAt) < 0.02,
              "pause holds position without replacing or rewinding the item")

        controller.play()
        let continued = await eventually { controller.videoIndex == 1 }
        check(continued && controller.wantsPlayback && controller.player.currentItem !== firstItem,
              "natural end advances using playback intent despite transport stopping")
        let completed = await eventually { ended == 1 }
        check(completed && controller.videoIndex == 1 && !controller.wantsPlayback,
              "natural end of final episode finishes the queue once")
        check(controller.localState == .paused && !controller.isPlaying,
              "completed queue observes paused transport")
        controller.play()
        check(controller.videoIndex == 0 && controller.player.currentItem !== firstItem,
              "play after queue completion loads first episode")
        controller.pause()
        await pause(0.2)
        check(!controller.wantsPlayback && !controller.isPlaying && controller.videoIndex == 0,
              "pause during asynchronous load prevents later callbacks from autoplaying")
        controller.didReachEnd(firstItem)
        check(controller.videoIndex == 0 && ended == 1 && !controller.wantsPlayback,
              "stale end callback for replaced item cannot advance new queue")

        let brokenURL = root.appendingPathComponent("00-broken.mov")
        try Data("not a video".utf8).write(to: brokenURL)
        controller.selectVideos([secondURL, brokenURL])
        controller.play()
        let failedItem = controller.player.currentItem!
        let failed = await eventually { controller.localState == .failed }
        check(failed && failedItem.status == .failed && failures == 1,
              "real corrupt file reports failed once")
        check(controller.videoIndex == 0 && !controller.wantsPlayback && !controller.isPlaying,
              "failed episode stops intent without skipping to a later file")
        controller.play()
        controller.pause()
        controller.refreshLocalObservation()
        await pause()
        check(failures == 1 && controller.player.currentItem === failedItem && controller.localState == .failed,
              "repeated requests and observations do not retry or duplicate a failure")
        controller.selectVideos([firstURL])
        let recovered = await eventually { controller.localState == .paused }
        check(recovered && failures == 1, "selecting a valid replacement recovers current item state")
        controller.didReachEnd(failedItem)
        check(controller.videoIndex == 0 && ended == 1 && !controller.wantsPlayback,
              "failed old item cannot affect a newly selected video")
        controller.play()
        controller.changeKind(.story)
        await pause()
        check(!controller.isPlaying && controller.player.timeControlStatus == .paused,
              "switching kind pauses local transport and ignores late local observations")
        controller.play()
        await pause()
        controller.tick()
        check(controller.isPlaying && controller.position > 0, "story compatibility remains functional")
        controller.changeKind(.mirror)
        controller.play()
        check(!controller.isPlaying && controller.player.timeControlStatus == .paused,
              "mirror selection never starts the local AVPlayer")
        print("\(checks) local playback checks passed using real AVPlayer items.")
    }
}
'''


def main() -> None:
    if sys.platform != "darwin":
        raise SystemExit("These checks require macOS and Apple Command Line Tools.")
    BUILD.mkdir(parents=True, exist_ok=True)
    source = re.sub(r"\bprivate(?:\(set\))?\s+", "", SOURCE.read_text(encoding="utf-8"))
    generated = BUILD / "LocalPlaybackChecks.swift"
    generated.write_text(source + "\n" + HARNESS, encoding="utf-8")
    executable = BUILD / "local-playback-checks"
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
