import AppKit
import SwiftUI

enum VFTheme {
    static let ink = Color(red: 45 / 255, green: 53 / 255, blue: 89 / 255)
    static let muted = Color(red: 104 / 255, green: 110 / 255, blue: 134 / 255)
    static let accent = Color(red: 86 / 255, green: 106 / 255, blue: 187 / 255)
    static let canvas = Color(red: 255 / 255, green: 249 / 255, blue: 242 / 255)
    static let surface = Color(red: 255 / 255, green: 254 / 255, blue: 250 / 255)
    static let line = Color(red: 220 / 255, green: 221 / 255, blue: 237 / 255)
    static let sky = Color(red: 187 / 255, green: 223 / 255, blue: 247 / 255)
    static let lilac = Color(red: 240 / 255, green: 237 / 255, blue: 250 / 255)
    static let peach = Color(red: 247 / 255, green: 221 / 255, blue: 209 / 255)
    static let outline = Color(red: 136 / 255, green: 148 / 255, blue: 197 / 255)
    static let lime = sky
    static let warning = Color(red: 196 / 255, green: 120 / 255, blue: 64 / 255)
}

/// A fish in motion, with a pause symbol cut into its body.
struct VFFishMark: View {
    var body: some View {
        VFFishShape().fill(style: FillStyle(eoFill: true))
            .aspectRatio(1, contentMode: .fit)
            .accessibilityHidden(true)
    }
}

struct VFLogo: View {
    var size: CGFloat = 40

    private static let image: NSImage? = {
        let bundled = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
        let preview = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Assets/AppIcon.icns")
        return [bundled, preview].compactMap { $0 }.compactMap { NSImage(contentsOf: $0) }.first
    }()

    var body: some View {
        Group {
            if let image = Self.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                VFFishMark()
                    .foregroundStyle(VFTheme.lime)
                    .padding(size * 0.10)
                    .background(VFTheme.ink, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct VFPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(isEnabled ? Color.white : VFTheme.muted)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isEnabled ? VFTheme.accent : VFTheme.line)
                    .shadow(color: isEnabled ? VFTheme.ink.opacity(0.80) : .clear,
                            radius: 0, x: 0, y: configuration.isPressed ? 0 : 2)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isEnabled ? VFTheme.ink.opacity(0.9) : VFTheme.line, lineWidth: 1.3)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .offset(y: configuration.isPressed ? 2 : 0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct VFSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isEnabled ? VFTheme.ink : VFTheme.muted)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(configuration.isPressed ? VFTheme.lilac : VFTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isEnabled ? VFTheme.outline.opacity(0.65) : VFTheme.line, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct VFCardSurface: ViewModifier {
    var cornerRadius: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .background(VFTheme.surface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(VFTheme.line, lineWidth: 1)
            }
            .shadow(color: VFTheme.ink.opacity(0.045), radius: 0, x: 0, y: 2)
    }
}

extension View {
    func vfCardSurface(cornerRadius: CGFloat = 18) -> some View {
        modifier(VFCardSurface(cornerRadius: cornerRadius))
    }
}

/// Compact secondary action used in dense surfaces (status bar, rows).
struct VFChipButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(isEnabled ? VFTheme.ink : VFTheme.muted.opacity(0.6))
            .padding(.horizontal, 8).frame(height: 20)
            .background(configuration.isPressed ? VFTheme.lilac : VFTheme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(VFTheme.line, lineWidth: 1))
            .contentShape(Capsule())
    }
}

/// Text-only action for low-emphasis commands (cancel, disconnect).
struct VFQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(configuration.isPressed ? VFTheme.ink : VFTheme.muted)
            .contentShape(Rectangle())
    }
}

/// Small bordered action inside cards and settings rows.
struct VFSmallButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isEnabled ? VFTheme.ink : VFTheme.muted.opacity(0.6))
            .padding(.horizontal, 11).frame(minHeight: 26)
            .background(configuration.isPressed ? VFTheme.lilac : VFTheme.surface,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(VFTheme.outline.opacity(0.45), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct VFSymbolTile: View {
    let symbol: String
    var size: CGFloat = 52

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.37, weight: .medium))
            .foregroundStyle(VFTheme.accent)
            .frame(width: size, height: size)
            .background(VFTheme.lilac, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .strokeBorder(VFTheme.outline.opacity(0.65), lineWidth: 1.2)
            }
            .shadow(color: VFTheme.ink.opacity(0.06), radius: 0, x: 0, y: 2)
            .accessibilityHidden(true)
    }
}

private struct VFFishShape: Shape {
    func path(in rect: CGRect) -> Path {
        var transform = CGAffineTransform(translationX: rect.minX, y: rect.minY)
            .scaledBy(x: rect.width, y: rect.height)
        return Path(VFBrandAssets.fishPath.copy(using: &transform)!)
    }
}

enum VFBrandAssets {
    static func menuBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            context.translateBy(x: 0, y: -1)
            context.scaleBy(x: rect.width, y: 20)
            context.addPath(fishPath)
            context.setFillColor(NSColor.black.cgColor)
            context.drawPath(using: .eoFill)
            context.restoreGState()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Vibe Fishing"
        return image
    }

    fileprivate static var fishPath: CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0.08, y: 0.33))
        path.addQuadCurve(to: CGPoint(x: 0.12, y: 0.30), control: CGPoint(x: 0.06, y: 0.27))
        path.addLine(to: CGPoint(x: 0.32, y: 0.43))
        path.addCurve(to: CGPoint(x: 0.91, y: 0.50), control1: CGPoint(x: 0.47, y: 0.22), control2: CGPoint(x: 0.74, y: 0.23))
        path.addCurve(to: CGPoint(x: 0.32, y: 0.57), control1: CGPoint(x: 0.74, y: 0.77), control2: CGPoint(x: 0.47, y: 0.78))
        path.addLine(to: CGPoint(x: 0.12, y: 0.70))
        path.addQuadCurve(to: CGPoint(x: 0.08, y: 0.67), control: CGPoint(x: 0.06, y: 0.73))
        path.addLine(to: CGPoint(x: 0.16, y: 0.50))
        path.closeSubpath()
        path.addRoundedRect(in: CGRect(x: 0.49, y: 0.405, width: 0.055, height: 0.19), cornerWidth: 0.020, cornerHeight: 0.020)
        path.addRoundedRect(in: CGRect(x: 0.605, y: 0.405, width: 0.055, height: 0.19), cornerWidth: 0.020, cornerHeight: 0.020)
        return path
    }
}
