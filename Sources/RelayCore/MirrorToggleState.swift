import Foundation

public enum MirrorPlaybackState: String, Codable {
    case unknown, playing, paused
}

/// Only an observation or an explicit human confirmation establishes state.
/// Posting a click and waiting are never evidence that the player obeyed.
public enum MirrorStateEvidence: String, Codable {
    case unknown, confirmed, observed
}

public struct MirrorToggleCommand: Equatable {
    public let id: UUID
    public let epoch: UInt64
    public let from: MirrorPlaybackState
    public let target: MirrorPlaybackState
}

/// A single-flight, observe-before-and-after toggle controller. Each request
/// permits at most one click. Unknown or mismatching verification aborts the
/// request without retrying. The adapter owns fresh capture, focus and input.
public struct MirrorToggleState {
    public private(set) var state: MirrorPlaybackState = .unknown
    public private(set) var evidence: MirrorStateEvidence = .unknown
    public private(set) var desiredState: MirrorPlaybackState?
    public private(set) var pendingCommand: MirrorToggleCommand?
    /// Capture this value when starting an observation, not when it finishes.
    /// Posting a click advances it, invalidating every pre-click observation.
    public private(set) var epoch: UInt64 = 0

    public var hasActiveRequest: Bool { desiredState != nil }
    public var isAwaitingObservation: Bool { phase == .observingBefore }
    public var isSettling: Bool { phase == .observingAfter }

    private enum Phase { case idle, observingBefore, readyToPost, observingAfter }
    private var phase: Phase = .idle
    private let commandTimeout: TimeInterval
    private var phaseStartedAt: TimeInterval?

    /// `settleDelay` is retained for source compatibility. Elapsed time no
    /// longer supplies evidence; the adapter decides when fresh frames are ready.
    public init(settleDelay: TimeInterval = 0.7, commandTimeout: TimeInterval = 5) {
        _ = settleDelay
        self.commandTimeout = commandTimeout.isFinite ? max(0, commandTimeout) : 5
    }

    /// Human confirmation is a baseline, never an instruction to act. The next
    /// request will discard it and require its own fresh observation.
    @discardableResult
    public mutating func confirm(_ confirmed: MirrorPlaybackState,
                                 now: TimeInterval) -> MirrorToggleCommand? {
        guard now.isFinite else { return nil }
        invalidate()
        if confirmed != .unknown {
            state = confirmed
            evidence = .confirmed
        }
        return nil
    }

    /// Record a passive inspection without requesting playback. The adapter
    /// must reject obsolete captures before calling this explicit reset.
    public mutating func recordObservation(_ observed: MirrorPlaybackState, now: TimeInterval) {
        guard now.isFinite else { return }
        invalidate()
        if observed != .unknown {
            state = observed
            evidence = .observed
        }
    }

    /// A fresh request always starts with unknown state. Only duplicates of an
    /// active request coalesce; a later request for the same target observes anew.
    @discardableResult
    public mutating func request(_ target: MirrorPlaybackState,
                                 now: TimeInterval) -> MirrorToggleCommand? {
        guard now.isFinite, target != .unknown else { return nil }
        if hasActiveRequest, desiredState == target { return nil }
        invalidate()
        desiredState = target
        phase = .observingBefore
        phaseStartedAt = now
        return nil
    }

    /// Accept a fresh result only for the observation phase that started it.
    /// An unknown initial result aborts without clicking. A post-click mismatch
    /// also aborts; it must never create a second toggle in this request.
    @discardableResult
    public mutating func observe(_ observed: MirrorPlaybackState, epoch observationEpoch: UInt64,
                                 now: TimeInterval) -> MirrorToggleCommand? {
        guard observationEpoch == epoch, now.isFinite, let desired = desiredState,
              phase == .observingBefore || phase == .observingAfter,
              let startedAt = phaseStartedAt, now >= startedAt else { return nil }
        guard now - startedAt <= commandTimeout, observed != .unknown else {
            invalidate()
            return nil
        }
        if phase == .observingAfter {
            guard observed == desired else { invalidate(); return nil }
            finishObservation(observed)
            return nil
        }
        state = observed
        evidence = .observed
        if observed == desired {
            finishObservation(observed)
            return nil
        }
        let command = MirrorToggleCommand(id: UUID(), epoch: epoch, from: observed, target: desired)
        pendingCommand = command
        phase = .readyToPost
        phaseStartedAt = now
        return command
    }

    /// Cancellation, a newer request, a posted click or manual input invalidates
    /// this token. Call the timed overload immediately before sending input.
    public func canPost(_ command: MirrorToggleCommand) -> Bool {
        phase == .readyToPost && pendingCommand == command && command.epoch == epoch
            && evidence == .observed && state == command.from && state != .unknown
            && desiredState == command.target
    }

    public func canPost(_ command: MirrorToggleCommand, now: TimeInterval) -> Bool {
        guard now.isFinite, let startedAt = phaseStartedAt,
              now >= startedAt, now - startedAt <= commandTimeout else { return false }
        return canPost(command)
    }

    /// After posting, capture a NEW observation using the NEW epoch. No state
    /// is inferred from delivery or from a timer, even when posting succeeded.
    @discardableResult
    public mutating func didPost(_ command: MirrorToggleCommand,
                                 now: TimeInterval) -> Bool {
        guard canPost(command, now: now) else { return false }
        epoch &+= 1
        phase = .observingAfter
        phaseStartedAt = now
        state = .unknown
        evidence = .unknown
        return true
    }

    /// Time can only invalidate an overdue phase. It cannot complete a request
    /// successfully or return a command, including after a long suspension.
    @discardableResult
    public mutating func tick(now: TimeInterval) -> MirrorToggleCommand? {
        guard now.isFinite, hasActiveRequest, let startedAt = phaseStartedAt,
              now - startedAt > commandTimeout else { return nil }
        invalidate()
        return nil
    }

    /// External input, lost windows or permissions, and disabled control all
    /// discard both the active target and observations already in flight.
    public mutating func invalidate() {
        epoch &+= 1
        state = .unknown
        evidence = .unknown
        desiredState = nil
        pendingCommand = nil
        phase = .idle
        phaseStartedAt = nil
    }

    /// The matching click remains cancellable during post-click verification,
    /// although didPost has advanced the observation epoch. Old tokens cannot
    /// cancel another request because every command has a distinct identity.
    @discardableResult
    public mutating func fail(_ command: MirrorToggleCommand) -> Bool {
        guard pendingCommand == command else { return false }
        invalidate()
        return true
    }

    private mutating func finishObservation(_ observed: MirrorPlaybackState) {
        state = observed
        evidence = .observed
        desiredState = nil
        pendingCommand = nil
        phase = .idle
        phaseStartedAt = nil
    }
}
