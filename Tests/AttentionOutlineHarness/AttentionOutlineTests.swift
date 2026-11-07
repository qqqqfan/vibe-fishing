import Foundation
import CoreGraphics

@main
enum AttentionOutlineTests {
    static func main() {
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            precondition(condition(), label)
            assertions += 1
        }
        typealias G = AttentionOutlineGeometry
        let ax = CGRect(x: 20, y: 40, width: 800, height: 700)
        let cocoa = CGRect(x: 20, y: 160, width: 800, height: 700)
        check(G.appKitFrame(forAX: ax, primaryTop: 900) == cocoa, "primary screen vertical conversion")
        check(G.appKitFrame(forAX: cocoa, primaryTop: 900) == ax, "coordinate conversion is reversible")
        check(G.appKitFrame(forAX: CGRect(x: -1500, y: 100, width: 1000, height: 600), primaryTop: 900)
            == CGRect(x: -1500, y: 200, width: 1000, height: 600), "left display preserves negative x")
        check(G.appKitFrame(forAX: CGRect(x: 100, y: -800, width: 800, height: 600), primaryTop: 900)?.minY == 1100,
              "display above primary")
        check(G.appKitFrame(forAX: CGRect(x: 100, y: 1000, width: 800, height: 600), primaryTop: 900)?.minY == -700,
              "display below primary")
        check(G.appKitFrame(forAX: .zero, primaryTop: 900) == nil, "zero dimensions rejected")
        check(G.appKitFrame(forAX: CGRect(x: 0, y: 0, width: -1, height: 100), primaryTop: 900) == nil,
              "negative dimensions rejected")
        check(G.appKitFrame(forAX: CGRect(x: CGFloat.infinity, y: 0, width: 100, height: 100), primaryTop: 900) == nil,
              "nonfinite frame rejected")
        check(G.appKitFrame(forAX: ax, primaryTop: .nan) == nil, "invalid primary display rejected")
        let panel = G.panelFrame(for: cocoa)
        check(panel == CGRect(x: 8, y: 148, width: 824, height: 724), "glow has room outside all four edges")
        let ring = G.outlineRect(in: CGRect(origin: .zero, size: panel.size))
        check(ring.offsetBy(dx: panel.minX, dy: panel.minY) == cocoa.insetBy(dx: 1.25, dy: 1.25),
              "2.5 point stroke lands within target bounds")
        check(G.framesMatch(ax, ax.offsetBy(dx: 2, dy: -2)), "allow small window server rounding")
        check(!G.framesMatch(ax, ax.offsetBy(dx: 3, dy: 0)), "reject neighboring window frame")
        check(!G.framesMatch(ax, CGRect(x: 20, y: 40, width: 803, height: 700)), "reject different window size")
        check(!G.framesMatch(.zero, .zero), "invalid frames cannot identify a target")
        check(G.acknowledgesReturn(point: CGPoint(x: 100, y: 200), targetFrame: cocoa, targetPID: 42, frontmostPID: 42),
              "click inside active target acknowledges")
        check(!G.acknowledgesReturn(point: CGPoint(x: 100, y: 200), targetFrame: cocoa, targetPID: 42, frontmostPID: 43),
              "click over target coordinates in another app does not acknowledge")
        check(!G.acknowledgesReturn(point: CGPoint(x: 900, y: 200), targetFrame: cocoa, targetPID: 42, frontmostPID: 42),
              "click outside target does not acknowledge")
        check(!G.acknowledgesReturn(point: CGPoint(x: 100, y: 200), targetFrame: cocoa, targetPID: 42, frontmostPID: nil),
              "unknown foreground does not acknowledge")
        check(!G.acknowledgesReturn(point: .zero, targetFrame: .zero, targetPID: 42, frontmostPID: 42),
              "invalid target cannot acknowledge")
        print("Attention outline: \(assertions) assertions passed (no windows or input created)")
    }
}
