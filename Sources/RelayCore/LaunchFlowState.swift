import Foundation

public enum LaunchStep: String, CaseIterable {
    case grantPermissions
    case openAIClient
    case openPhoneMirror
    case openPreferredPhoneApp
    case arrangeWindows
    case connectPlayback
    case startListening
}

public enum LaunchFlowStatus: String {
    case idle, running, blocked, ready, cancelled
}

public enum LaunchAgentConnection: String {
    case notListening, listeningUnverified, receivingEvents
}

public struct LaunchStepCommand: Equatable {
    public let id: UUID
    public let generation: UInt64
    public let step: LaunchStep
}

/// Coordinates startup intentions without equating an open window with an
/// operational integration. The platform adapter must verify each step's
/// postcondition or block it; opening a URL alone is not phone-app confirmation.
public struct LaunchFlowState {
    public let steps: [LaunchStep]
    public private(set) var status: LaunchFlowStatus = .idle
    public private(set) var pendingCommand: LaunchStepCommand?
    public private(set) var completedSteps: [LaunchStep] = []
    public private(set) var blockReason: String?
    public private(set) var agentConnection: LaunchAgentConnection = .notListening
    public private(set) var generation: UInt64 = 0

    public var currentStep: LaunchStep? { pendingCommand?.step ?? blockedStep }
    /// Ready means startup finished, while this separately requires a real
    /// event from the selected AI integration after listening was started.
    public var agentEventsVerified: Bool { agentConnection == .receivingEvents }

    private var blockedStep: LaunchStep?

    public init(steps: [LaunchStep] = LaunchStep.allCases) {
        self.steps = steps.isEmpty ? LaunchStep.allCases : steps
    }

    /// Idempotent while running, blocked or ready. Use retry for a blocked step;
    /// cancel then begin is an explicit full restart with a new generation.
    @discardableResult
    public mutating func begin() -> LaunchStepCommand? {
        guard status == .idle || status == .cancelled else { return nil }
        generation &+= 1
        completedSteps.removeAll(keepingCapacity: true)
        blockReason = nil
        blockedStep = nil
        agentConnection = .notListening
        status = .running
        return prepare(steps[0])
    }

    /// Check before starting a side effect and again in its asynchronous callback.
    public func canExecute(_ command: LaunchStepCommand) -> Bool {
        status == .running && command.generation == generation && pendingCommand == command
    }

    /// Advance only after the coordinator has verified the actual postcondition.
    /// Missing permission, a disconnected phone, or an unconfirmed phone app
    /// must call block instead; the state machine cannot inspect those itself.
    @discardableResult
    public mutating func succeed(_ command: LaunchStepCommand) -> LaunchStepCommand? {
        guard canExecute(command) else { return nil }
        pendingCommand = nil
        completedSteps.append(command.step)
        guard let index = steps.firstIndex(of: command.step) else { return nil }
        let next = steps.index(after: index)
        if next < steps.endIndex { return prepare(steps[next]) }
        status = .ready
        if agentConnection != .receivingEvents { agentConnection = .listeningUnverified }
        return nil
    }

    /// Preserve prior successful steps and stop here. A delayed success for the
    /// failed command is invalid after this call, even if the user has retried.
    @discardableResult
    public mutating func block(_ command: LaunchStepCommand, reason: String) -> Bool {
        guard canExecute(command) else { return false }
        generation &+= 1
        pendingCommand = nil
        blockedStep = command.step
        blockReason = reason
        status = .blocked
        if command.step == .startListening { agentConnection = .notListening }
        return true
    }

    /// An active connection can lose a prerequisite after startup. Return to
    /// that step without preserving later completion or accepting old callbacks.
    /// An explicit cancellation is never resumed by an external state change.
    @discardableResult
    public mutating func interrupt(at step: LaunchStep, reason: String) -> Bool {
        guard status == .running || status == .blocked || status == .ready,
              let targetIndex = steps.firstIndex(of: step) else { return false }
        generation &+= 1
        pendingCommand = nil
        blockedStep = step
        let earlierSteps = steps.prefix(targetIndex)
        completedSteps.removeAll { !earlierSteps.contains($0) }
        agentConnection = .notListening
        status = .blocked
        blockReason = reason
        return true
    }

    /// Retry only the blocked step; do not reopen already launched applications.
    @discardableResult
    public mutating func retry() -> LaunchStepCommand? {
        guard status == .blocked, let step = blockedStep else { return nil }
        generation &+= 1
        blockedStep = nil
        blockReason = nil
        status = .running
        return prepare(step)
    }

    /// Invalidates callbacks, not external OS actions that already completed.
    /// The coordinator remains responsible for stopping any active listener.
    public mutating func cancel() {
        generation &+= 1
        pendingCommand = nil
        blockedStep = nil
        blockReason = nil
        agentConnection = .notListening
        status = .cancelled
    }

    /// Call only for a genuine accepted event from the selected AI adapter.
    /// Window discovery, application launch and simulated events must not call
    /// this. An event arriving during listener startup is valid and is retained.
    @discardableResult
    public mutating func recordAgentEvent() -> Bool {
        let startingListener = status == .running && pendingCommand?.step == .startListening
        let readyListener = status == .ready && completedSteps.contains(.startListening)
        guard startingListener || readyListener, agentConnection != .receivingEvents else { return false }
        agentConnection = .receivingEvents
        return true
    }

    /// A restarted listener must prove connectivity with a new accepted event.
    public mutating func resetAgentConnection(isListening: Bool) {
        agentConnection = isListening ? .listeningUnverified : .notListening
    }

    private mutating func prepare(_ step: LaunchStep) -> LaunchStepCommand {
        let command = LaunchStepCommand(id: UUID(), generation: generation, step: step)
        pendingCommand = command
        return command
    }
}
