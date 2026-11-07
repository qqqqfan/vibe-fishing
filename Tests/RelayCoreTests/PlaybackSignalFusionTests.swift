import XCTest
@testable import RelayCore

final class PlaybackSignalFusionTests: XCTestCase {
    private func run(_ fusion: inout PlaybackSignalFusion, from start: Double, to end: Double,
                     audio: Double?, load: Double?) {
        var time = start
        while time <= end + 0.0001 {
            fusion.ingest(PlaybackSignalSample(time: time, audioLevelDB: audio, streamLoad: load))
            time += 0.1
        }
    }

    func testSoundReadsAsPlayingWithinTwoTicks() {
        var fusion = PlaybackSignalFusion()
        run(&fusion, from: 0, to: 0.1, audio: -14, load: 400)
        XCTAssertEqual(fusion.reading.state, .playing)
        XCTAssertTrue(fusion.reading.strong)
    }

    func testQuietLineInsidePlayingVideoStaysPlaying() {
        var fusion = PlaybackSignalFusion()
        run(&fusion, from: 0, to: 3, audio: -14, load: 400)
        run(&fusion, from: 3.1, to: 3.7, audio: -200, load: 400)
        XCTAssertEqual(fusion.reading.state, .playing)
        XCTAssertTrue(fusion.reading.settling)
    }

    func testStaticShotWithSoundIsNotPaused() {
        var fusion = PlaybackSignalFusion()
        run(&fusion, from: 0, to: 6, audio: -18, load: 10)
        XCTAssertEqual(fusion.reading.state, .playing)
    }

    func testSilenceAndStillStreamIsStrongPause() {
        var fusion = PlaybackSignalFusion()
        run(&fusion, from: 0, to: 3, audio: -14, load: 400)
        run(&fusion, from: 3.1, to: 4.5, audio: -200, load: 10)
        XCTAssertEqual(fusion.reading.state, .paused)
        XCTAssertTrue(fusion.reading.strong)
        XCTAssertFalse(fusion.reading.settling)
        XCTAssertEqual(fusion.reading.reason, .silentAndStill)
    }

    func testResumeIsDetectedFromFirstSound() {
        var fusion = PlaybackSignalFusion()
        run(&fusion, from: 0, to: 1, audio: -14, load: 400)
        run(&fusion, from: 1.1, to: 3, audio: -200, load: 10)
        XCTAssertEqual(fusion.reading.state, .paused)
        run(&fusion, from: 3.1, to: 3.2, audio: -14, load: 400)
        XCTAssertEqual(fusion.reading.state, .playing)
        XCTAssertEqual(fusion.reading.changedAt >= 3.1, true)
    }

    func testPausedPageWithBusyStreamReadsAsPaused() {
        // Field case 2026-11-05: paused Douyin, silent, stream load ~200-370.
        var fusion = PlaybackSignalFusion()
        run(&fusion, from: 0, to: 1, audio: -14, load: 400)
        run(&fusion, from: 1.1, to: 2.5, audio: -200, load: 300)
        XCTAssertEqual(fusion.reading.state, .paused)
        XCTAssertFalse(fusion.reading.strong)
        XCTAssertEqual(fusion.reading.reason, .silenceOnly)
    }

    func testLightInterfaceMotionWhilePausedResolvesToPaused() {
        var fusion = PlaybackSignalFusion()
        run(&fusion, from: 0, to: 1, audio: -14, load: 400)
        run(&fusion, from: 1.1, to: 4, audio: -200, load: 100)
        XCTAssertEqual(fusion.reading.state, .paused)
        XCTAssertFalse(fusion.reading.strong)
    }

    func testDigitalSilenceBeforeAnyRealAudioIsNotTrusted() {
        // Denied capture delivers zeros, so a moving stream must still win.
        var fusion = PlaybackSignalFusion()
        run(&fusion, from: 0, to: 2, audio: -200, load: 400)
        XCTAssertFalse(fusion.audioProven)
        XCTAssertEqual(fusion.reading.state, .playing)
        XCTAssertFalse(fusion.reading.strong)
        XCTAssertEqual(fusion.reading.reason, .streamMoving)
    }

    func testTrustedSilenceAfterLaunchIsPausedEvenIfScreenMoves() {
        // Field case 2026-11-05 18:56: app restarted with the video paused.
        var fusion = PlaybackSignalFusion()
        fusion.audioTrusted = true
        run(&fusion, from: 0, to: 2, audio: -200, load: 300)
        XCTAssertEqual(fusion.reading.state, .paused)
        fusion.reset()
        XCTAssertTrue(fusion.audioTrusted)
    }

    func testStreamOnlyPauseIsNeverStrong() {
        var fusion = PlaybackSignalFusion()
        run(&fusion, from: 0, to: 2, audio: nil, load: 10)
        XCTAssertEqual(fusion.reading.state, .paused)
        XCTAssertFalse(fusion.reading.strong)
    }

    func testAudioOnlyWhenStreamCannotBeRead() {
        var fusion = PlaybackSignalFusion()
        run(&fusion, from: 0, to: 1, audio: -14, load: nil)
        XCTAssertEqual(fusion.reading.state, .playing)
        run(&fusion, from: 1.1, to: 2.5, audio: -200, load: nil)
        XCTAssertEqual(fusion.reading.state, .paused)
        XCTAssertFalse(fusion.reading.strong)
    }

    func testNoSignalsStayUnknown() {
        var fusion = PlaybackSignalFusion()
        run(&fusion, from: 0, to: 5, audio: nil, load: nil)
        XCTAssertEqual(fusion.reading.state, .unknown)
        XCTAssertTrue(fusion.reading.settling)
    }

    func testOutOfOrderSampleIsIgnored() {
        var fusion = PlaybackSignalFusion()
        run(&fusion, from: 0, to: 1, audio: -14, load: 400)
        let before = fusion.reading
        XCTAssertFalse(fusion.ingest(PlaybackSignalSample(time: 0.2, audioLevelDB: -200, streamLoad: 10)))
        XCTAssertEqual(fusion.reading, before)
    }

    func testResetForgetsProvenAudio() {
        var fusion = PlaybackSignalFusion()
        run(&fusion, from: 0, to: 1, audio: -14, load: 400)
        fusion.reset()
        XCTAssertFalse(fusion.audioProven)
        XCTAssertEqual(fusion.reading.state, .unknown)
    }
}
