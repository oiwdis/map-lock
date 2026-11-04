import SwiftUI

/// Design tokens ported from the web mockup (DESIGN.md / index.html).
enum Theme {
    // Base and map
    static let background = Color(hex: 0x0A0A0C)
    static let ocean = Color(hex: 0x0B1220)
    static let oceanTop = Color(hex: 0x0F1A2E)
    static let land = Color(hex: 0x283548)
    static let landFar = Color(hex: 0x141B26)
    static let border = Color(hex: 0x0B1220)

    // Text, three levels of white
    static let text = Color(hex: 0xF5F5F7)
    static let text2 = Color(.sRGB, red: 235 / 255, green: 235 / 255, blue: 245 / 255, opacity: 0.62)
    static let text3 = Color(.sRGB, red: 235 / 255, green: 235 / 255, blue: 245 / 255, opacity: 0.38)

    // Apple dark mode system colors
    static let accent = Color(hex: 0x0A84FF)
    static let accent2 = Color(hex: 0x409CFF)
    static let target = Color(hex: 0xFFD60A)
    static let good = Color(hex: 0x30D158)
    static let bad = Color(hex: 0xFF453A)
    static let warn = Color(hex: 0xFF9F0A)
    static let goodBG = Color(hex: 0x30D158, opacity: 0.16)
    static let badBG = Color(hex: 0xFF453A, opacity: 0.16)
    static let warnBG = Color(hex: 0xFF9F0A, opacity: 0.16)

    // Surfaces
    static let glass = Color(.sRGB, red: 28 / 255, green: 28 / 255, blue: 32 / 255, opacity: 0.62)
    static let glassStrong = Color(.sRGB, red: 30 / 255, green: 30 / 255, blue: 36 / 255, opacity: 0.92)
    static let fill = Color.white.opacity(0.06)
    static let fill2 = Color.white.opacity(0.10)
    static let fill3 = Color.white.opacity(0.16)
    static let hairline = Color.white.opacity(0.08)
    static let hairline2 = Color.white.opacity(0.14)

    // Type scale 12/13/15/17/20/28/40
    enum Size {
        static let xs: CGFloat = 12
        static let sm: CGFloat = 13
        static let body: CGFloat = 15
        static let md: CGFloat = 17
        static let lg: CGFloat = 20
        static let xl: CGFloat = 28
        static let xxl: CGFloat = 40
    }

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    // 4pt spacing
    enum Space {
        static let s1: CGFloat = 4
        static let s2: CGFloat = 8
        static let s3: CGFloat = 12
        static let s4: CGFloat = 16
        static let s5: CGFloat = 20
        static let s6: CGFloat = 24
        static let s8: CGFloat = 32
        static let s10: CGFloat = 40
    }

    // Radii 8/12/16/22
    enum Radius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 22
    }

    // Motion 120/200/360 ms, ease out and a light spring
    enum Motion {
        static func ease(_ duration: Double) -> Animation {
            .timingCurve(0.2, 0.8, 0.2, 1, duration: duration)
        }
        static var fast: Animation { ease(0.12) }
        static var medium: Animation { ease(0.2) }
        static var slow: Animation { ease(0.36) }
        static var spring: Animation { .spring(response: 0.36, dampingFraction: 0.62) }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}

// MARK: Backgrounds

/// The dark, softly colored backdrop behind the quiz (like a blurred wallpaper).
struct Backdrop: View {
    var body: some View {
        ZStack {
            Theme.background
            RadialGradient(colors: [Color(hex: 0x1E3A8A, opacity: 0.75), .clear],
                           center: UnitPoint(x: 0.12, y: 0.0), startRadius: 0, endRadius: 900)
            RadialGradient(colors: [Color(hex: 0x4C1D95, opacity: 0.65), .clear],
                           center: UnitPoint(x: 0.85, y: 0.05), startRadius: 0, endRadius: 900)
            RadialGradient(colors: [Color(hex: 0x9D174D, opacity: 0.45), .clear],
                           center: UnitPoint(x: 0.9, y: 1.0), startRadius: 0, endRadius: 800)
            Color(.sRGB, red: 8 / 255, green: 8 / 255, blue: 12 / 255, opacity: 0.55)
        }
        .ignoresSafeArea()
    }
}

/// Glass panel: material, dark tint, 1px hairline border, soft inner highlight.
struct GlassPanel: ViewModifier {
    var radius: CGFloat = Theme.Radius.xl
    var strong = false
    var shadow = true

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .background(
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(strong ? Theme.glassStrong : Theme.glass)
                }
            )
            .overlay(shape.strokeBorder(Theme.hairline2, lineWidth: 1))
            .overlay(
                shape.strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(0.10), .clear], startPoint: .top, endPoint: .center),
                    lineWidth: 0.5
                )
            )
            .shadow(color: Color.black.opacity(shadow ? 0.45 : 0), radius: 28, x: 0, y: 18)
    }
}

extension View {
    func glass(radius: CGFloat = Theme.Radius.xl, strong: Bool = false, shadow: Bool = true) -> some View {
        modifier(GlassPanel(radius: radius, strong: strong, shadow: shadow))
    }
}

// MARK: Buttons

enum ButtonKind {
    case primary, ghost, danger
}

/// The standard button: 40pt tall, radius 12, 15pt semibold.
struct AppButtonStyle: ButtonStyle {
    var kind: ButtonKind = .primary
    var height: CGFloat = 40
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        AppButtonBody(label: configuration.label, isPressed: configuration.isPressed,
                      kind: kind, height: height, fullWidth: fullWidth)
    }
}

private struct AppButtonBody<Label: View>: View {
    let label: Label
    let isPressed: Bool
    let kind: ButtonKind
    let height: CGFloat
    let fullWidth: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        label
            .font(Theme.font(Theme.Size.body, .semibold))
            .foregroundStyle(kind == .ghost ? Theme.text : Color.white)
            .lineLimit(1)
            .padding(.horizontal, Theme.Space.s5)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .fill(fillColor)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            .scaleEffect(isPressed ? 0.98 : 1)
            .opacity(isEnabled ? 1 : 0.5)
            .animation(Theme.Motion.fast, value: isPressed)
            .animation(Theme.Motion.medium, value: hovering)
            .onHover { hovering = $0 }
    }

    private var fillColor: Color {
        switch kind {
        case .primary: return hovering ? Theme.accent2 : Theme.accent
        case .ghost: return hovering ? Theme.fill3 : Theme.fill2
        case .danger: return Theme.bad
        }
    }
}

/// Small quiet text button, like "Emergency skip".
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        QuietButtonBody(label: configuration.label, isPressed: configuration.isPressed)
    }
}

private struct QuietButtonBody<Label: View>: View {
    let label: Label
    let isPressed: Bool
    @State private var hovering = false

    var body: some View {
        label
            .font(Theme.font(Theme.Size.xs, .medium))
            .foregroundStyle(hovering ? Theme.text2 : Theme.text3)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .fill(hovering ? Theme.fill : Color.clear)
            )
            .contentShape(Rectangle())
            .opacity(isPressed ? 0.7 : 1)
            .onHover { hovering = $0 }
    }
}

// MARK: Small parts

/// Rounded pill, 28pt tall.
struct Pill<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 6) { content }
            .font(Theme.font(Theme.Size.sm, .semibold))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, Theme.Space.s3)
            .frame(height: 28)
            .background(Capsule().fill(Theme.fill2))
    }
}

/// Keyboard key badge, like the "1" to "4" on answer buttons.
struct KeyBadge: View {
    let text: String
    var tint: Color? = nil

    var body: some View {
        Text(text)
            .font(Theme.font(Theme.Size.xs, .semibold))
            .foregroundStyle(tint == nil ? Theme.text2 : Color.white)
            .frame(minWidth: 22, minHeight: 22)
            .padding(.horizontal, 2)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint ?? Theme.fill2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(tint == nil ? Theme.hairline2 : Color.clear, lineWidth: 1)
            )
    }
}

/// Section label: small, uppercase, quiet.
struct SectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(Theme.font(Theme.Size.xs, .semibold))
            .kerning(0.7)
            .foregroundStyle(Theme.text3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Feedback motion

/// Red shake. Animate `shakes` up by 1 to shake once.
struct ShakeEffect: GeometryEffect {
    var shakes: CGFloat

    nonisolated var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    nonisolated func effectValue(size: CGSize) -> ProjectionTransform {
        let t = shakes - shakes.rounded(.down)
        let x = 6 * sin(t * .pi * 4) * (1 - t)
        return ProjectionTransform(CGAffineTransform(translationX: x, y: 0))
    }
}

/// Green pulse. Animate `pulses` up by 1 to pulse once.
struct PulseEffect: GeometryEffect {
    var pulses: CGFloat

    nonisolated var animatableData: CGFloat {
        get { pulses }
        set { pulses = newValue }
    }

    nonisolated func effectValue(size: CGSize) -> ProjectionTransform {
        let t = pulses - pulses.rounded(.down)
        let s = 1 + 0.035 * sin(t * .pi)
        let transform = CGAffineTransform(translationX: size.width / 2, y: size.height / 2)
            .scaledBy(x: s, y: s)
            .translatedBy(x: -size.width / 2, y: -size.height / 2)
        return ProjectionTransform(transform)
    }
}

/// Rounded app badge with a globe, used in the home window.
struct AppBadge: View {
    var size: CGFloat = 64

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .fill(LinearGradient(colors: [Color(hex: 0x2A7FFF), Color(hex: 0x5B2BD6)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "globe.europe.africa.fill")
                    .font(.system(size: size * 0.5, weight: .regular))
                    .foregroundStyle(Color.white)
            )
            .shadow(color: Color.black.opacity(0.35), radius: 12, x: 0, y: 8)
    }
}
