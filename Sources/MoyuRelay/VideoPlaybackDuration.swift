import Foundation

/// Accumulates observed playback, not AI generation time. Long gaps (sleep or
/// suspended polling) are excluded because playback during them is unknown.
struct VideoPlaybackDuration {
    private(set) var seconds: TimeInterval = 0
    private var lastSample: TimeInterval?
    private var wasPlaying = false

    mutating func reset() { self = VideoPlaybackDuration() }

    @discardableResult
    mutating func sample(playing: Bool, uptime: TimeInterval) -> TimeInterval {
        defer { lastSample = uptime; wasPlaying = playing }
        guard let lastSample else { return seconds }
        let delta = uptime - lastSample
        if playing && wasPlaying && delta > 0 && delta <= 2 {
            seconds += delta
        }
        return seconds
    }
}
