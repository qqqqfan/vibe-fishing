import Foundation

/// Conservative evidence for user input changing an external toggle player.
/// Event routing metadata can name a forwarding process rather than the app
/// beneath the pointer. An unrelated PID must not veto a foreground hit.
public enum MirrorInputPolicy {
    public static func affectsMirror(isKeyboard: Bool, routedToMirror: Bool,
                                     mirrorIsFrontmost: Bool, pointInsideMirror: Bool,
                                     topmostHitIsMirror: Bool) -> Bool {
        if isKeyboard { return routedToMirror || mirrorIsFrontmost }
        return routedToMirror || topmostHitIsMirror || (mirrorIsFrontmost && pointInsideMirror)
    }
}
