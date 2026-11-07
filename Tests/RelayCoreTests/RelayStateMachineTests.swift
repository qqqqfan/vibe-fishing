import Foundation
import XCTest
@testable import RelayCore

final class RelayStateMachineTests: XCTestCase {
    private func event(_ state: AgentState, time: TimeInterval,
                       id: String? = nil, source: String = "chatgpt",
                       session: String = "session-a", turn: String = "turn-1") -> AgentEvent {
        AgentEvent(id: id ?? "\(state.rawValue)-\(time)", source: source,
                   sessionID: session, turnID: turn, state: state, timestamp: time)
    }

    private func machine(delay: TimeInterval = 3) -> RelayStateMachine {
        var result = RelayStateMachine(startDelay: delay)
        result.bind(source: "chatgpt")
        return result
    }

    func testWaitsBeforePlayingAndRepeatedProgressDoesNotDelayStart() {
        var sut = machine()
        XCTAssertEqual(sut.consume(event(.running, time: 100), now: 100), [])
        XCTAssertEqual(sut.tick(now: 102.9), [])
        XCTAssertEqual(sut.consume(event(.running, time: 102), now: 102), [])
        XCTAssertEqual(sut.tick(now: 103), [.play])
        XCTAssertEqual(sut.tick(now: 104), [])
        XCTAssertTrue(sut.snapshot.playbackRequested)
    }

    func testShortTaskNeverRequestsPlayback() {
        var sut = machine()
        _ = sut.consume(event(.running, time: 100), now: 100)
        XCTAssertEqual(sut.consume(event(.completed, time: 102), now: 102), [.pause, .requestAttention])
        XCTAssertEqual(sut.tick(now: 103), [])
        XCTAssertFalse(sut.snapshot.playbackRequested)
    }

    func testImmediateHandoffCycleResumesOnlyOnNextSubmit() {
        var sut = machine(delay: 0)
        XCTAssertEqual(sut.consume(event(.running, time: 100), now: 100), [.play])
        XCTAssertEqual(sut.consume(event(.completed, time: 101), now: 101), [.pause, .requestAttention])
        // Returning to read/type isn't an agent event and must not resume video.
        XCTAssertEqual(sut.tick(now: 102), [])
        XCTAssertEqual(sut.consume(event(.completed, time: 103), now: 103), [])
        XCTAssertEqual(sut.consume(event(.running, time: 104, turn: "turn-2"), now: 104), [.play])
        XCTAssertEqual(sut.tick(now: 105), [])
        XCTAssertEqual(sut.consume(event(.needsInput, time: 106, turn: "turn-2"), now: 106), [.pause, .requestAttention])
        XCTAssertEqual(sut.consume(event(.running, time: 107, turn: "turn-2"), now: 107), [.play])
    }

    func testOnlyRunningClaimsSessionAndOtherSourcesAndSessionsAreIgnored() {
        var sut = machine()
        XCTAssertEqual(sut.consume(event(.completed, time: 100), now: 100), [])
        XCTAssertNil(sut.snapshot.sessionID)
        XCTAssertEqual(sut.consume(event(.running, time: 100, source: "claude"), now: 100), [])
        XCTAssertNil(sut.snapshot.sessionID)
        _ = sut.consume(event(.running, time: 101), now: 101)
        XCTAssertEqual(sut.snapshot.sessionID, "session-a")
        XCTAssertEqual(sut.consume(event(.completed, time: 102, session: "session-b"), now: 102), [])
        XCTAssertEqual(sut.snapshot.state, .running)
        XCTAssertEqual(sut.tick(now: 104), [.play])
    }

    func testExplicitSessionBindingRejectsOtherSessions() {
        var sut = machine()
        sut.bind(source: "chatgpt", sessionID: "chosen")
        XCTAssertEqual(sut.consume(event(.running, time: 100), now: 100), [])
        XCTAssertEqual(sut.snapshot.state, .idle)
        _ = sut.consume(event(.running, time: 101, session: "chosen"), now: 101)
        XCTAssertEqual(sut.snapshot.state, .running)
    }

    func testOldTurnCannotCompleteOrReplaceNewTurnEvenWithLaterTimestamp() {
        var sut = machine(delay: 0)
        _ = sut.consume(event(.running, time: 100), now: 100)
        XCTAssertEqual(sut.consume(event(.running, time: 110, turn: "turn-2"), now: 110), [.pause, .play])
        XCTAssertEqual(sut.consume(event(.completed, time: 111), now: 111), [])
        XCTAssertEqual(sut.consume(event(.running, time: 112), now: 112), [])
        XCTAssertEqual(sut.snapshot.turnID, "turn-2")
        XCTAssertTrue(sut.snapshot.playbackRequested)
    }

    func testOlderUnseenTurnDoesNotReplaceCurrentTurn() {
        var sut = machine()
        _ = sut.consume(event(.running, time: 110, turn: "turn-2"), now: 110)
        XCTAssertEqual(sut.consume(event(.running, time: 105), now: 111), [])
        XCTAssertEqual(sut.snapshot.turnID, "turn-2")
    }

    func testDuplicateCompletionCannotTogglePlaybackOrRepeatReminder() {
        var sut = machine(delay: 0)
        _ = sut.consume(event(.running, time: 100), now: 100)
        let completion = event(.completed, time: 101)
        XCTAssertEqual(sut.consume(completion, now: 101), [.pause, .requestAttention])
        XCTAssertEqual(sut.consume(completion, now: 102), [])
        XCTAssertEqual(sut.consume(event(.completed, time: 103), now: 103), [])
        XCTAssertEqual(sut.consume(event(.running, time: 104), now: 104), [])
        XCTAssertEqual(sut.snapshot.state, .completed)
    }

    func testManualPauseSurvivesNewTurnsAndExplicitUnpauseCanResume() {
        var sut = machine(delay: 0)
        _ = sut.consume(event(.running, time: 100), now: 100)
        XCTAssertEqual(sut.setManualPaused(true, now: 101), [.pause])
        _ = sut.consume(event(.completed, time: 102), now: 102)
        XCTAssertEqual(sut.consume(event(.running, time: 103, turn: "turn-2"), now: 103), [])
        XCTAssertTrue(sut.snapshot.manuallyPaused)
        XCTAssertEqual(sut.tick(now: 110), [])
        XCTAssertEqual(sut.setManualPaused(false, now: 110), [.play])
        XCTAssertEqual(sut.tick(now: 111), [])
        XCTAssertEqual(sut.consume(event(.running, time: 112, turn: "turn-2"), now: 112), [])
    }

    func testUnpauseAfterCompletionWaitsForNewRunningTurn() {
        var sut = machine(delay: 0)
        _ = sut.consume(event(.running, time: 100), now: 100)
        _ = sut.setManualPaused(true, now: 101)
        _ = sut.consume(event(.completed, time: 102), now: 102)
        XCTAssertEqual(sut.setManualPaused(false, now: 103), [])
        XCTAssertEqual(sut.tick(now: 104), [])
        XCTAssertEqual(sut.consume(event(.running, time: 105, turn: "turn-2"), now: 105), [.play])
    }

    func testManualPauseCancelsPendingStart() {
        var sut = machine()
        _ = sut.consume(event(.running, time: 100), now: 100)
        XCTAssertEqual(sut.setManualPaused(true, now: 101), [.pause])
        XCTAssertEqual(sut.setManualPaused(true, now: 102), [])
        XCTAssertEqual(sut.tick(now: 110), [])
        XCTAssertFalse(sut.snapshot.playbackRequested)
    }

    func testNeedsInputPausesImmediatelyAndFreshRunningResumesSameTurn() {
        var sut = machine(delay: 0)
        let start = event(.running, time: 100)
        _ = sut.consume(start, now: 100)
        XCTAssertEqual(sut.consume(event(.needsInput, time: 101), now: 101), [.pause, .requestAttention])
        XCTAssertEqual(sut.consume(start, now: 102), [])
        XCTAssertEqual(sut.consume(event(.running, time: 101, id: "same-time"), now: 102), [])
        XCTAssertEqual(sut.consume(event(.needsInput, time: 102), now: 102), [])
        XCTAssertEqual(sut.snapshot.state, .needsInput)
        XCTAssertEqual(sut.consume(event(.running, time: 103), now: 103), [.play])
        XCTAssertEqual(sut.snapshot.state, .running)
    }

    func testUnknownPausesWithoutReminderAndCanRecover() {
        var sut = machine(delay: 0)
        _ = sut.consume(event(.running, time: 100), now: 100)
        XCTAssertEqual(sut.consume(event(.unknown, time: 101), now: 101), [.pause])
        XCTAssertEqual(sut.tick(now: 102), [])
        XCTAssertEqual(sut.consume(event(.unknown, time: 103), now: 103), [])
        XCTAssertEqual(sut.consume(event(.running, time: 104), now: 104), [.play])
    }

    func testFailureAndCancellationPauseAndRemind() {
        for state in [AgentState.failed, .cancelled] {
            var sut = machine(delay: 0)
            _ = sut.consume(event(.running, time: 100), now: 100)
            XCTAssertEqual(sut.consume(event(state, time: 101), now: 101), [.pause, .requestAttention])
            XCTAssertFalse(sut.snapshot.playbackRequested)
        }
    }

    func testRejectsExpiredFutureNonFiniteAndOutOfOrderEvents() {
        var sut = machine()
        XCTAssertEqual(sut.consume(event(.running, time: 1), now: 200), [])
        XCTAssertEqual(sut.consume(event(.running, time: 210), now: 200), [])
        XCTAssertEqual(sut.consume(event(.running, time: .nan), now: 200), [])
        XCTAssertNil(sut.snapshot.sessionID)
        _ = sut.consume(event(.running, time: 200), now: 200)
        XCTAssertEqual(sut.consume(event(.completed, time: 199), now: 201), [])
        XCTAssertEqual(sut.snapshot.state, .running)
    }

    func testRebindClearsOldTurnAndPreservesManualPreference() {
        var sut = machine()
        _ = sut.consume(event(.running, time: 100), now: 100)
        _ = sut.setManualPaused(true, now: 101)
        sut.bind(source: "claude")
        XCTAssertEqual(sut.snapshot.source, "claude")
        XCTAssertNil(sut.snapshot.sessionID)
        XCTAssertNil(sut.snapshot.turnID)
        XCTAssertTrue(sut.snapshot.manuallyPaused)
        XCTAssertEqual(sut.snapshot.state, .idle)
        XCTAssertEqual(sut.tick(now: 200), [])
    }

    func testResetPausesAndRetainsBindingAndManualPreference() {
        var sut = machine()
        _ = sut.consume(event(.running, time: 100), now: 100)
        _ = sut.setManualPaused(true, now: 101)
        XCTAssertEqual(sut.reset(), [.pause])
        XCTAssertEqual(sut.snapshot.sessionID, "session-a")
        XCTAssertNil(sut.snapshot.turnID)
        XCTAssertTrue(sut.snapshot.manuallyPaused)
        XCTAssertEqual(sut.tick(now: 200), [])
    }

    func testResetDoesNotReplayPreviousEvent() {
        var sut = machine(delay: 0)
        let start = event(.running, time: 100)
        _ = sut.consume(start, now: 100)
        _ = sut.reset()
        XCTAssertEqual(sut.consume(start, now: 101), [])
        XCTAssertEqual(sut.snapshot.state, .idle)
        XCTAssertEqual(sut.consume(event(.running, time: 102), now: 102), [.play])
    }

    func testCodableUsesBridgeFieldNames() throws {
        let original = event(.needsInput, time: 123)
        let encoded = try JSONEncoder().encode(original)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(json["session_id"] as? String, "session-a")
        XCTAssertEqual(json["turn_id"] as? String, "turn-1")
        XCTAssertNil(json["sessionID"])
        XCTAssertEqual(try JSONDecoder().decode(AgentEvent.self, from: encoded), original)
    }
}
