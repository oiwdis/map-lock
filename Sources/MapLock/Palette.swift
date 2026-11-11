import Foundation

/// One color as sRGB 0...1 plus opacity.
struct RGBA: Sendable, Equatable {
    let r: Double, g: Double, b: Double, a: Double

    init(_ hex: UInt32, _ a: Double = 1) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
        self.a = a
    }

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    /// This color painted over an opaque one.
    func over(_ base: RGBA) -> RGBA {
        RGBA(r: r * a + base.r * (1 - a), g: g * a + base.g * (1 - a), b: b * a + base.b * (1 - a))
    }

    /// WCAG relative luminance (ignores opacity, so paint it over something first).
    var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// WCAG contrast ratio between two opaque colors.
    static func contrast(_ x: RGBA, _ y: RGBA) -> Double {
        let a = x.luminance, b = y.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

/// A light and a dark value.
struct Shade: Sendable {
    let light: RGBA
    let dark: RGBA

    init(_ light: RGBA, _ dark: RGBA) { self.light = light; self.dark = dark }
    init(_ light: UInt32, _ dark: UInt32) { self.light = RGBA(light); self.dark = RGBA(dark) }

    func value(dark isDark: Bool) -> RGBA { isDark ? dark : light }
}

/// Every color the app uses, with no UI framework, so the Linux tests can check contrast.
/// A quiet atlas palette. Theme.swift turns these into adaptive SwiftUI colors.
enum Palette {
    static let white = 0xFFFFFF as UInt32

    // Page and surfaces
    static let page = Shade(0xF3F6F5, 0x101918)
    /// Results and skip dialogs: solid enough that the text never depends on what is behind.
    static let dialog = Shade(white, 0x1A2624)
    /// Settings cards and the answer buttons.
    static let card = Shade(white, 0x1A2624)
    static let scrim = Shade(RGBA(0x000000, 0.22), RGBA(0x000000, 0.45))

    /// Soft glows behind the quiz and home window (Theme.Backdrop). Kept pale enough
    /// that colored text on them still passes 4.5:1. Dark adds a veil on top.
    static let lightGlows = [RGBA(0xD6E8E1, 0.18), RGBA(0xE1EDE8, 0.16), RGBA(0xE8EFEC, 0.12)]
    static let darkGlows = [RGBA(0x24483D, 0.12), RGBA(0x203D38, 0.10), RGBA(0x203D38, 0.08)]
    static let darkVeil = RGBA(0x08080C, 0.55)

    // Text
    static let text = Shade(0x182D29, 0xEDF5F1)
    static let text2 = Shade(0x475D56, 0xB5C8BF)
    static let text3 = Shade(0x596D65, 0x9EB4AA)
    static let goodText = Shade(0x17702F, 0x30D158)
    static let badText = Shade(0xC62828, 0xFF6961)
    static let warnText = Shade(0xB02E00, 0xFF9F0A)

    // Buttons: white text on these fills.
    static let accentFill = Shade(0x176B52, 0x23765D)
    static let accentFillHover = Shade(0x11563F, 0x277A61)
    static let dangerFill = Shade(0xC62828, 0xC4262B)
    /// Text on a green or red key badge (the badge uses goodText / badText as its fill).
    static let onTint = Shade(0xFFFFFF, 0x0A0A0C)
    /// Accent for icons and focus rings.
    static let accent = Shade(0x176B52, 0x79D6B2)

    // Map
    static let sea = Shade(0xDCEBE7, 0x101E24)
    static let land = Shade(0x477761, 0x5B7C6A)
    static let border = Shade(RGBA(white, 0.85), RGBA(white, 0.60))
    static let highlight = Shade(0xFFD60A, 0xFFD60A)
    static let highlightOutline = Shade(0x7A5A00, 0xFFD60A)
    static let ringTiny = Shade(0xC2410C, 0xFFD60A)
    static let correctFill = Shade(0xA8F046, 0x30D158)
    static let correctOutline = Shade(0x14532D, 0x30D158)
    static let correctRing = goodText
    static let wrongFill = Shade(0xE5383B, 0xFF453A)
    static let wrongRing = badText
    /// Light line around the clicked wrong country, so the red reads against green land.
    static let wrongOutline = Shade(RGBA(white, 1), RGBA(white, 0.9))
    static let dotFill = land
    static let dotStroke = Shade(RGBA(white, 1), RGBA(white, 0.80))
    static let leader = Shade(RGBA(0x003246, 0.60), RGBA(white, 0.60))
    /// Frame around the map card.
    static let mapFrame = Shade(RGBA(0x003246, 0.35), RGBA(white, 0.28))
}
