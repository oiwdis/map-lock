// Contrast check for every color pair in Palette.swift (WCAG ratios).
// Run ./check-contrast.sh from the project folder. Text needs 4.5:1, map shapes 3:1.
import Foundation

nonisolated(unsafe) var allFails: [String] = []
func check(_ name: String, _ fg: RGBA, _ bg: RGBA, min: Double, info: Bool = false) {
    let c = RGBA.contrast(fg.over(bg), bg)
    let ok = c + 1e-9 >= min
    print(String(format: "%@ %-44@ %5.2f (need %.1f)", ok ? "ok  " : (info ? "info" : "FAIL"), name as NSString, c, min))
    if !ok && !info { allFails.append(name) }
}

for dark in [false, true] {
    let m = dark ? "dark " : "light"
    func v(_ s: Shade) -> RGBA { s.value(dark: dark) }
    let page = v(Palette.page)
    // Backdrop glows (Theme.Backdrop), worst spots.
    let glows: [RGBA] = dark
        ? Palette.darkGlows.map { Palette.darkVeil.over($0.over(page)) }
        : Palette.lightGlows.map { $0.over(page) }
    var backs: [(String, RGBA)] = [("page", page)]
    for (i, g) in glows.enumerated() { backs.append(("glow\(i)", g)) }
    for (n, b) in backs where n != "page" || true { backs.append(("card/\(n)", v(Palette.card).over(b))) }
    let dialogBacks = backs.map { ("dialog/\($0.0)", v(Palette.dialog).over(v(Palette.scrim).over($0.1))) }
    let sea = v(Palette.sea), land = v(Palette.land)

    for (n, b) in backs + dialogBacks {
        check("\(m) text on \(n)", v(Palette.text), b, min: 4.5)
        check("\(m) accent text on \(n)", v(Palette.accent), b, min: 4.5)
        check("\(m) text2 on \(n)", v(Palette.text2), b, min: 4.5)
        check("\(m) text3 on \(n)", v(Palette.text3), b, min: 4.5)
        check("\(m) correct text on \(n)", v(Palette.goodText), b, min: 4.5)
        check("\(m) wrong text on \(n)", v(Palette.badText), b, min: 4.5)
        check("\(m) warn text on \(n)", v(Palette.warnText), b, min: 4.5)
    }
    // Map label pill sits on the sea.
    check("\(m) text on sea", v(Palette.text), sea, min: 4.5)
    // Buttons and badges
    let white = RGBA(0xFFFFFF)
    check("\(m) white on primary button", white, v(Palette.accentFill), min: 4.5)
    check("\(m) white on primary hover", white, v(Palette.accentFillHover), min: 4.5)
    check("\(m) white on danger button", white, v(Palette.dangerFill), min: 4.5)
    check("\(m) badge text on correct", v(Palette.onTint), v(Palette.goodText), min: 4.5)
    check("\(m) badge text on wrong", v(Palette.onTint), v(Palette.badText), min: 4.5)
    // Map (non-text: 3:1)
    check("\(m) land vs sea", land, sea, min: 3)
    check("\(m) tiny ring vs sea", v(Palette.ringTiny), sea, min: 3)
    check("\(m) correct ring vs sea", v(Palette.correctRing), sea, min: 3)
    check("\(m) wrong ring vs sea", v(Palette.wrongRing), sea, min: 3, info: true)
    check("\(m) highlight vs land", v(Palette.highlight), land, min: 3)
    check("\(m) highlight outline vs sea", v(Palette.highlightOutline), sea, min: 3)
    check("\(m) correct fill vs land", v(Palette.correctFill), land, min: 3, info: dark)  // dark: web color, has outline
    check("\(m) correct outline vs sea", v(Palette.correctOutline), sea, min: 3)
    check("\(m) wrong fill vs land", v(Palette.wrongFill), land, min: 3, info: true)
    check("\(m) wrong outline vs wrong fill", v(Palette.wrongOutline), v(Palette.wrongFill), min: 3)
    check("\(m) wrong outline vs land", v(Palette.wrongOutline), land, min: 3)
    check("\(m) dot fill vs sea", v(Palette.dotFill), sea, min: 3)
    check("\(m) dot outline vs dot", v(Palette.dotStroke), v(Palette.dotFill), min: 3)
    check("\(m) leader vs sea", v(Palette.leader), sea, min: 3)
    check("\(m) map frame vs page", v(Palette.mapFrame), page, min: 1.5, info: true)
    check("\(m) border vs land", v(Palette.border), land, min: 3, info: true)
}
let fails = allFails
print(fails.isEmpty ? "contrast: all pass" : "contrast FAILS: \(fails)")
exit(fails.isEmpty ? 0 : 1)
