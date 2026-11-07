import XCTest
@testable import RelayCore

final class MirrorInputPolicyTests: XCTestCase {
    func testForegroundMirrorPointerInputSurvivesUnrelatedRoutingPID() {
        // Physical clicks and scrolls may be reported as routed through a
        // forwarding process. The foreground hit must still invalidate playback.
        XCTAssertTrue(MirrorInputPolicy.affectsMirror(isKeyboard: false,
            routedToMirror: false, mirrorIsFrontmost: true,
            pointInsideMirror: true, topmostHitIsMirror: false))
        XCTAssertTrue(MirrorInputPolicy.affectsMirror(isKeyboard: false,
            routedToMirror: false, mirrorIsFrontmost: true,
            pointInsideMirror: true, topmostHitIsMirror: true))
    }

    func testBackgroundMirrorScrollUsesTheWindowUnderThePointer() {
        // macOS allows scrolling a background window without activating it.
        XCTAssertTrue(MirrorInputPolicy.affectsMirror(isKeyboard: false,
            routedToMirror: false, mirrorIsFrontmost: false,
            pointInsideMirror: true, topmostHitIsMirror: true))
    }

    func testClickingBackToCodexDoesNotInvalidateMirrorPlayback() {
        XCTAssertFalse(MirrorInputPolicy.affectsMirror(isKeyboard: false,
            routedToMirror: false, mirrorIsFrontmost: false,
            pointInsideMirror: false, topmostHitIsMirror: false))
        // The activation notification may still name the mirror on mouse-down;
        // foreground status alone does not turn an outside click into input.
        XCTAssertFalse(MirrorInputPolicy.affectsMirror(isKeyboard: false,
            routedToMirror: false, mirrorIsFrontmost: true,
            pointInsideMirror: false, topmostHitIsMirror: false))
    }

    func testOverlappingWindowReceivesItsOwnClickWithoutFalseInvalidation() {
        // A point can be geometrically inside the mirror while another app
        // covers it. The mirror rectangle alone is insufficient evidence.
        XCTAssertFalse(MirrorInputPolicy.affectsMirror(isKeyboard: false,
            routedToMirror: false, mirrorIsFrontmost: false,
            pointInsideMirror: true, topmostHitIsMirror: false))
    }

    func testExplicitMirrorRoutingDoesNotRequireForegroundOrGeometry() {
        XCTAssertTrue(MirrorInputPolicy.affectsMirror(isKeyboard: false,
            routedToMirror: true, mirrorIsFrontmost: false,
            pointInsideMirror: false, topmostHitIsMirror: false))
    }

    func testMirrorKeyboardInputUsesFocusOrExplicitRouting() {
        XCTAssertTrue(MirrorInputPolicy.affectsMirror(isKeyboard: true,
            routedToMirror: false, mirrorIsFrontmost: true,
            pointInsideMirror: false, topmostHitIsMirror: false))
        XCTAssertTrue(MirrorInputPolicy.affectsMirror(isKeyboard: true,
            routedToMirror: true, mirrorIsFrontmost: false,
            pointInsideMirror: false, topmostHitIsMirror: false))
    }

    func testTypingInCodexIgnoresPointerHoveringOverMirror() {
        XCTAssertFalse(MirrorInputPolicy.affectsMirror(isKeyboard: true,
            routedToMirror: false, mirrorIsFrontmost: false,
            pointInsideMirror: true, topmostHitIsMirror: true))
        XCTAssertFalse(MirrorInputPolicy.affectsMirror(isKeyboard: true,
            routedToMirror: false, mirrorIsFrontmost: false,
            pointInsideMirror: false, topmostHitIsMirror: false))
    }

    func testRecognizedManualMirrorInputInvalidatesAnOutstandingPause() throws {
        var playback = MirrorToggleState()
        _ = playback.confirm(.playing, now: 100)
        _ = playback.request(.paused, now: 101)
        let stalePause = try XCTUnwrap(playback.observe(.playing, epoch: playback.epoch, now: 101.01))
        let manualMirrorInput = MirrorInputPolicy.affectsMirror(isKeyboard: false,
            routedToMirror: false, mirrorIsFrontmost: true,
            pointInsideMirror: true, topmostHitIsMirror: false)
        XCTAssertTrue(manualMirrorInput)
        if manualMirrorInput { playback.invalidate() }

        XCTAssertEqual(playback.state, .unknown)
        XCTAssertNil(playback.desiredState)
        XCTAssertFalse(playback.canPost(stalePause, now: 101.1))
        XCTAssertFalse(playback.didPost(stalePause, now: 101.1))
        XCTAssertNil(playback.tick(now: 102))
    }
}
