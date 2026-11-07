import Foundation

/// One 100 ms reading of the two pixel-free signals. `audioLevelDB` is nil when
/// no process tap is delivering audio. `streamLoad` is the mirroring media
/// daemon's CPU in milliseconds per second, nil when it cannot be read.
public struct PlaybackSignalSample: Equatable {
    public let time: TimeInterval
    public let audioLevelDB: Double?
    public let streamLoad: Double?

    public init(time: TimeInterval, audioLevelDB: Double?, streamLoad: Double?) {
        self.time = time
        self.audioLevelDB = audioLevelDB
        self.streamLoad = streamLoad
    }
}

public enum PlaybackSignalReason: String, Codable {
    case noEvidence, sound, silentAndStill, silentVideo, silentLightMotion
    case streamMoving, streamStill, silenceOnly, settling
}

/// Continuously fuses "is the mirror making sound" and "is the mirror receiving
/// video". Sound alone proves playback quickly. Pause needs both silence and a
/// still stream, so a quiet line or a static shot does not read as paused.
/// `strong` marks evidence good enough to correct a click that had no effect.
public struct PlaybackSignalFusion {
    public struct Configuration: Equatable {
        public var audioActiveDB = -70.0
        public var audioAttack: TimeInterval = 0.10
        public var silenceHold: TimeInterval = 0.8
        public var streamIdleLoad = 60.0
        public var streamVideoLoad = 150.0
        public var streamIdleHold: TimeInterval = 0.6
        public var silentVideoHold: TimeInterval = 1.5
        public var silentGiveUp: TimeInterval = 2.5
        public var streamOnlyIdleHold: TimeInterval = 1.0
        public var streamOnlyVideoHold: TimeInterval = 0.5
        public var audioOnlySilence: TimeInterval = 1.2
        public init() {}
    }

    public struct Reading: Equatable {
        public var state: MirrorPlaybackState = .unknown
        /// The latest signals disagree with `state` but do not yet replace it.
        public var settling = true
        public var strong = false
        public var reason: PlaybackSignalReason = .noEvidence
        /// Time of the last change to `state`.
        public var changedAt: TimeInterval = 0
        public init() {}
    }

    public private(set) var reading = Reading()
    /// Silence means nothing until this session has heard real samples: denied
    /// capture and a muted phone both deliver digital zero.
    public private(set) var audioProven = false
    /// Set when the system confirms audio capture is granted. Silence is then
    /// real silence from the start, so a paused video right after launch is
    /// not mistaken for playing because the screen is busy.
    public var audioTrusted = false
    public private(set) var smoothedLoad: Double?

    private let configuration: Configuration
    private var audioRunStart: TimeInterval?
    private var lastAudioAt: TimeInterval?
    private var streamIdleSince: TimeInterval?
    private var streamVideoSince: TimeInterval?
    private var lastTime: TimeInterval?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Returns true when the published reading changed.
    @discardableResult
    public mutating func ingest(_ sample: PlaybackSignalSample) -> Bool {
        guard sample.time.isFinite else { return false }
        if let lastTime, sample.time < lastTime { return false }
        lastTime = sample.time
        updateAudio(sample)
        updateStream(sample)
        let next = decide(sample)
        var updated = reading
        if let next {
            if next.state != reading.state { updated.changedAt = sample.time }
            updated.state = next.state
            updated.settling = false
            updated.strong = next.strong
            updated.reason = next.reason
        } else {
            updated.settling = true
            updated.reason = .settling
        }
        guard updated != reading else { return false }
        reading = updated
        return true
    }

    /// Forget accumulated evidence, for example after rebinding the window.
    public mutating func reset() {
        let trusted = audioTrusted
        self = PlaybackSignalFusion(configuration: configuration)
        audioTrusted = trusted
    }

    private mutating func updateAudio(_ sample: PlaybackSignalSample) {
        guard let level = sample.audioLevelDB, level.isFinite, level >= configuration.audioActiveDB else {
            audioRunStart = nil
            return
        }
        audioProven = true
        lastAudioAt = sample.time
        if audioRunStart == nil { audioRunStart = sample.time }
    }

    private mutating func updateStream(_ sample: PlaybackSignalSample) {
        guard let load = sample.streamLoad, load.isFinite, load >= 0 else {
            smoothedLoad = nil
            streamIdleSince = nil
            streamVideoSince = nil
            return
        }
        let smoothed = smoothedLoad.map { $0 * 0.6 + load * 0.4 } ?? load
        smoothedLoad = smoothed
        if smoothed < configuration.streamIdleLoad {
            if streamIdleSince == nil { streamIdleSince = sample.time }
        } else { streamIdleSince = nil }
        if smoothed >= configuration.streamVideoLoad {
            if streamVideoSince == nil { streamVideoSince = sample.time }
        } else { streamVideoSince = nil }
    }

    private func decide(_ sample: PlaybackSignalSample)
        -> (state: MirrorPlaybackState, strong: Bool, reason: PlaybackSignalReason)? {
        let now = sample.time
        func held(_ since: TimeInterval?, _ duration: TimeInterval) -> Bool {
            since.map { now - $0 >= duration } ?? false
        }
        if held(audioRunStart, configuration.audioAttack) { return (.playing, true, .sound) }
        // Inside an audio run shorter than the attack, nothing is decided yet.
        if audioRunStart != nil { return nil }
        let audioUsable = sample.audioLevelDB != nil && (audioProven || audioTrusted)
        let streamUsable = smoothedLoad != nil
        if audioUsable {
            // Once real sound has been heard, sound decides. The stream load is
            // only a confidence hint: on 2026-11-05 a paused Douyin page kept it
            // at 100-370 ms/s (UI animation), which read as "silent video" and
            // blocked every resume click.
            let silentFor = lastAudioAt.map { now - $0 } ?? .infinity
            guard silentFor >= configuration.silenceHold else { return nil }
            if streamUsable, held(streamIdleSince, configuration.streamIdleHold) { return (.paused, true, .silentAndStill) }
            return silentFor >= configuration.audioOnlySilence ? (.paused, false, .silenceOnly) : nil
        }
        guard streamUsable else { return nil }
        if held(streamIdleSince, configuration.streamOnlyIdleHold) { return (.paused, false, .streamStill) }
        if held(streamVideoSince, configuration.streamOnlyVideoHold) { return (.playing, false, .streamMoving) }
        return nil
    }
}
