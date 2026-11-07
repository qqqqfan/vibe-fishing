import Foundation

/// Merges whole-turn events from every connected AI client into play/pause intent.
///
/// The rule is about the user's attention, not about any one app: when the user
/// sends something (a turn starts, or resumes after approval) the video plays;
/// when any turn finishes or needs the user, the video pauses and the user is
/// pointed back. Several sources may describe the same turn (an official hook
/// and the window observer). Duplicates are harmless because the player adapter
/// is idempotent and repeated reminders are coalesced here.
public struct AgentActivityHub {
    public struct Key: Hashable {
        public let source: String
        public let sessionID: String
        public init(source: String, sessionID: String) {
            self.source = source
            self.sessionID = sessionID
        }
    }

    public struct Entry: Equatable {
        public var turnID: String
        public var state: AgentState
        public var timestamp: TimeInterval
        public var updatedAt: TimeInterval
    }

    public struct Change: Equatable {
        public let key: Key
        public let state: AgentState
    }

    public private(set) var entries: [Key: Entry] = [:]
    public private(set) var manuallyPaused = false
    /// The most recent accepted transition, for the interface and reminders.
    public private(set) var lastChange: Change?

    private var lastStopAt: TimeInterval = -.infinity
    private var lastStartAt: TimeInterval = -.infinity
    private var seenEventIDs = Set<String>()
    private var seenOrder: [String] = []
    private var retired = Set<String>()
    private var retiredOrder: [String] = []

    private static let maximumEventAge: TimeInterval = 120
    private static let futureClockTolerance: TimeInterval = 5
    /// A turn nobody has reported on for this long is treated as abandoned.
    public static let staleRunningAfter: TimeInterval = 45 * 60
    /// Two sources finishing the same turn produce one reminder.
    public static let reminderCoalescing: TimeInterval = 6

    public init() {}

    public var anyRunning: Bool { entries.values.contains { $0.state == .running } }
    public var anyWaitingForUser: Bool { entries.values.contains { $0.state == .needsInput } }

    public mutating func consume(_ event: AgentEvent, now: TimeInterval) -> [RelayAction] {
        guard now.isFinite, event.timestamp.isFinite,
              !event.id.isEmpty, !event.source.isEmpty, !event.sessionID.isEmpty, !event.turnID.isEmpty,
              event.timestamp >= now - Self.maximumEventAge,
              event.timestamp <= now + Self.futureClockTolerance,
              !seenEventIDs.contains(event.id) else { return [] }
        remember(event.id)
        let key = Key(source: event.source, sessionID: event.sessionID)
        let turnKey = Self.turnKey(key, event.turnID)

        guard let entry = entries[key], entry.turnID == event.turnID else {
            // Only the start of work can open a turn; late tail events of an
            // older or unknown turn must not resume or pause anything.
            guard event.state == .running, !retired.contains(turnKey) else { return [] }
            if let entry = entries[key] {
                guard event.timestamp > entry.timestamp else { return [] }
                retire(Self.turnKey(key, entry.turnID))
            }
            entries[key] = Entry(turnID: event.turnID, state: .running, timestamp: event.timestamp, updatedAt: now)
            lastChange = Change(key: key, state: .running)
            return start(now: now)
        }

        guard event.timestamp >= entry.timestamp else { return [] }
        entries[key]?.timestamp = event.timestamp
        entries[key]?.updatedAt = now
        // A finished turn stays finished; only a new turn can restart.
        guard !Self.isTerminal(entry.state), event.state != entry.state else { return [] }

        switch event.state {
        case .running:
            // Continuation after an approval: the user has just acted.
            entries[key]?.state = .running
            lastChange = Change(key: key, state: .running)
            return start(now: now)
        case .needsInput, .completed, .failed:
            entries[key]?.state = event.state
            if Self.isTerminal(event.state) { retire(turnKey) }
            lastChange = Change(key: key, state: event.state)
            return stop(now: now, remind: true)
        case .cancelled:
            // The user stopped it, so they are already looking at the app.
            entries[key]?.state = .cancelled
            retire(turnKey)
            lastChange = Change(key: key, state: .cancelled)
            return stop(now: now, remind: false)
        case .idle, .unknown:
            return []
        }
    }

    /// Drops abandoned turns without touching playback.
    public mutating func tick(now: TimeInterval) {
        guard now.isFinite else { return }
        for (key, entry) in entries where now - entry.updatedAt > Self.staleRunningAfter {
            if entry.state == .running || entry.state == .needsInput { retire(Self.turnKey(key, entry.turnID)) }
            entries[key] = nil
        }
    }

    /// Forget one source entirely, for example a window that closed.
    public mutating func remove(source: String, sessionID: String) {
        let key = Key(source: source, sessionID: sessionID)
        if let entry = entries[key] { retire(Self.turnKey(key, entry.turnID)) }
        entries[key] = nil
    }

    public mutating func setManualPaused(_ paused: Bool) -> [RelayAction] {
        guard paused != manuallyPaused else { return [] }
        manuallyPaused = paused
        if paused { return [.pause] }
        return anyRunning ? [.play] : []
    }

    /// Stop everything in flight. History is kept so late events cannot replay.
    public mutating func reset() -> [RelayAction] {
        for (key, entry) in entries { retire(Self.turnKey(key, entry.turnID)) }
        entries.removeAll()
        lastChange = nil
        return [.pause]
    }

    private mutating func start(now: TimeInterval) -> [RelayAction] {
        lastStartAt = now
        // The latest thing the user did wins. A reminder for another session was
        // already shown, and a stale approval must never block resuming.
        guard !manuallyPaused else { return [] }
        return [.play]
    }

    private mutating func stop(now: TimeInterval, remind: Bool) -> [RelayAction] {
        defer { if remind { lastStopAt = now } }
        // A stop that duplicates one just handled, with no new start between, is quiet.
        let duplicate = now - lastStopAt < Self.reminderCoalescing && lastStopAt >= lastStartAt
        return remind && !duplicate ? [.pause, .requestAttention] : [.pause]
    }

    private static func isTerminal(_ state: AgentState) -> Bool {
        state == .completed || state == .failed || state == .cancelled
    }

    private static func turnKey(_ key: Key, _ turn: String) -> String {
        key.source + "\u{1F}" + key.sessionID + "\u{1F}" + turn
    }

    private mutating func remember(_ id: String) {
        seenEventIDs.insert(id)
        seenOrder.append(id)
        if seenOrder.count > 4_096 { seenEventIDs.remove(seenOrder.removeFirst()) }
    }

    private mutating func retire(_ turnKey: String) {
        guard retired.insert(turnKey).inserted else { return }
        retiredOrder.append(turnKey)
        if retiredOrder.count > 1_024 { retired.remove(retiredOrder.removeFirst()) }
    }
}

/// Turns periodic window observations into whole-turn transitions.
/// Running is entered as soon as a stop control appears. Completion requires the
/// stop control to stay gone across readable scans, so a control that briefly
/// re-renders between tool calls does not end the turn.
public struct GenerationDetector {
    public struct Observation: Equatable {
        public var readable: Bool
        public var stopVisible: Bool
        public var approvalVisible: Bool
        public init(readable: Bool, stopVisible: Bool, approvalVisible: Bool) {
            self.readable = readable
            self.stopVisible = stopVisible
            self.approvalVisible = approvalVisible
        }
    }

    public private(set) var state: AgentState = .idle
    public private(set) var turnID = UUID().uuidString
    public var completionHold: TimeInterval
    public var approvalHold: TimeInterval
    private var stopLastSeen: TimeInterval?
    private var approvalLastSeen: TimeInterval?
    private var approvalSince: TimeInterval?

    public init(completionHold: TimeInterval = 1.2, approvalHold: TimeInterval = 0.4) {
        self.completionHold = completionHold
        self.approvalHold = approvalHold
    }

    /// Returns a state only when it changed.
    public mutating func observe(_ observation: Observation, at time: TimeInterval) -> AgentState? {
        guard observation.readable else { return nil }
        let active = state == .running || state == .needsInput
        if observation.approvalVisible, active {
            approvalLastSeen = time
            if approvalSince == nil { approvalSince = time }
            if state == .running, let since = approvalSince, time - since >= approvalHold {
                return transition(to: .needsInput)
            }
            return nil
        }
        approvalSince = nil
        if observation.stopVisible {
            stopLastSeen = time
            if state != .running {
                if state != .needsInput { turnID = UUID().uuidString }
                return transition(to: .running)
            }
            return nil
        }
        guard active else { return nil }
        // Completion needs every sign of work, including a pending approval
        // that was rejected, to stay gone for the hold period.
        let lastActivity = max(stopLastSeen ?? -.infinity, approvalLastSeen ?? -.infinity)
        guard lastActivity.isFinite, time - lastActivity >= completionHold else { return nil }
        stopLastSeen = nil
        approvalLastSeen = nil
        return transition(to: .completed)
    }

    private mutating func transition(to next: AgentState) -> AgentState? {
        guard next != state else { return nil }
        state = next
        return next
    }
}

/// Matches control names, never message text. Exact phrases avoid confusing a
/// chat title with a control. Additional phrases can be supplied per install.
public struct ControlVocabulary: Equatable, Codable {
    public var stop: [String]
    public var approval: [String]

    public static let standard = ControlVocabulary(
        stop: ["stop", "stop generating", "stop generation", "stop response", "stop responding", "stop streaming",
               "stop run", "stop task", "stop agent", "cancel generation", "cancel response", "interrupt",
               "停止", "停止生成", "停止响应", "停止回答", "停止输出", "停止运行", "停止任务", "取消生成", "中止生成",
               "中断", "终止", "停止流式传输"],
        approval: ["allow once", "allow this time", "always allow", "approve", "approve once", "approve and continue",
                   "allow", "run command", "允许一次", "仅允许一次", "本次允许", "始终允许", "批准", "批准并继续",
                   "允许此操作", "允许", "运行命令"])

    public init(stop: [String], approval: [String]) {
        self.stop = stop
        self.approval = approval
    }

    public func merged(with other: ControlVocabulary) -> ControlVocabulary {
        ControlVocabulary(stop: Array(Set(stop + other.stop)).sorted(),
                          approval: Array(Set(approval + other.approval)).sorted())
    }

    public static func normalize(_ label: String) -> String {
        String(label.prefix(80)).lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " .…:：").union(.whitespacesAndNewlines))
    }

    public func isStop(_ label: String) -> Bool { Self.matches(Self.normalize(label), stop) }
    public func isApproval(_ label: String) -> Bool { Self.matches(Self.normalize(label), approval) }

    private static func matches(_ label: String, _ phrases: [String]) -> Bool {
        guard !label.isEmpty, label.count <= 40 else { return false }
        return phrases.contains { phrase in
            let phrase = normalize(phrase)
            if label == phrase { return true }
            // "Stop (⌘.)", "停止（Esc）", "Stop generating ⌘⌫"
            for separator in [" (", "（", " ⌘", " ⌃", " esc", " ctrl"] where label.hasPrefix(phrase + separator) { return true }
            return false
        }
    }
}
