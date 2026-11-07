import XCTest
@testable import RelayCore

final class LaunchFlowStateTests: XCTestCase {
    func testRestartingListenerRequiresANewRealEvent() throws {
        var sut = LaunchFlowState()
        let listen = try advance(&sut, to: .startListening)
        _ = sut.succeed(listen)
        XCTAssertTrue(sut.recordAgentEvent())
        sut.resetAgentConnection(isListening: false)
        XCTAssertEqual(sut.agentConnection, .notListening)
        XCTAssertFalse(sut.agentEventsVerified)
        sut.resetAgentConnection(isListening: true)
        XCTAssertEqual(sut.agentConnection, .listeningUnverified)
        XCTAssertFalse(sut.agentEventsVerified)
        XCTAssertTrue(sut.recordAgentEvent())
        XCTAssertTrue(sut.agentEventsVerified)
    }

    private func advance(_ sut: inout LaunchFlowState, to step: LaunchStep) throws -> LaunchStepCommand {
        var command = try XCTUnwrap(sut.pendingCommand ?? sut.begin())
        while command.step != step {
            command = try XCTUnwrap(sut.succeed(command))
        }
        return command
    }

    func testRunsAllStepsInRequiredOrder() throws {
        var sut = LaunchFlowState()
        var command = sut.begin()
        let expected: [LaunchStep] = [.grantPermissions, .openAIClient, .openPhoneMirror,
                                     .openPreferredPhoneApp, .arrangeWindows, .connectPlayback, .startListening]
        for step in expected {
            let current = try XCTUnwrap(command)
            XCTAssertEqual(current.step, step)
            XCTAssertTrue(sut.canExecute(current))
            command = sut.succeed(current)
        }
        XCTAssertNil(command)
        XCTAssertEqual(sut.completedSteps, expected)
        XCTAssertEqual(sut.status, .ready)
        XCTAssertNil(sut.currentStep)
    }

    func testRepeatedBeginIsSingleFlight() throws {
        var sut = LaunchFlowState()
        let command = try XCTUnwrap(sut.begin())
        let generation = sut.generation
        XCTAssertNil(sut.begin())
        XCTAssertNil(sut.begin())
        XCTAssertEqual(sut.pendingCommand, command)
        XCTAssertEqual(sut.generation, generation)
    }

    func testDuplicateSuccessCannotSkipNextStep() throws {
        var sut = LaunchFlowState()
        let first = try XCTUnwrap(sut.begin())
        let second = try XCTUnwrap(sut.succeed(first))
        XCTAssertNil(sut.succeed(first))
        XCTAssertEqual(sut.pendingCommand, second)
        XCTAssertEqual(sut.completedSteps, [.grantPermissions])
    }

    func testOutOfOrderCommandCannotAdvanceFlow() throws {
        var sut = LaunchFlowState()
        let current = try XCTUnwrap(sut.begin())
        let forged = LaunchStepCommand(id: current.id, generation: current.generation, step: .startListening)
        XCTAssertFalse(sut.canExecute(forged))
        XCTAssertNil(sut.succeed(forged))
        XCTAssertEqual(sut.pendingCommand, current)
        XCTAssertEqual(sut.agentConnection, .notListening)
    }

    func testPermissionBlockPreservesOpenedAppsAndRetryStartsAtLayout() throws {
        var sut = LaunchFlowState()
        let layout = try advance(&sut, to: .arrangeWindows)
        XCTAssertTrue(sut.block(layout, reason: "需要辅助功能权限"))
        XCTAssertEqual(sut.status, .blocked)
        XCTAssertEqual(sut.currentStep, .arrangeWindows)
        XCTAssertEqual(sut.blockReason, "需要辅助功能权限")
        XCTAssertEqual(sut.completedSteps, [.grantPermissions, .openAIClient, .openPhoneMirror, .openPreferredPhoneApp])
        let retry = try XCTUnwrap(sut.retry())
        XCTAssertEqual(retry.step, .arrangeWindows)
        XCTAssertFalse(retry.id == layout.id)
        XCTAssertFalse(sut.canExecute(layout))
        XCTAssertTrue(sut.canExecute(retry))
        XCTAssertNil(sut.blockReason)
    }

    func testPhoneUnavailableCannotSkipToPhoneAppOrPlayback() throws {
        var sut = LaunchFlowState()
        let mirror = try advance(&sut, to: .openPhoneMirror)
        XCTAssertTrue(sut.block(mirror, reason: "手机尚未连接"))
        XCTAssertEqual(sut.completedSteps, [.grantPermissions, .openAIClient])
        XCTAssertEqual(sut.currentStep, .openPhoneMirror)
        XCTAssertNil(sut.begin())
        XCTAssertFalse(sut.agentEventsVerified)
    }

    func testPhoneAppRequiresConfirmationBeforeConnectingPlayback() throws {
        var sut = LaunchFlowState()
        let phoneApp = try advance(&sut, to: .openPreferredPhoneApp)
        XCTAssertTrue(sut.block(phoneApp, reason: "已尝试打开抖音，尚未确认当前 App"))
        XCTAssertEqual(sut.currentStep, .openPreferredPhoneApp)
        XCTAssertFalse(sut.completedSteps.contains(.connectPlayback))
        XCTAssertFalse(sut.completedSteps.contains(.startListening))
        let retry = try XCTUnwrap(sut.retry())
        XCTAssertEqual(try XCTUnwrap(sut.succeed(retry)).step, .arrangeWindows)
    }

    func testRepeatedLocalFailureRemainsRetryableWithoutRepeatingEarlierSteps() throws {
        var sut = LaunchFlowState()
        var command = try advance(&sut, to: .connectPlayback)
        let previous = sut.completedSteps
        for attempt in 1...3 {
            XCTAssertTrue(sut.block(command, reason: "播控待确认 \(attempt)"))
            XCTAssertEqual(sut.completedSteps, previous)
            command = try XCTUnwrap(sut.retry())
            XCTAssertEqual(command.step, .connectPlayback)
        }
        XCTAssertEqual(try XCTUnwrap(sut.succeed(command)).step, .startListening)
    }

    func testCancelInvalidatesOldCallbacksAndRestartUsesNewGeneration() throws {
        var sut = LaunchFlowState()
        let old = try advance(&sut, to: .openPhoneMirror)
        sut.cancel()
        XCTAssertEqual(sut.status, .cancelled)
        XCTAssertFalse(sut.canExecute(old))
        XCTAssertNil(sut.succeed(old))
        XCTAssertFalse(sut.block(old, reason: "迟到失败"))
        let fresh = try XCTUnwrap(sut.begin())
        XCTAssertEqual(fresh.step, .grantPermissions)
        XCTAssertFalse(fresh.generation == old.generation)
        XCTAssertEqual(sut.completedSteps, [])
        XCTAssertNil(sut.succeed(old))
        XCTAssertEqual(sut.pendingCommand, fresh)
    }

    func testStaleFailureCannotBlockAReattempt() throws {
        var sut = LaunchFlowState()
        let first = try XCTUnwrap(sut.begin())
        _ = sut.block(first, reason: "尚未找到窗口")
        let retry = try XCTUnwrap(sut.retry())
        XCTAssertFalse(sut.block(first, reason: "旧回调"))
        XCTAssertEqual(sut.status, .running)
        XCTAssertEqual(sut.pendingCommand, retry)
    }

    func testOpeningAIWindowNeverMarksAgentEventsConnected() throws {
        var sut = LaunchFlowState()
        let open = try advance(&sut, to: .openAIClient)
        _ = sut.succeed(open)
        XCTAssertEqual(sut.agentConnection, .notListening)
        XCTAssertFalse(sut.agentEventsVerified)
        XCTAssertFalse(sut.recordAgentEvent())
        XCTAssertEqual(sut.agentConnection, .notListening)
    }

    func testPermissionBlockCannotLaunchAnyApplication() throws {
        var sut = LaunchFlowState()
        let permission = try XCTUnwrap(sut.begin())
        XCTAssertEqual(permission.step, .grantPermissions)
        XCTAssertTrue(sut.block(permission, reason: "需要授权"))
        XCTAssertTrue(sut.completedSteps.isEmpty)
        XCTAssertFalse(sut.recordAgentEvent())
        let retry = try XCTUnwrap(sut.retry())
        XCTAssertEqual(try XCTUnwrap(sut.succeed(retry)).step, .openAIClient)
        XCTAssertNil(sut.succeed(permission))
    }

    func testLocalVideoRouteDoesNotRequirePhoneOrPhoneApp() throws {
        let route: [LaunchStep] = [.grantPermissions, .openAIClient, .connectPlayback, .startListening]
        var sut = LaunchFlowState(steps: route)
        var command = sut.begin()
        for step in route {
            let current = try XCTUnwrap(command)
            XCTAssertEqual(current.step, step)
            command = sut.succeed(current)
        }
        XCTAssertNil(command)
        XCTAssertEqual(sut.completedSteps, route)
        XCTAssertFalse(sut.completedSteps.contains(.openPhoneMirror))
        XCTAssertFalse(sut.agentEventsVerified)
        XCTAssertTrue(sut.recordAgentEvent())
    }

    func testEmptyRouteUsesFullGuidedFlow() throws {
        var sut = LaunchFlowState(steps: [])
        XCTAssertEqual(sut.steps, LaunchStep.allCases)
        XCTAssertEqual(try XCTUnwrap(sut.begin()).step, .grantPermissions)
    }

    func testFinishedStartupIsListeningButUnverifiedUntilRealEvent() throws {
        var sut = LaunchFlowState()
        let listen = try advance(&sut, to: .startListening)
        XCTAssertNil(sut.succeed(listen))
        XCTAssertEqual(sut.status, .ready)
        XCTAssertEqual(sut.agentConnection, .listeningUnverified)
        XCTAssertFalse(sut.agentEventsVerified)
        XCTAssertTrue(sut.recordAgentEvent())
        XCTAssertEqual(sut.agentConnection, .receivingEvents)
        XCTAssertTrue(sut.agentEventsVerified)
        XCTAssertFalse(sut.recordAgentEvent())
    }

    func testRealEventDuringListenerStartupIsNotDowngradedAfterSuccess() throws {
        var sut = LaunchFlowState()
        let listen = try advance(&sut, to: .startListening)
        XCTAssertTrue(sut.recordAgentEvent())
        _ = sut.succeed(listen)
        XCTAssertEqual(sut.agentConnection, .receivingEvents)
        XCTAssertTrue(sut.agentEventsVerified)
    }

    func testListenerFailureClearsPrematureConnectionAndCanRetry() throws {
        var sut = LaunchFlowState()
        let listen = try advance(&sut, to: .startListening)
        _ = sut.recordAgentEvent()
        XCTAssertTrue(sut.block(listen, reason: "客户端事件监听已中断"))
        XCTAssertEqual(sut.agentConnection, .notListening)
        XCTAssertFalse(sut.recordAgentEvent())
        let retry = try XCTUnwrap(sut.retry())
        _ = sut.succeed(retry)
        XCTAssertEqual(sut.agentConnection, .listeningUnverified)
    }

    func testRetryIsOnlyAvailableForBlockedFlowAndReadyBeginIsIdempotent() throws {
        var sut = LaunchFlowState()
        XCTAssertNil(sut.retry())
        let listen = try advance(&sut, to: .startListening)
        XCTAssertNil(sut.retry())
        _ = sut.succeed(listen)
        XCTAssertNil(sut.retry())
        XCTAssertNil(sut.begin())
        sut.cancel()
        XCTAssertNil(sut.retry())
        XCTAssertFalse(sut.recordAgentEvent())
        XCTAssertNil(sut.currentStep)
    }

    func testReadyListenerInterruptionCanRetryButNeedsNewRealEvent() throws {
        var sut = LaunchFlowState()
        let previousListen = try advance(&sut, to: .startListening)
        _ = sut.succeed(previousListen)
        XCTAssertTrue(sut.recordAgentEvent())
        let previousGeneration = sut.generation

        XCTAssertTrue(sut.interrupt(at: .startListening, reason: "事件目录已移走"))
        XCTAssertEqual(sut.generation, previousGeneration + 1)
        XCTAssertEqual(sut.status, .blocked)
        XCTAssertEqual(sut.currentStep, .startListening)
        XCTAssertEqual(sut.blockReason, "事件目录已移走")
        XCTAssertEqual(sut.completedSteps, Array(LaunchStep.allCases.dropLast()))
        XCTAssertNil(sut.pendingCommand)
        XCTAssertEqual(sut.agentConnection, .notListening)
        XCTAssertFalse(sut.agentEventsVerified)
        XCTAssertFalse(sut.recordAgentEvent())
        XCTAssertNil(sut.succeed(previousListen))

        let retry = try XCTUnwrap(sut.retry())
        XCTAssertEqual(retry.step, .startListening)
        XCTAssertFalse(sut.canExecute(previousListen))
        XCTAssertNil(sut.succeed(retry))
        XCTAssertEqual(sut.status, .ready)
        XCTAssertEqual(sut.agentConnection, .listeningUnverified)
        XCTAssertFalse(sut.agentEventsVerified)
        XCTAssertTrue(sut.recordAgentEvent())
        XCTAssertTrue(sut.agentEventsVerified)
    }

    func testPermissionRevocationReturnsToFirstStepAndRejectsOldCallbacks() throws {
        var sut = LaunchFlowState()
        let oldListen = try advance(&sut, to: .startListening)
        XCTAssertTrue(sut.recordAgentEvent())
        let previousGeneration = sut.generation

        XCTAssertTrue(sut.interrupt(at: .grantPermissions, reason: "辅助功能已撤回"))
        XCTAssertEqual(sut.generation, previousGeneration + 1)
        XCTAssertEqual(sut.currentStep, .grantPermissions)
        XCTAssertEqual(sut.completedSteps, [])
        XCTAssertEqual(sut.agentConnection, .notListening)
        XCTAssertFalse(sut.canExecute(oldListen))
        XCTAssertNil(sut.succeed(oldListen))
        XCTAssertFalse(sut.block(oldListen, reason: "迟到监听失败"))
        XCTAssertFalse(sut.recordAgentEvent())
        XCTAssertEqual(sut.blockReason, "辅助功能已撤回")

        let retry = try XCTUnwrap(sut.retry())
        XCTAssertEqual(retry.step, .grantPermissions)
        XCTAssertEqual(try XCTUnwrap(sut.succeed(retry)).step, .openAIClient)
        XCTAssertNil(sut.succeed(oldListen))
    }

    func testInterruptionOfBlockedFlowKeepsOnlyEarlierCompletedSteps() throws {
        var sut = LaunchFlowState()
        let playback = try advance(&sut, to: .connectPlayback)
        XCTAssertTrue(sut.block(playback, reason: "原步骤等待"))
        let previousGeneration = sut.generation

        XCTAssertTrue(sut.interrupt(at: .openPhoneMirror, reason: "镜像已关闭"))
        XCTAssertEqual(sut.generation, previousGeneration + 1)
        XCTAssertEqual(sut.status, .blocked)
        XCTAssertEqual(sut.currentStep, .openPhoneMirror)
        XCTAssertEqual(sut.completedSteps, [.grantPermissions, .openAIClient])
        XCTAssertEqual(sut.blockReason, "镜像已关闭")
        XCTAssertNil(sut.pendingCommand)
        XCTAssertEqual(sut.agentConnection, .notListening)
        XCTAssertEqual(try XCTUnwrap(sut.retry()).step, .openPhoneMirror)
    }

    func testInterruptionNeverRestoresCancelledFlow() throws {
        var sut = LaunchFlowState()
        _ = try advance(&sut, to: .startListening)
        sut.cancel()
        let generation = sut.generation
        let completed = sut.completedSteps

        XCTAssertFalse(sut.interrupt(at: .grantPermissions, reason: "权限变化"))
        XCTAssertFalse(sut.interrupt(at: .startListening, reason: "目录恢复"))
        XCTAssertEqual(sut.generation, generation)
        XCTAssertEqual(sut.status, .cancelled)
        XCTAssertEqual(sut.completedSteps, completed)
        XCTAssertNil(sut.currentStep)
        XCTAssertNil(sut.blockReason)
        XCTAssertNil(sut.retry())
        XCTAssertFalse(sut.recordAgentEvent())
    }

    func testIdleFlowIgnoresInterruption() {
        var sut = LaunchFlowState()
        XCTAssertFalse(sut.interrupt(at: .grantPermissions, reason: "尚未开始"))
        XCTAssertEqual(sut.status, .idle)
        XCTAssertEqual(sut.generation, 0)
        XCTAssertNil(sut.currentStep)
        XCTAssertNil(sut.blockReason)
        XCTAssertEqual(sut.completedSteps, [])
    }

    func testLocalRouteRejectsPhoneInterruptionWithoutLosingConnection() throws {
        let route: [LaunchStep] = [.grantPermissions, .openAIClient, .connectPlayback, .startListening]
        var sut = LaunchFlowState(steps: route)
        let listen = try advance(&sut, to: .startListening)
        _ = sut.succeed(listen)
        XCTAssertTrue(sut.recordAgentEvent())
        let generation = sut.generation

        XCTAssertFalse(sut.interrupt(at: .openPhoneMirror, reason: "不属于当前路线"))
        XCTAssertEqual(sut.generation, generation)
        XCTAssertEqual(sut.status, .ready)
        XCTAssertEqual(sut.completedSteps, route)
        XCTAssertNil(sut.currentStep)
        XCTAssertNil(sut.blockReason)
        XCTAssertTrue(sut.agentEventsVerified)
    }

}
