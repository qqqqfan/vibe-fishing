import XCTest
@testable import RelayCore

final class AgentActivityHubTests: XCTestCase {
    private var counter = 0
    private func event(_ source: String, _ session: String, _ turn: String, _ state: AgentState, at time: Double) -> AgentEvent {
        counter += 1
        return AgentEvent(id: "e\(counter)", source: source, sessionID: session, turnID: turn, state: state, timestamp: time)
    }

    func testNewSessionResumesAfterAnotherSessionCompleted() {
        // The old single-session binding silently dropped this second thread.
        var hub = AgentActivityHub()
        XCTAssertEqual(hub.consume(event("codex", "a", "t1", .running, at: 100), now: 100), [.play])
        XCTAssertEqual(hub.consume(event("codex", "a", "t1", .completed, at: 110), now: 110), [.pause, .requestAttention])
        XCTAssertEqual(hub.consume(event("codex", "b", "t9", .running, at: 120), now: 120), [.play])
    }

    func testDifferentAppsShareOneRule() {
        var hub = AgentActivityHub()
        XCTAssertEqual(hub.consume(event("app:com.openai.codex", "w1", "x", .running, at: 100), now: 100), [.play])
        XCTAssertEqual(hub.consume(event("app:com.openai.codex", "w1", "x", .completed, at: 105), now: 105), [.pause, .requestAttention])
        XCTAssertEqual(hub.consume(event("app:com.anthropic.claudefordesktop", "w2", "y", .running, at: 130), now: 130), [.play])
        XCTAssertEqual(hub.consume(event("app:com.anthropic.claudefordesktop", "w2", "y", .completed, at: 140), now: 140), [.pause, .requestAttention])
    }

    func testAnyCompletionPullsAttentionEvenIfAnotherIsRunning() {
        var hub = AgentActivityHub()
        _ = hub.consume(event("codex", "a", "t1", .running, at: 100), now: 100)
        _ = hub.consume(event("claude", "b", "t2", .running, at: 101), now: 101)
        XCTAssertEqual(hub.consume(event("claude", "b", "t2", .completed, at: 110), now: 110), [.pause, .requestAttention])
        XCTAssertTrue(hub.anyRunning)
    }

    func testHookAndWindowObserverForOneTurnRemindOnce() {
        var hub = AgentActivityHub()
        XCTAssertEqual(hub.consume(event("codex", "s", "t", .running, at: 100), now: 100), [.play])
        XCTAssertEqual(hub.consume(event("app:com.openai.codex", "w", "u", .running, at: 100.4), now: 100.4), [.play])
        XCTAssertEqual(hub.consume(event("codex", "s", "t", .completed, at: 110), now: 110), [.pause, .requestAttention])
        XCTAssertEqual(hub.consume(event("app:com.openai.codex", "w", "u", .completed, at: 111.2), now: 111.2), [.pause])
    }

    func testLateRunningTailOfFinishedTurnDoesNotResume() {
        var hub = AgentActivityHub()
        _ = hub.consume(event("codex", "a", "t1", .running, at: 100), now: 100)
        _ = hub.consume(event("codex", "a", "t1", .completed, at: 110), now: 110)
        XCTAssertEqual(hub.consume(event("codex", "a", "t1", .running, at: 111), now: 111), [])
    }

    func testApprovalPausesAndContinuationResumes() {
        var hub = AgentActivityHub()
        _ = hub.consume(event("claude", "a", "t", .running, at: 100), now: 100)
        XCTAssertEqual(hub.consume(event("claude", "a", "t", .needsInput, at: 110), now: 110), [.pause, .requestAttention])
        XCTAssertEqual(hub.consume(event("claude", "a", "t", .running, at: 120), now: 120), [.play])
    }

    func testStaleApprovalNeverBlocksANewMessage() {
        var hub = AgentActivityHub()
        _ = hub.consume(event("claude", "a", "t", .running, at: 100), now: 100)
        _ = hub.consume(event("claude", "a", "t", .needsInput, at: 110), now: 110)
        XCTAssertEqual(hub.consume(event("codex", "b", "u", .running, at: 200), now: 200), [.play])
    }

    func testUserCancelPausesWithoutReminder() {
        var hub = AgentActivityHub()
        _ = hub.consume(event("codex", "a", "t", .running, at: 100), now: 100)
        XCTAssertEqual(hub.consume(event("codex", "a", "t", .cancelled, at: 110), now: 110), [.pause])
    }

    func testManualPauseIsRespectedAndReleased() {
        var hub = AgentActivityHub()
        XCTAssertEqual(hub.setManualPaused(true), [.pause])
        XCTAssertEqual(hub.consume(event("codex", "a", "t", .running, at: 100), now: 100), [])
        XCTAssertEqual(hub.setManualPaused(false), [.play])
    }

    func testOldEventsAreDropped() {
        var hub = AgentActivityHub()
        XCTAssertEqual(hub.consume(event("codex", "a", "t", .running, at: 100), now: 400), [])
    }

    func testAbandonedTurnExpiresQuietly() {
        var hub = AgentActivityHub()
        _ = hub.consume(event("codex", "a", "t", .running, at: 100), now: 100)
        hub.tick(now: 100 + AgentActivityHub.staleRunningAfter + 1)
        XCTAssertFalse(hub.anyRunning)
    }

    func testClosedWindowStopsCounting() {
        var hub = AgentActivityHub()
        _ = hub.consume(event("app:x", "w", "t", .running, at: 100), now: 100)
        hub.remove(source: "app:x", sessionID: "w")
        XCTAssertFalse(hub.anyRunning)
    }
}

final class GenerationDetectorTests: XCTestCase {
    private func obs(stop: Bool, approval: Bool = false, readable: Bool = true) -> GenerationDetector.Observation {
        GenerationDetector.Observation(readable: readable, stopVisible: stop, approvalVisible: approval)
    }

    func testStartsOnStopControlAndCompletesAfterHold() {
        var detector = GenerationDetector()
        XCTAssertEqual(detector.observe(obs(stop: true), at: 0), .running)
        XCTAssertEqual(detector.observe(obs(stop: true), at: 0.5), nil)
        XCTAssertEqual(detector.observe(obs(stop: false), at: 1.0), nil)
        XCTAssertEqual(detector.observe(obs(stop: false), at: 1.5), nil)
        XCTAssertEqual(detector.observe(obs(stop: false), at: 2.0), .completed)
    }

    func testBriefRerenderBetweenToolCallsDoesNotComplete() {
        var detector = GenerationDetector()
        _ = detector.observe(obs(stop: true), at: 0)
        XCTAssertEqual(detector.observe(obs(stop: false), at: 0.5), nil)
        XCTAssertEqual(detector.observe(obs(stop: true), at: 1.0), nil)
        XCTAssertEqual(detector.observe(obs(stop: false), at: 1.5), nil)
        XCTAssertEqual(detector.state, .running)
    }

    func testUnreadableWindowNeverImpliesCompletion() {
        var detector = GenerationDetector()
        _ = detector.observe(obs(stop: true), at: 0)
        XCTAssertEqual(detector.observe(obs(stop: false, readable: false), at: 60), nil)
        XCTAssertEqual(detector.state, .running)
    }

    func testIdleWindowWithoutStopStaysIdle() {
        var detector = GenerationDetector()
        XCTAssertEqual(detector.observe(obs(stop: false), at: 0), nil)
        XCTAssertEqual(detector.observe(obs(stop: false), at: 30), nil)
        XCTAssertEqual(detector.state, .idle)
    }

    func testEachGenerationGetsANewTurn() {
        var detector = GenerationDetector()
        _ = detector.observe(obs(stop: true), at: 0)
        let first = detector.turnID
        _ = detector.observe(obs(stop: false), at: 2)
        _ = detector.observe(obs(stop: true), at: 5)
        XCTAssertFalse(first == detector.turnID)
    }

    func testApprovalThenContinueKeepsTheTurn() {
        var detector = GenerationDetector()
        _ = detector.observe(obs(stop: true), at: 0)
        let turn = detector.turnID
        XCTAssertEqual(detector.observe(obs(stop: true, approval: true), at: 1), nil)
        XCTAssertEqual(detector.observe(obs(stop: true, approval: true), at: 1.5), .needsInput)
        XCTAssertEqual(detector.observe(obs(stop: true), at: 3), .running)
        XCTAssertEqual(detector.turnID, turn)
    }

    func testRejectedApprovalEndsInCompletion() {
        var detector = GenerationDetector()
        _ = detector.observe(obs(stop: true), at: 0)
        _ = detector.observe(obs(stop: false, approval: true), at: 1)
        XCTAssertEqual(detector.observe(obs(stop: false, approval: true), at: 1.5), .needsInput)
        XCTAssertEqual(detector.observe(obs(stop: false), at: 2), nil)
        XCTAssertEqual(detector.observe(obs(stop: false), at: 3), .completed)
    }

    func testApprovalWordsOutsideAGenerationAreIgnored() {
        var detector = GenerationDetector()
        XCTAssertEqual(detector.observe(obs(stop: false, approval: true), at: 0), nil)
        XCTAssertEqual(detector.observe(obs(stop: false, approval: true), at: 5), nil)
        XCTAssertEqual(detector.state, .idle)
    }

    func testVocabularyMatchesControlsNotSentences() {
        let words = ControlVocabulary.standard
        XCTAssertTrue(words.isStop("Stop generating"))
        XCTAssertTrue(words.isStop("停止生成"))
        XCTAssertTrue(words.isStop("Stop (⌘.)"))
        XCTAssertFalse(words.isStop("Stop using var in JavaScript"))
        XCTAssertFalse(words.isStop("如何停止生成重复代码"))
        XCTAssertFalse(words.isApproval("Allow me to explain"))
        XCTAssertTrue(words.isApproval("Allow once"))
    }
}
