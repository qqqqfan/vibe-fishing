import Foundation

public enum AgentState: String, Codable, CaseIterable {
    case idle
    case running
    case needsInput
    case completed
    case failed
    case cancelled
    case unknown
}

public struct AgentEvent: Codable, Equatable {
    public var id: String
    public var source: String
    public var sessionID: String
    public var turnID: String
    public var state: AgentState
    public var timestamp: TimeInterval

    public init(id: String, source: String, sessionID: String, turnID: String,
                state: AgentState, timestamp: TimeInterval) {
        self.id = id
        self.source = source
        self.sessionID = sessionID
        self.turnID = turnID
        self.state = state
        self.timestamp = timestamp
    }

    enum CodingKeys: String, CodingKey {
        case id, source, state, timestamp
        case sessionID = "session_id"
        case turnID = "turn_id"
    }
}

public enum RelayAction: Equatable {
    case play
    case pause
    /// Ask the UI to draw attention without activating the agent's window.
    case requestAttention
}

public struct RelaySnapshot: Equatable {
    public internal(set) var state: AgentState
    public internal(set) var source: String
    public internal(set) var sessionID: String?
    public internal(set) var turnID: String?
    /// The last requested state, not confirmation that an external player obeyed.
    public internal(set) var playbackRequested: Bool
    public internal(set) var manuallyPaused: Bool

    public init(state: AgentState = .idle, source: String = "",
                sessionID: String? = nil, turnID: String? = nil,
                playbackRequested: Bool = false, manuallyPaused: Bool = false) {
        self.state = state
        self.source = source
        self.sessionID = sessionID
        self.turnID = turnID
        self.playbackRequested = playbackRequested
        self.manuallyPaused = manuallyPaused
    }
}

/// Converts trusted, whole-turn agent events into player intentions.
///
/// The adapter must exclude subagent notifications and unrelated windows. This
/// layer additionally isolates sources, sessions and turns, and never interprets
/// a pause action as a toggle. The player adapter must make pause idempotent.
public struct RelayStateMachine {
    public private(set) var snapshot: RelaySnapshot

    private let startDelay: TimeInterval
    private var pendingPlaybackAt: TimeInterval?
    private var latestTimestamp: TimeInterval?
    private var observedEventIDs = Set<String>()
    private var observedEventOrder: [String] = []
    private var retiredTurnIDs = Set<String>()
    private var retiredTurnOrder: [String] = []

    /// Events are transient notifications, not history to replay at launch.
    private static let maximumEventAge: TimeInterval = 120
    private static let futureClockTolerance: TimeInterval = 5
    private static let eventHistoryLimit = 2_048
    private static let turnHistoryLimit = 512

    public init(startDelay: TimeInterval = 3) {
        self.startDelay = startDelay.isFinite ? max(0, startDelay) : 3
        self.snapshot = RelaySnapshot()
    }

    /// Bind before listening. Call the player adapter's pause before rebinding.
    /// With no session specified, the next valid running event claims it.
    public mutating func bind(source: String, sessionID: String? = nil) {
        let manuallyPaused = snapshot.manuallyPaused
        snapshot = RelaySnapshot(source: source, sessionID: sessionID,
                                 manuallyPaused: manuallyPaused)
        clearTracking()
    }

    public mutating func consume(_ event: AgentEvent, now: TimeInterval) -> [RelayAction] {
        guard now.isFinite, event.timestamp.isFinite,
              !snapshot.source.isEmpty, event.source == snapshot.source,
              !event.id.isEmpty, !event.sessionID.isEmpty, !event.turnID.isEmpty,
              event.timestamp >= now - Self.maximumEventAge,
              event.timestamp <= now + Self.futureClockTolerance,
              !observedEventIDs.contains(event.id) else { return [] }

        if let boundSession = snapshot.sessionID {
            guard event.sessionID == boundSession else { return [] }
        } else {
            guard event.state == .running else { return [] }
        }

        let isNewTurn = snapshot.turnID != event.turnID
        if isNewTurn {
            guard event.state == .running,
                  !retiredTurnIDs.contains(event.turnID),
                  latestTimestamp.map({ event.timestamp > $0 }) ?? true else { return [] }
        } else {
            guard latestTimestamp.map({ event.timestamp >= $0 }) ?? true else { return [] }
            // A completed turn stays complete. Continuation after a permission
            // request is different: a fresh, later running event can resume it.
            if isTerminal(snapshot.state) { return [] }
            if event.state == .running && snapshot.state != .running {
                guard latestTimestamp.map({ event.timestamp > $0 }) ?? true else { return [] }
            }
        }

        rememberEvent(event.id)
        latestTimestamp = event.timestamp
        if snapshot.sessionID == nil { snapshot.sessionID = event.sessionID }

        let previousState = snapshot.state
        let wasPlaying = snapshot.playbackRequested
        if isNewTurn {
            if let previousTurn = snapshot.turnID { rememberRetiredTurn(previousTurn) }
            snapshot.turnID = event.turnID
            pendingPlaybackAt = nil
            snapshot.playbackRequested = false
        }
        snapshot.state = event.state

        switch event.state {
        case .running:
            // Repeated progress events must not keep postponing the start.
            if !snapshot.manuallyPaused && !snapshot.playbackRequested && pendingPlaybackAt == nil {
                pendingPlaybackAt = now + startDelay
            }
            var actions: [RelayAction] = isNewTurn && wasPlaying ? [.pause] : []
            actions += tick(now: now)
            return actions
        case .needsInput, .completed, .failed, .cancelled:
            pendingPlaybackAt = nil
            snapshot.playbackRequested = false
            // Some bridges repeat a status with a fresh ID. Do not show another
            // reminder until there is a real transition.
            guard previousState != event.state || isNewTurn else { return [] }
            return [.pause, .requestAttention]
        case .unknown, .idle:
            pendingPlaybackAt = nil
            snapshot.playbackRequested = false
            guard previousState != event.state || wasPlaying else { return [] }
            return [.pause]
        }
    }

    public mutating func tick(now: TimeInterval) -> [RelayAction] {
        guard now.isFinite, snapshot.state == .running,
              !snapshot.manuallyPaused, !snapshot.playbackRequested,
              let deadline = pendingPlaybackAt, now >= deadline else { return [] }
        pendingPlaybackAt = nil
        snapshot.playbackRequested = true
        return [.play]
    }

    /// Explicitly clearing manual pause is a user playback command. It may
    /// resume a currently running turn immediately, but never a stopped one.
    public mutating func setManualPaused(_ paused: Bool, now: TimeInterval) -> [RelayAction] {
        guard paused != snapshot.manuallyPaused else { return [] }
        snapshot.manuallyPaused = paused
        pendingPlaybackAt = nil
        snapshot.playbackRequested = false
        if paused { return [.pause] }
        if snapshot.state == .running {
            snapshot.playbackRequested = true
            return [.play]
        }
        return []
    }

    /// Stop the active turn while retaining the selected source/session and the
    /// user's manual-pause preference. A new event is required to start again.
    public mutating func reset() -> [RelayAction] {
        let source = snapshot.source
        let sessionID = snapshot.sessionID
        let manuallyPaused = snapshot.manuallyPaused
        snapshot = RelaySnapshot(source: source, sessionID: sessionID,
                                 manuallyPaused: manuallyPaused)
        // Keep ordering and replay protection across a local stop. Rebinding
        // is the explicit operation that starts a new observation history.
        pendingPlaybackAt = nil
        return [.pause]
    }

    private func isTerminal(_ state: AgentState) -> Bool {
        state == .completed || state == .failed || state == .cancelled
    }

    private mutating func clearTracking() {
        pendingPlaybackAt = nil
        latestTimestamp = nil
        observedEventIDs.removeAll(keepingCapacity: true)
        observedEventOrder.removeAll(keepingCapacity: true)
        retiredTurnIDs.removeAll(keepingCapacity: true)
        retiredTurnOrder.removeAll(keepingCapacity: true)
    }

    private mutating func rememberEvent(_ id: String) {
        observedEventIDs.insert(id)
        observedEventOrder.append(id)
        if observedEventOrder.count > Self.eventHistoryLimit {
            observedEventIDs.remove(observedEventOrder.removeFirst())
        }
    }

    private mutating func rememberRetiredTurn(_ id: String) {
        retiredTurnIDs.insert(id)
        retiredTurnOrder.append(id)
        if retiredTurnOrder.count > Self.turnHistoryLimit {
            retiredTurnIDs.remove(retiredTurnOrder.removeFirst())
        }
    }
}
