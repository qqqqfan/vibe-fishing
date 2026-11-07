import Foundation

@main struct ShortcutAndPlaybackRegression {
    static func main() {
        precondition(PlaybackShortcutLabel.format(code: 48, flags: 1 << 18, characters: "\t") == "⌃Tab")
        precondition(PlaybackShortcutLabel.format(code: 36, flags: 1 << 20, characters: "\r") == "⌘Return")
        precondition(PlaybackShortcutLabel.format(code: 49, flags: (1 << 18) | (1 << 19), characters: " ") == "⌃⌥Space")
        precondition(PlaybackShortcutLabel.key(123) == "←")
        precondition(PlaybackShortcutLabel.key(122) == "F1")
        precondition(PlaybackShortcutLabel.key(0, characters: "a") == "A")
        precondition(PlaybackShortcutLabel.key(250, characters: "\u{0}") == "Key 250")
        var clock = VideoPlaybackDuration()
        precondition(clock.sample(playing: true, uptime: 1) == 0)
        precondition(clock.sample(playing: true, uptime: 2) == 1)
        precondition(clock.sample(playing: false, uptime: 3) == 1)
        precondition(clock.sample(playing: false, uptime: 4) == 1)
        precondition(clock.sample(playing: true, uptime: 5) == 1)
        precondition(clock.sample(playing: true, uptime: 6) == 2)
        precondition(clock.sample(playing: true, uptime: 100) == 2)
        precondition(clock.sample(playing: true, uptime: 99) == 2)
        clock.reset()
        precondition(clock.seconds == 0)
        print("快捷键与播放计时回归：16 项检查通过")
    }
}
