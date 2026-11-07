import SwiftUI

/// A decorative explanation of the handoff, never a detected playback state.
struct RelayScene: View {
    var compact = false

    var body: some View {
        ZStack {
            RelaySceneConnections()
                .stroke(VFTheme.outline.opacity(0.75), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                .frame(width: 360, height: 212)

            VFLogo(size: 198)

            sceneLabel("vibe coding", symbol: "sparkle", tint: VFTheme.lilac)
                .offset(x: -130, y: -56)
            sceneLabel("摸鱼刷视频", symbol: "play.fill", tint: VFTheme.sky.opacity(0.55))
                .offset(x: 126, y: 58)
        }
        .frame(maxWidth: .infinity)
        .frame(height: compact ? 170 : 212)
        .scaleEffect(compact ? 0.8 : 1)
        .accessibilityHidden(true)
    }

    private func sceneLabel(_ text: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(VFTheme.ink)
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(tint, in: Capsule())
        .overlay(Capsule().strokeBorder(VFTheme.outline.opacity(0.65), lineWidth: 1))
        .shadow(color: VFTheme.ink.opacity(0.05), radius: 0, x: 0, y: 2)
    }
}

private struct RelaySceneConnections: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 82, y: 50))
        path.addLine(to: CGPoint(x: 103, y: 50))
        path.addQuadCurve(to: CGPoint(x: 111, y: 58), control: CGPoint(x: 111, y: 50))
        path.addLine(to: CGPoint(x: 111, y: 70))
        path.addEllipse(in: CGRect(x: 108.5, y: 70, width: 5, height: 5))
        path.move(to: CGPoint(x: 249, y: 137))
        path.addLine(to: CGPoint(x: 249, y: 156))
        path.addQuadCurve(to: CGPoint(x: 257, y: 164), control: CGPoint(x: 249, y: 164))
        path.addLine(to: CGPoint(x: 280, y: 164))
        path.addEllipse(in: CGRect(x: 246.5, y: 132, width: 5, height: 5))
        return path
    }
}

struct VFStatusPill: View {
    let text: String
    var active = false
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(active ? VFTheme.accent : VFTheme.muted).frame(width: 5, height: 5)
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(active ? VFTheme.accent : VFTheme.muted)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(active ? VFTheme.lilac : VFTheme.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(active ? VFTheme.outline.opacity(0.55) : VFTheme.line, lineWidth: 1))
    }
}

struct VFNotice: View {
    let text: String
    var symbol = "info.circle"
    var warning = false
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(warning ? VFTheme.ink : VFTheme.accent)
                .padding(.top, 1)
            Text(text).font(.system(size: 12)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(warning ? VFTheme.ink : VFTheme.muted)
        .padding(12)
        .background(warning ? VFTheme.peach.opacity(0.62) : VFTheme.lilac.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(warning ? VFTheme.peach : VFTheme.line, lineWidth: 1))
    }
}
