import XCTest
@testable import RelayCore

final class MirrorToggleStateTests: XCTestCase {
    private func prepare(_ sut: inout MirrorToggleState, from: MirrorPlaybackState,
                         to target: MirrorPlaybackState, now: TimeInterval) throws -> MirrorToggleCommand {
        XCTAssertNil(sut.request(target, now: now))
        XCTAssertTrue(sut.isAwaitingObservation)
        return try XCTUnwrap(sut.observe(from, epoch: sut.epoch, now: now + 0.1))
    }

    func testRequestDiscardsHumanBaselineAndRequiresFreshObservation() throws {
        var sut = MirrorToggleState()
        XCTAssertNil(sut.confirm(.paused, now: 99))
        XCTAssertEqual(sut.evidence, .confirmed)
        let baselineEpoch = sut.epoch
        XCTAssertNil(sut.request(.playing, now: 100))
        XCTAssertFalse(sut.epoch == baselineEpoch)
        XCTAssertEqual(sut.state, .unknown)
        XCTAssertEqual(sut.evidence, .unknown)
        XCTAssertTrue(sut.hasActiveRequest)
        XCTAssertTrue(sut.isAwaitingObservation)
        XCTAssertNil(sut.pendingCommand)
        let command = try XCTUnwrap(sut.observe(.paused, epoch: sut.epoch, now: 100.1))
        XCTAssertEqual(command.from, .paused)
        XCTAssertEqual(command.target, .playing)
        XCTAssertEqual(sut.evidence, .observed)
        XCTAssertTrue(sut.canPost(command, now: 100.2))
    }

    func testAlreadyAtTargetFinishesWithObservationAndNoClick() {
        var sut = MirrorToggleState()
        _ = sut.request(.paused, now: 100)
        XCTAssertNil(sut.observe(.paused, epoch: sut.epoch, now: 100.1))
        XCTAssertEqual(sut.state, .paused)
        XCTAssertEqual(sut.evidence, .observed)
        XCTAssertFalse(sut.hasActiveRequest)
        XCTAssertFalse(sut.isAwaitingObservation)
        XCTAssertFalse(sut.isSettling)
        XCTAssertNil(sut.pendingCommand)
        XCTAssertNil(sut.desiredState)
        XCTAssertNil(sut.tick(now: 500))
        XCTAssertEqual(sut.state, .paused)
    }

    func testSameTargetAfterCompletionRequiresAnotherFreshObservation() throws {
        var sut = MirrorToggleState()
        _ = sut.request(.paused, now: 100)
        _ = sut.observe(.paused, epoch: sut.epoch, now: 100.1)
        let completedEpoch = sut.epoch
        XCTAssertNil(sut.request(.paused, now: 101))
        XCTAssertFalse(sut.epoch == completedEpoch)
        XCTAssertEqual(sut.state, .unknown)
        XCTAssertNil(sut.pendingCommand)
        XCTAssertNil(sut.observe(.paused, epoch: completedEpoch, now: 101.1))
        XCTAssertTrue(sut.isAwaitingObservation)
        // The user may have started playing since the previous success.
        let command = try XCTUnwrap(sut.observe(.playing, epoch: sut.epoch, now: 101.2))
        XCTAssertEqual(command.from, .playing)
        XCTAssertEqual(command.target, .paused)
    }

    func testUnknownInitialObservationAbortsWithoutClickOrRetry() {
        var sut = MirrorToggleState()
        _ = sut.request(.playing, now: 100)
        let captureEpoch = sut.epoch
        XCTAssertNil(sut.observe(.unknown, epoch: captureEpoch, now: 100.2))
        XCTAssertEqual(sut.state, .unknown)
        XCTAssertEqual(sut.evidence, .unknown)
        XCTAssertFalse(sut.hasActiveRequest)
        XCTAssertNil(sut.pendingCommand)
        XCTAssertNil(sut.observe(.paused, epoch: captureEpoch, now: 100.3))
        XCTAssertNil(sut.observe(.paused, epoch: sut.epoch, now: 100.4))
        XCTAssertNil(sut.tick(now: 101))
        XCTAssertNil(sut.pendingCommand)
    }

    func testPostingRequiresNewObservationAndDoesNotInferSuccessFromTime() throws {
        var sut = MirrorToggleState(settleDelay: 0)
        let command = try prepare(&sut, from: .playing, to: .paused, now: 100)
        let beforeEpoch = sut.epoch
        XCTAssertTrue(sut.didPost(command, now: 100.2))
        XCTAssertFalse(sut.epoch == beforeEpoch)
        XCTAssertEqual(sut.state, .unknown)
        XCTAssertEqual(sut.evidence, .unknown)
        XCTAssertTrue(sut.isSettling)
        XCTAssertFalse(sut.isAwaitingObservation)
        XCTAssertTrue(sut.hasActiveRequest)
        XCTAssertFalse(sut.canPost(command))
        XCTAssertFalse(sut.didPost(command, now: 100.3))
        XCTAssertNil(sut.tick(now: 101))
        XCTAssertNil(sut.tick(now: 105))
        XCTAssertEqual(sut.state, .unknown)
        XCTAssertEqual(sut.evidence, .unknown)
        XCTAssertTrue(sut.isSettling)
        XCTAssertNil(sut.observe(.paused, epoch: sut.epoch, now: 105.1))
        XCTAssertEqual(sut.state, .paused)
        XCTAssertEqual(sut.evidence, .observed)
        XCTAssertFalse(sut.hasActiveRequest)
        XCTAssertFalse(sut.isSettling)
        XCTAssertNil(sut.pendingCommand)
    }

    func testPreClickCaptureCannotAcknowledgeAPostedClick() throws {
        var sut = MirrorToggleState()
        let command = try prepare(&sut, from: .paused, to: .playing, now: 100)
        let beforeEpoch = sut.epoch
        _ = sut.didPost(command, now: 100.2)
        XCTAssertNil(sut.observe(.playing, epoch: beforeEpoch, now: 100.3))
        XCTAssertEqual(sut.state, .unknown)
        XCTAssertEqual(sut.evidence, .unknown)
        XCTAssertTrue(sut.isSettling)
        XCTAssertNil(sut.observe(.playing, epoch: sut.epoch, now: 100.4))
        XCTAssertEqual(sut.state, .playing)
        XCTAssertEqual(sut.evidence, .observed)
    }

    func testPostClickMismatchAndUnknownAbortWithoutSecondToggle() throws {
        for result in [MirrorPlaybackState.playing, .unknown] {
            var sut = MirrorToggleState()
            let command = try prepare(&sut, from: .playing, to: .paused, now: 100)
            _ = sut.didPost(command, now: 100.2)
            let afterEpoch = sut.epoch
            XCTAssertNil(sut.observe(result, epoch: afterEpoch, now: 100.5))
            XCTAssertEqual(sut.state, .unknown)
            XCTAssertEqual(sut.evidence, .unknown)
            XCTAssertFalse(sut.hasActiveRequest)
            XCTAssertNil(sut.pendingCommand)
            XCTAssertFalse(sut.canPost(command))
            XCTAssertNil(sut.observe(.paused, epoch: afterEpoch, now: 100.6))
            XCTAssertNil(sut.tick(now: 102))
            XCTAssertEqual(sut.state, .unknown)
        }
    }

    func testDuplicateRequestDuringInitialCaptureDoesNotRestartItsDeadline() {
        var sut = MirrorToggleState()
        _ = sut.request(.paused, now: 100)
        let captureEpoch = sut.epoch
        XCTAssertNil(sut.request(.paused, now: 104))
        XCTAssertEqual(sut.epoch, captureEpoch)
        XCTAssertTrue(sut.isAwaitingObservation)
        XCTAssertNil(sut.tick(now: 105.1))
        XCTAssertFalse(sut.hasActiveRequest)
        XCTAssertEqual(sut.state, .unknown)
    }

    func testDuplicateRequestAndObservationCannotPrepareAnotherCommand() throws {
        var sut = MirrorToggleState()
        let command = try prepare(&sut, from: .paused, to: .playing, now: 100)
        let preparedEpoch = sut.epoch
        XCTAssertNil(sut.request(.playing, now: 100.2))
        XCTAssertNil(sut.observe(.paused, epoch: preparedEpoch, now: 100.3))
        XCTAssertEqual(sut.pendingCommand, command)
        XCTAssertEqual(sut.epoch, preparedEpoch)
        XCTAssertTrue(sut.didPost(command, now: 100.4))
        let afterEpoch = sut.epoch
        XCTAssertNil(sut.request(.playing, now: 100.5))
        XCTAssertEqual(sut.epoch, afterEpoch)
        XCTAssertNil(sut.observe(.playing, epoch: afterEpoch, now: 100.6))
        XCTAssertNil(sut.observe(.paused, epoch: afterEpoch, now: 100.7))
        XCTAssertNil(sut.pendingCommand)
        XCTAssertEqual(sut.state, .playing)
    }

    func testReversedTargetDuringCaptureRejectsOldObservation() {
        var sut = MirrorToggleState()
        _ = sut.request(.playing, now: 100)
        let oldEpoch = sut.epoch
        XCTAssertNil(sut.request(.paused, now: 100.1))
        XCTAssertFalse(sut.epoch == oldEpoch)
        XCTAssertNil(sut.observe(.paused, epoch: oldEpoch, now: 100.2))
        XCTAssertTrue(sut.isAwaitingObservation)
        XCTAssertEqual(sut.state, .unknown)
        XCTAssertNil(sut.observe(.paused, epoch: sut.epoch, now: 100.3))
        XCTAssertEqual(sut.state, .paused)
        XCTAssertFalse(sut.hasActiveRequest)
    }

    func testReversedTargetCancelsUnpostedCommandAndWaitsForNewObservation() throws {
        var sut = MirrorToggleState()
        let oldPlay = try prepare(&sut, from: .paused, to: .playing, now: 100)
        XCTAssertNil(sut.request(.paused, now: 100.2))
        XCTAssertFalse(sut.canPost(oldPlay))
        XCTAssertFalse(sut.didPost(oldPlay, now: 100.3))
        XCTAssertFalse(sut.fail(oldPlay))
        XCTAssertEqual(sut.state, .unknown)
        XCTAssertTrue(sut.isAwaitingObservation)
        XCTAssertEqual(sut.desiredState, .paused)
        XCTAssertNil(sut.pendingCommand)
        XCTAssertNil(sut.observe(.paused, epoch: sut.epoch, now: 100.4))
        XCTAssertEqual(sut.state, .paused)
        XCTAssertFalse(sut.hasActiveRequest)
    }

    func testReversedTargetAfterPostingNeedsFreshBeforeAndAfterCaptures() throws {
        var sut = MirrorToggleState()
        let oldPlay = try prepare(&sut, from: .paused, to: .playing, now: 100)
        _ = sut.didPost(oldPlay, now: 100.2)
        let oldVerificationEpoch = sut.epoch
        XCTAssertNil(sut.request(.paused, now: 100.3))
        XCTAssertFalse(sut.isSettling)
        XCTAssertTrue(sut.isAwaitingObservation)
        XCTAssertNil(sut.observe(.playing, epoch: oldVerificationEpoch, now: 100.4))
        XCTAssertFalse(sut.fail(oldPlay))
        let pause = try XCTUnwrap(sut.observe(.playing, epoch: sut.epoch, now: 100.5))
        XCTAssertFalse(pause.id == oldPlay.id)
        XCTAssertTrue(sut.didPost(pause, now: 100.6))
        XCTAssertNil(sut.tick(now: 102))
        XCTAssertEqual(sut.state, .unknown)
        XCTAssertNil(sut.observe(.paused, epoch: sut.epoch, now: 102.1))
        XCTAssertEqual(sut.state, .paused)
        XCTAssertEqual(sut.evidence, .observed)
    }

    func testUserInputInvalidatesCommandAndCapturesAlreadyInFlight() throws {
        var sut = MirrorToggleState()
        let command = try prepare(&sut, from: .playing, to: .paused, now: 100)
        let oldEpoch = sut.epoch
        sut.invalidate()
        XCTAssertFalse(sut.canPost(command))
        XCTAssertFalse(sut.didPost(command, now: 100.2))
        XCTAssertFalse(sut.fail(command))
        XCTAssertNil(sut.observe(.paused, epoch: oldEpoch, now: 100.3))
        XCTAssertEqual(sut.state, .unknown)
        XCTAssertEqual(sut.evidence, .unknown)
        XCTAssertFalse(sut.hasActiveRequest)
    }

    func testUserInputDuringVerificationPreventsLateSuccess() throws {
        var sut = MirrorToggleState()
        let command = try prepare(&sut, from: .paused, to: .playing, now: 100)
        _ = sut.didPost(command, now: 100.2)
        let oldEpoch = sut.epoch
        sut.invalidate()
        XCTAssertNil(sut.observe(.playing, epoch: oldEpoch, now: 100.3))
        XCTAssertNil(sut.tick(now: 102))
        XCTAssertEqual(sut.state, .unknown)
        XCTAssertFalse(sut.hasActiveRequest)
        XCTAssertFalse(sut.isSettling)
    }

    func testMatchingFailureStillCancelsAfterPostingAdvancesEpoch() throws {
        var sut = MirrorToggleState()
        let command = try prepare(&sut, from: .paused, to: .playing, now: 100)
        _ = sut.didPost(command, now: 100.2)
        XCTAssertFalse(command.epoch == sut.epoch)
        XCTAssertTrue(sut.fail(command))
        XCTAssertFalse(sut.fail(command))
        XCTAssertEqual(sut.state, .unknown)
        XCTAssertFalse(sut.hasActiveRequest)
        XCTAssertNil(sut.pendingCommand)
    }

    func testStaleFailureCannotCancelANewerCommand() throws {
        var sut = MirrorToggleState()
        let old = try prepare(&sut, from: .paused, to: .playing, now: 100)
        _ = sut.request(.paused, now: 100.2)
        _ = sut.request(.playing, now: 100.3)
        let current = try XCTUnwrap(sut.observe(.paused, epoch: sut.epoch, now: 100.4))
        XCTAssertFalse(sut.fail(old))
        XCTAssertFalse(sut.didPost(old, now: 100.5))
        XCTAssertEqual(sut.pendingCommand, current)
        XCTAssertTrue(sut.canPost(current, now: 100.5))
        XCTAssertTrue(sut.fail(current))
        XCTAssertNil(sut.pendingCommand)
    }

    func testEachObservationAndFocusPhaseHasItsOwnTimeout() throws {
        var sut = MirrorToggleState(commandTimeout: 5)
        _ = sut.request(.paused, now: 100)
        let command = try XCTUnwrap(sut.observe(.playing, epoch: sut.epoch, now: 104.9))
        XCTAssertNil(sut.tick(now: 109.8))
        XCTAssertTrue(sut.canPost(command, now: 109.8))
        XCTAssertTrue(sut.didPost(command, now: 109.8))
        XCTAssertNil(sut.tick(now: 114.7))
        XCTAssertTrue(sut.isSettling)
        XCTAssertEqual(sut.state, .unknown)
        XCTAssertNil(sut.observe(.paused, epoch: sut.epoch, now: 114.7))
        XCTAssertEqual(sut.state, .paused)
        XCTAssertEqual(sut.evidence, .observed)
    }

    func testLateInitialObservationAbortsEvenBeforeTimerRuns() {
        var sut = MirrorToggleState()
        _ = sut.request(.playing, now: 100)
        XCTAssertNil(sut.observe(.paused, epoch: sut.epoch, now: 105.1))
        XCTAssertFalse(sut.hasActiveRequest)
        XCTAssertNil(sut.pendingCommand)
        XCTAssertEqual(sut.state, .unknown)
    }

    func testLateFocusCannotPostBeforeTimerRuns() throws {
        var sut = MirrorToggleState()
        let command = try prepare(&sut, from: .paused, to: .playing, now: 100)
        XCTAssertFalse(sut.canPost(command, now: 105.2))
        XCTAssertFalse(sut.didPost(command, now: 105.2))
        XCTAssertNil(sut.tick(now: 105.2))
        XCTAssertFalse(sut.hasActiveRequest)
        XCTAssertEqual(sut.state, .unknown)
    }

    func testLateVerificationCannotTurnTimeoutIntoSuccess() throws {
        var sut = MirrorToggleState()
        let command = try prepare(&sut, from: .playing, to: .paused, now: 100)
        _ = sut.didPost(command, now: 100.2)
        XCTAssertNil(sut.observe(.paused, epoch: sut.epoch, now: 105.3))
        XCTAssertEqual(sut.state, .unknown)
        XCTAssertEqual(sut.evidence, .unknown)
        XCTAssertFalse(sut.hasActiveRequest)
        XCTAssertNil(sut.pendingCommand)
    }

    func testLongSuspensionOnlyInvalidatesAPostedClick() throws {
        var sut = MirrorToggleState()
        let command = try prepare(&sut, from: .paused, to: .playing, now: 100)
        _ = sut.didPost(command, now: 100.2)
        XCTAssertNil(sut.tick(now: 500))
        XCTAssertEqual(sut.state, .unknown)
        XCTAssertEqual(sut.evidence, .unknown)
        XCTAssertNil(sut.pendingCommand)
        XCTAssertFalse(sut.hasActiveRequest)
    }

    func testHumanConfirmationCancelsWorkButCannotAuthorizeNextClick() throws {
        var sut = MirrorToggleState()
        let command = try prepare(&sut, from: .playing, to: .paused, now: 100)
        _ = sut.didPost(command, now: 100.2)
        let oldEpoch = sut.epoch
        XCTAssertNil(sut.confirm(.paused, now: 100.3))
        XCTAssertEqual(sut.state, .paused)
        XCTAssertEqual(sut.evidence, .confirmed)
        XCTAssertFalse(sut.hasActiveRequest)
        XCTAssertFalse(sut.fail(command))
        XCTAssertNil(sut.observe(.playing, epoch: oldEpoch, now: 100.4))
        XCTAssertEqual(sut.state, .paused)
        XCTAssertNil(sut.request(.playing, now: 101))
        XCTAssertEqual(sut.state, .unknown)
        XCTAssertTrue(sut.isAwaitingObservation)
        XCTAssertNil(sut.pendingCommand)
    }

    func testPassiveObservationCancelsWorkWithoutProducingAnAction() throws {
        var sut = MirrorToggleState()
        let command = try prepare(&sut, from: .playing, to: .paused, now: 100)
        let oldEpoch = sut.epoch
        sut.recordObservation(.playing, now: 100.2)
        XCTAssertFalse(sut.epoch == oldEpoch)
        XCTAssertEqual(sut.state, .playing)
        XCTAssertEqual(sut.evidence, .observed)
        XCTAssertFalse(sut.hasActiveRequest)
        XCTAssertNil(sut.pendingCommand)
        XCTAssertFalse(sut.canPost(command))
        XCTAssertNil(sut.tick(now: 101))
        XCTAssertNil(sut.request(.paused, now: 102))
        XCTAssertEqual(sut.state, .unknown)
        XCTAssertTrue(sut.isAwaitingObservation)
        XCTAssertNil(sut.pendingCommand)
        sut.recordObservation(.unknown, now: 102.1)
        XCTAssertEqual(sut.state, .unknown)
        XCTAssertEqual(sut.evidence, .unknown)
        XCTAssertFalse(sut.hasActiveRequest)
    }

    func testInvalidTimesAndUnknownTargetsCannotPrepareOrCompleteClicks() {
        var sut = MirrorToggleState()
        _ = sut.confirm(.paused, now: 99)
        XCTAssertNil(sut.request(.playing, now: .nan))
        XCTAssertNil(sut.request(.unknown, now: 100))
        XCTAssertEqual(sut.state, .paused)
        XCTAssertNil(sut.pendingCommand)
        _ = sut.request(.playing, now: 100)
        let observationEpoch = sut.epoch
        XCTAssertNil(sut.observe(.paused, epoch: observationEpoch, now: .infinity))
        XCTAssertNil(sut.observe(.paused, epoch: observationEpoch, now: 99))
        XCTAssertNil(sut.tick(now: .infinity))
        XCTAssertNil(sut.confirm(.playing, now: .nan))
        sut.recordObservation(.playing, now: .nan)
        XCTAssertEqual(sut.epoch, observationEpoch)
        XCTAssertEqual(sut.state, .unknown)
        XCTAssertTrue(sut.isAwaitingObservation)
        XCTAssertNil(sut.pendingCommand)
    }
}
