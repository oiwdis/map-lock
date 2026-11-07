import SwiftUI
import AppKit

/// Design tokens ported from the web mockup (DESIGN.md / index.html).
/// Every color has a light and a dark value and follows the window's appearance
/// (set from the Appearance setting through NSApp.appearance).
/// Light is Seterra-like: green land on a light blue sea, light panels, dark text.
enum Theme {
    // All values live in Palette.swift (shared with the Linux contrast test) and match
    // the web demo. Every color follows the window's appearance, so a Light / Dark /
    // Match system switch takes effect at once in every window.

    // Base and map
    static let background = dyn(Palette.page)
    static let ocean = dyn(Palette.sea)
    /// Flat sea (the web uses one sea color; a gradient made the light sea uneven).
    static let oceanTop = dyn(Palette.sea)
    static let land = dyn(Palette.land)
    static let border = dyn(Palette.border)

    // Map highlights
    static let mapGood = dyn(Palette.correctFill)
    static let mapGoodOutline = dyn(Palette.correctOutline)
    static let mapBad = dyn(Palette.wrongFill)
    static let mapBadOutline = dyn(Palette.wrongOutline)
    /// The answer reveal / the asked country while asking.
    static let mapTarget = dyn(Palette.highlight)
    static let mapTargetOutline = dyn(Palette.highlightOutline)
    /// Ring around a tiny target, per state.
    static let ringTiny = dyn(Palette.ringTiny)
    static let ringGood = dyn(Palette.correctRing)
    static let ringBad = dyn(Palette.wrongRing)
    /// Seterra-style dots for tiny countries.
    static let dotFill = dyn(Palette.dotFill)
    static let dotStroke = dyn(Palette.dotStroke)
    static let leader = dyn(Palette.leader)
    static let mapFrame = dyn(Palette.mapFrame)
    /// Hover wash over a country.
    static let hover = dyn(0xFFFFFF, 0xFFFFFF, lightOpacity: 0.28, darkOpacity: 0.16)

    // Text, three levels, plus result colors for text
    static let text = dyn(Palette.text)
    static let text2 = dyn(Palette.text2)
    static let text3 = dyn(Palette.text3)
    static let good = dyn(Palette.goodText)
    static let bad = dyn(Palette.badText)
    static let warn = dyn(Palette.warnText)
    /// Text on a green or red badge.
    static let onTint = dyn(Palette.onTint)

    // Accent and button fills (white text on them passes 4.5:1)
    static let accent = dyn(Palette.accent)
    static let accentFill = dyn(Palette.accentFill)
    static let accentFillHover = dyn(Palette.accentFillHover)
    static let dangerFill = dyn(Palette.dangerFill)
    static let goodBG = dyn(0x34C759, 0x30D158, lightOpacity: 0.16, darkOpacity: 0.16)
    static let badBG = dyn(0xFF3B30, 0xFF453A, lightOpacity: 0.14, darkOpacity: 0.16)
    static let warnBG = dyn(0xFF9500, 0xFF9F0A, lightOpacity: 0.16, darkOpacity: 0.16)

    // Surfaces
    static let glass = dyn(Palette.card)
    /// Solid-ish card fill for tiles and selectable place cards.
    static let card = dyn(Palette.card)
    /// Results and skip dialogs.
    static let dialog = dyn(Palette.dialog)
    static let fill = dyn(0x000000, 0xFFFFFF, lightOpacity: 0.04, darkOpacity: 0.06)
    static let fill2 = dyn(0x000000, 0xFFFFFF, lightOpacity: 0.07, darkOpacity: 0.10)
    static let fill3 = dyn(0x000000, 0xFFFFFF, lightOpacity: 0.11, darkOpacity: 0.16)
    static let hairline = dyn(0x000000, 0xFFFFFF, lightOpacity: 0.08, darkOpacity: 0.08)
    static let hairline2 = dyn(0x000000, 0xFFFFFF, lightOpacity: 0.12, darkOpacity: 0.14)
    static let highlight = dyn(0xFFFFFF, 0xFFFFFF, lightOpacity: 0.6, darkOpacity: 0.10)
    static let shadow = dyn(0x000000, 0x000000, lightOpacity: 0.14, darkOpacity: 0.45)
    static let scrim = dyn(Palette.scrim)
    /// Window background behind the SwiftUI content (home window, overlay).
    static var windowBackground: NSColor { dynNS(Palette.page) }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static func dynNS(_ light: UInt32, _ dark: UInt32, lightOpacity: Double = 1, darkOpacity: Double = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            isDark(appearance) ? NSColor(hex: dark, alpha: darkOpacity) : NSColor(hex: light, alpha: lightOpacity)
        }
    }

    static func nsColor(_ c: RGBA) -> NSColor {
        NSColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: CGFloat(c.a))
    }

    static func dynNS(_ shade: Shade) -> NSColor {
        NSColor(name: nil) { appearance in nsColor(shade.value(dark: isDark(appearance))) }
    }

    static func dyn(_ shade: Shade) -> Color { Color(nsColor: dynNS(shade)) }

    static func dyn(_ light: UInt32, _ dark: UInt32, lightOpacity: Double = 1, darkOpacity: Double = 1) -> Color {
        Color(nsColor: dynNS(light, dark, lightOpacity: lightOpacity, darkOpacity: darkOpacity))
    }

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

extension NSColor {
    convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: CGFloat(alpha))
    }
}

extension AppearanceMode {
    /// The SwiftUI scheme to force, or nil to follow macOS.
    var colorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }

    /// Sets the look for every Map Lock window.
    @MainActor func apply() {
        switch self {
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .system: NSApp.appearance = nil
        }
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

/// The softly colored backdrop behind the quiz (like a blurred wallpaper).
/// Dark: deep blue and purple glows. Light: pale sky and mint glows.
struct Backdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Theme.background
            let glows = scheme == .dark ? Palette.darkGlows : Palette.lightGlows
            let spots: [(UnitPoint, CGFloat)] = [(UnitPoint(x: 0.12, y: 0.0), 900),
                                                 (UnitPoint(x: 0.85, y: 0.05), 900),
                                                 (UnitPoint(x: 0.9, y: 1.0), 800)]
            ForEach(0..<3, id: \.self) { i in
                RadialGradient(colors: [Color(nsColor: Theme.nsColor(glows[i])), .clear],
                               center: spots[i].0, startRadius: 0, endRadius: spots[i].1)
            }
            if scheme == .dark {
                Color(nsColor: Theme.nsColor(Palette.darkVeil))
            }
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
                    // Dialogs use a near-solid themed fill, not a material, so they always
                    // match Light / Dark and their text never sits on a dark blur in Light.
                    if !strong { shape.fill(.ultraThinMaterial) }
                    shape.fill(strong ? Theme.dialog : Theme.glass)
                }
            )
            .overlay(shape.strokeBorder(Theme.hairline2, lineWidth: 1))
            .overlay(
                shape.strokeBorder(
                    LinearGradient(colors: [Theme.highlight, .clear], startPoint: .top, endPoint: .center),
                    lineWidth: 0.5
                )
            )
            .shadow(color: shadow ? Theme.shadow : .clear, radius: 28, x: 0, y: 18)
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
struct AppButtonStyle: PrimitiveButtonStyle {
    var kind: ButtonKind = .primary
    var height: CGFloat = 40
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        AppButtonBody(label: configuration.label, kind: kind, height: height, fullWidth: fullWidth) {
            configuration.trigger()
        }
    }
}

private struct AppButtonBody<Label: View>: View {
    let label: Label
    let kind: ButtonKind
    let height: CGFloat
    let fullWidth: Bool
    let trigger: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        label
            .font(Theme.font(Theme.Size.body, .semibold))
            .foregroundStyle(kind == .ghost ? Theme.text : Color.white)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, Theme.Space.s5)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .fill(fillColor)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            .opacity(isEnabled ? 1 : 0.5)
            .animation(Theme.Motion.medium, value: hovering)
            .overlay(HitTarget(enabled: isEnabled, action: trigger, hover: { hovering = $0 }))
    }

    private var fillColor: Color {
        switch kind {
        case .primary: return hovering ? Theme.accentFillHover : Theme.accentFill
        case .ghost: return hovering ? Theme.fill3 : Theme.fill2
        case .danger: return Theme.dangerFill
        }
    }
}

/// Small quiet text button, like "Emergency skip".
struct QuietButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        QuietButtonBody(label: configuration.label) {
            configuration.trigger()
        }
    }
}

private struct QuietButtonBody<Label: View>: View {
    let label: Label
    let trigger: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        label
            .font(Theme.font(Theme.Size.xs, .medium))
            .foregroundStyle(hovering ? Theme.text2 : Theme.text3)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minHeight: 28)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.5)
            .overlay(HitTarget(enabled: isEnabled, action: trigger, hover: { hovering = $0 }))
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
            .foregroundStyle(tint == nil ? Theme.text2 : Theme.onTint)
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
