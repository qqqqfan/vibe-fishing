import Foundation
import CoreGraphics

/// Pure geometry shared with the outline tests. AX and Window Server coordinates
/// grow downwards from the primary display; AppKit coordinates grow upwards.
enum AttentionOutlineGeometry {
    static let padding: CGFloat = 12

    static func isUsable(_ frame: CGRect) -> Bool {
        frame.minX.isFinite && frame.minY.isFinite && frame.maxX.isFinite && frame.maxY.isFinite
            && frame.size.width.isFinite && frame.size.height.isFinite
            && frame.size.width > 0 && frame.size.height > 0
    }

    static func appKitFrame(forAX frame: CGRect, primaryTop: CGFloat) -> CGRect? {
        guard isUsable(frame), primaryTop.isFinite else { return nil }
        let result = CGRect(x: frame.minX, y: primaryTop - frame.maxY, width: frame.width, height: frame.height)
        return isUsable(result) ? result : nil
    }

    static func panelFrame(for frame: CGRect) -> CGRect {
        frame.insetBy(dx: -padding, dy: -padding)
    }

    static func outlineRect(in panelBounds: CGRect) -> CGRect {
        panelBounds.insetBy(dx: padding + 1.25, dy: padding + 1.25)
    }

    static func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        guard isUsable(lhs), isUsable(rhs) else { return false }
        return abs(lhs.minX - rhs.minX) <= 2 && abs(lhs.minY - rhs.minY) <= 2
            && abs(lhs.width - rhs.width) <= 2 && abs(lhs.height - rhs.height) <= 2
    }

    static func acknowledgesReturn(point: CGPoint, targetFrame: CGRect,
                                    targetPID: Int32, frontmostPID: Int32?) -> Bool {
        frontmostPID == targetPID && isUsable(targetFrame) && targetFrame.contains(point)
    }
}
