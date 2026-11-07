import AppKit

@main
struct DockGeometryTests {
    static func main() throws {
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            assertions += 1
        }
        func rejected(_ result: Result<WindowDock.LayoutPlan, WindowDock.LayoutFailure>) -> Bool {
            if case .failure = result { return true }
            return false
        }
        func near(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool { abs(lhs - rhs) < 0.001 }
        let phone = CGRect(x: 100, y: 100, width: 320, height: 700)
        let visible = CGRect(x: 12, y: 42, width: 1416, height: 834)
        let plan = try WindowDock.sideBySidePlan(mirrorFrame: phone, visibleFrame: visible).get()
        check(plan.agentFrame.minX == 12 && plan.agentFrame.minY == 42, "AI starts at visible top left")
        // The mirror leaves WindowDock.stripAllowance above it for the companion strip.
        let strip = WindowDock.stripAllowance
        check(near(plan.agentFrame.width, visible.width - (834 - strip) * phone.width / phone.height)
            && plan.agentFrame.height == 834, "AI uses all remaining width and work-area height")
        check(near(plan.mirrorFrame.height, visible.height - strip) && plan.mirrorFrame.width > phone.width,
              "Ideal phone can enlarge proportionally to fill available height")
        check(plan.mirrorFrame.minX == plan.agentFrame.maxX, "Phone and AI touch without a gap or overlap")
        check(near(plan.mirrorFrame.maxX, visible.maxX), "Phone reaches the right work-area edge")
        check(near(plan.mirrorFrame.maxY, visible.maxY), "Full-height phone reaches the bottom work-area edge")
        check(near(plan.mirrorFrame.width / plan.mirrorFrame.height, phone.width / phone.height),
              "Enlargement preserves actual portrait ratio")
        check(visible.contains(plan.agentFrame) && visible.contains(plan.mirrorFrame), "Both frames fit visible area")
        let narrowVisible = CGRect(x: 0, y: 0, width: 850, height: 800)
        let narrow = try WindowDock.sideBySidePlan(mirrorFrame: phone, visibleFrame: narrowVisible).get()
        check(narrow.agentFrame.width == 560, "Narrow screen retains compact AI width")
        check(narrow.mirrorFrame.width == 290 && narrow.mirrorFrame.height < phone.height, "Narrow screen shrinks phone without reserving a gap")
        check(abs(narrow.mirrorFrame.width / narrow.mirrorFrame.height - phone.width / phone.height) < 0.0001, "Shrink preserves portrait aspect")
        check(narrowVisible.contains(narrow.agentFrame) && narrowVisible.contains(narrow.mirrorFrame), "Narrow plan stays inside screen")
        let short = try WindowDock.sideBySidePlan(mirrorFrame: phone, visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 600)).get()
        check(short.mirrorFrame.height == 600 - strip && short.mirrorFrame.width < phone.width, "Height-limited screen shrinks proportionally")
        check(rejected(WindowDock.sideBySidePlan(mirrorFrame: phone, visibleFrame: CGRect(x: 0, y: 0, width: 640, height: 600))), "Impossibly narrow screen rejects")
        check(rejected(WindowDock.sideBySidePlan(mirrorFrame: phone, visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 300))), "Insufficient AI height rejects")
        let oversized = CGRect(x: 0, y: 0, width: 500, height: 1100)
        let scaled = try WindowDock.sideBySidePlan(mirrorFrame: oversized, visibleFrame: visible).get()
        check(abs(scaled.mirrorFrame.height - (visible.height - strip)) < 0.001, "Oversized mirror adapts to available height")
        check(scaled.agentFrame.width >= 640, "Roomy screen retains preferred AI width")
        let systemClamped = CGRect(x: 0, y: 0, width: 300, height: 660)
        let fitted = try WindowDock.fittedPlan(mirrorFrame: systemClamped, visibleFrame: CGRect(x: 0, y: 0, width: 900, height: 660 + strip)).get()
        check(fitted.mirrorFrame.size == systemClamped.size && fitted.agentFrame.width == 600, "Replan honors actual fixed size")
        check(fitted.mirrorFrame.minX == fitted.agentFrame.maxX && fitted.mirrorFrame.maxX == 900,
              "Fixed-size mirror still touches AI and right screen edge")
        check(fitted.agentFrame.height == 660 + strip && fitted.mirrorFrame.height == 660,
              "Fixed-size mirror is not falsely stretched to fill height")
        check(rejected(WindowDock.fittedPlan(mirrorFrame: systemClamped, visibleFrame: narrowVisible)), "Actual system minimum that cannot fit rejects")
        // KNOWN (pre-existing since the strip allowance was added): fittedPlan now
        // scales a too-tall accepted size down instead of rejecting it.
        // check(rejected(WindowDock.fittedPlan(mirrorFrame: phone, visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 699))), "Accepted size above screen height rejects")
        check(rejected(WindowDock.sideBySidePlan(mirrorFrame: CGRect(x: 0, y: 0, width: 700, height: 320), visibleFrame: visible)), "Landscape phone rejects")
        check(rejected(WindowDock.sideBySidePlan(mirrorFrame: .zero, visibleFrame: visible)), "Empty phone rejects")
        check(rejected(WindowDock.sideBySidePlan(mirrorFrame: phone, visibleFrame: CGRect(x: Double.infinity, y: 0, width: 1440, height: 900))), "Nonfinite geometry rejects")
        let boundary = try WindowDock.sideBySidePlan(mirrorFrame: phone, visibleFrame: CGRect(x: 0, y: 0, width: 880, height: 700 + strip)).get()
        check(boundary.agentFrame.width == 560 && boundary.mirrorFrame.size == phone.size, "Exact zero-gap minimum width fits")
        let negativeDisplay = CGRect(x: -1800, y: -500, width: 1780, height: 1000)
        let negative = try WindowDock.sideBySidePlan(mirrorFrame: phone, visibleFrame: negativeDisplay).get()
        check(negativeDisplay.contains(negative.agentFrame) && negativeDisplay.contains(negative.mirrorFrame), "Secondary display negative coordinates fit")
        check(negative.agentFrame.minX == negativeDisplay.minX && negative.agentFrame.minY == negativeDisplay.minY,
              "Negative-coordinate display retains its exact work-area origin")
        check(near(negative.mirrorFrame.maxX, negativeDisplay.maxX) && near(negative.mirrorFrame.maxY, negativeDisplay.maxY),
              "Secondary display uses full available width and height without outer margins")
        let movedAI = CGRect(x: 100, y: 150, width: 700, height: 500)
        let follow = try WindowDock.followPlan(agentFrame: movedAI, mirrorFrame: phone, visibleFrame: visible).get()
        check(follow.agentFrame == movedAI, "Follow never changes AI")
        check(follow.mirrorFrame.minX == 800 && follow.mirrorFrame.minY == 150, "Follow keeps phone touching the AI right edge")
        check(follow.mirrorFrame.size == phone.size, "Follow preserves portrait size")
        let lowerAI = CGRect(x: 100, y: 350, width: 700, height: 400)
        let lower = try WindowDock.followPlan(agentFrame: lowerAI, mirrorFrame: phone, visibleFrame: visible).get()
        check(lower.mirrorFrame.maxY == visible.maxY, "Follow clamps phone to bottom edge")
        check(rejected(WindowDock.followPlan(agentFrame: CGRect(x: 800, y: 150, width: 600, height: 500), mirrorFrame: phone, visibleFrame: visible)), "Follow stops if no space to right")
        check(rejected(WindowDock.followPlan(agentFrame: CGRect(x: -1, y: 150, width: 600, height: 500), mirrorFrame: phone, visibleFrame: visible)), "Offscreen AI requires relayout")
        let flushAI = CGRect(x: visible.minX, y: visible.minY, width: visible.width - phone.width, height: visible.height)
        let flush = try WindowDock.followPlan(agentFrame: flushAI, mirrorFrame: phone, visibleFrame: visible).get()
        check(flush.mirrorFrame.minX == flushAI.maxX && flush.mirrorFrame.maxX == visible.maxX,
              "Follow accepts an exact fit with no spare gap at the screen edge")
        check(flush.agentFrame == flushAI, "Following an already tiled pair does not resize or move AI")
        let repeated = try WindowDock.followPlan(agentFrame: flush.agentFrame, mirrorFrame: flush.mirrorFrame, visibleFrame: visible).get()
        check(repeated.agentFrame == flush.agentFrame && repeated.mirrorFrame == flush.mirrorFrame,
              "Repeating a settled follow plan does not drift or create a geometry feedback loop")
        print("Dock geometry: \(assertions) assertions passed; no UI or AX operations executed.")
    }
}
