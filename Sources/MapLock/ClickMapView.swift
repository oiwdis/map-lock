import SwiftUI

/// The map for a "Click the country" question: the whole region with nothing highlighted.
/// Small countries get a Seterra-style dot. A click picks a country (see ClickMap.swift).
/// After the answer the target turns green, or the clicked country flashes red and the
/// target shows in yellow.
struct ClickMapView: View {
    let world: [Country]
    let target: Country
    let state: TargetState
    /// The country that was clicked, once answered (nil for "I don't know").
    let clicked: String?
    let enabled: Bool
    let onClick: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: String? = nil
    @State private var cache = ClickLayoutCache()
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            let layout = cache.layout(for: target, world: world, size: geo.size)
            // All parts of the hovered country (for example Cyprus and Northern Cyprus).
            let hoverParts: [ClickTarget] = hovered.map { name in layout.targets.filter { $0.name == name } } ?? []
            ZStack {
                ClickBaseMap(world: world, layout: layout, scheme: scheme)
                    .equatable()
                if enabled, !hoverParts.isEmpty {
                    HoverLayer(parts: hoverParts)
                }
                if state != .asking {
                    ClickResultLayer(layout: layout, target: target.name, state: state,
                                     clicked: clicked, animate: !reduceMotion)
                        .id(clicked ?? "-")
                }
            }
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture().onEnded { value in
                    guard enabled, let name = ClickMap.hit(value.location, in: layout.targets) else { return }
                    hovered = nil
                    onClick(name)
                }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    let name = enabled ? ClickMap.hit(point, in: layout.targets) : nil
                    if name != hovered { hovered = name }
                case .ended:
                    if hovered != nil { hovered = nil }
                }
            }
        }
        .onChange(of: target.name) { _, _ in hovered = nil }
    }
}

/// Everything ClickMap works out for one region view at one size.
struct ClickLayout {
    let key: String
    let plan: MapPlan
    let map: FittedMap
    let region: Region
    let targets: [ClickTarget]
}

/// Keeps the layout between redraws (hover changes redraw often). Not observed on purpose.
final class ClickLayoutCache {
    private var last: ClickLayout? = nil

    func layout(for target: Country, world: [Country], size: CGSize) -> ClickLayout {
        // The view is the same for the whole region, so the key is the region and the size.
        let key = "\(target.region.rawValue)|\(Int(size.width))x\(Int(size.height))|\(world.count)"
        if let last, last.key == key { return last }
        let plan = MapViews.regionPlan(for: target, world: world)
        let map = FittedMap(projection: plan.projection, fit: plan.fit, size: size)
        let targets = ClickMap.targets(for: target, world: world, map: map, size: size)
        let made = ClickLayout(key: key, plan: plan, map: map, region: target.region, targets: targets)
        last = made
        return made
    }
}

/// All countries, no highlight, plus the neutral dots. Only redraws when the view changes.
private struct ClickBaseMap: View, Equatable {
    let world: [Country]
    let layout: ClickLayout
    /// Part of the equality so a Light / Dark switch redraws the map.
    let scheme: ColorScheme

    nonisolated static func == (lhs: ClickBaseMap, rhs: ClickBaseMap) -> Bool {
        lhs.layout.key == rhs.layout.key && lhs.scheme == rhs.scheme
    }

    var body: some View {
        let world = self.world
        let layout = self.layout
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(
                Path(rect),
                with: .radialGradient(
                    Gradient(colors: [Theme.oceanTop, Theme.ocean]),
                    center: CGPoint(x: size.width * 0.5, y: size.height * 0.4),
                    startRadius: 0,
                    endRadius: max(size.width, size.height) * 0.7
                )
            )
            let visible = rect.insetBy(dx: -20, dy: -20)
            for country in world where country.region == layout.region {
                let path = MapDrawing.makePath(layout.map.viewPolygons(for: country))
                guard path.boundingRect.intersects(visible) else { continue }
                let fill = Theme.land  // only the region is drawn; everything else is sea
                context.fill(path, with: .color(fill), style: FillStyle(eoFill: true))
                context.stroke(path, with: .color(Theme.border),
                               style: StrokeStyle(lineWidth: 0.6, lineJoin: .round))
            }
            for t in layout.targets {
                guard let dot = t.dot else { continue }
                if t.needsLeader, let anchor = t.anchor {
                    ClickDots.leader(from: anchor, to: dot, in: &context, color: Theme.leader)
                }
                let circle = Path(ellipseIn: ClickDots.rect(at: dot))
                context.fill(circle, with: .color(Theme.dotFill))
                context.stroke(circle, with: .color(Theme.dotStroke), lineWidth: 1.5)
            }
        }
        .allowsHitTesting(false)
    }
}

enum ClickDots {
    static func rect(at center: CGPoint) -> CGRect {
        let r = ClickMap.dotRadius
        return CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
    }

    /// Thin line from a nudged dot back to its country's true center, with a tiny end point.
    static func leader(from anchor: CGPoint, to dot: CGPoint, in context: inout GraphicsContext, color: Color) {
        let dx = dot.x - anchor.x, dy = dot.y - anchor.y
        let d = hypot(dx, dy)
        guard d > 0 else { return }
        // Stop at the dot's edge so the line does not run under it.
        let end = CGPoint(x: dot.x - dx / d * ClickMap.dotRadius, y: dot.y - dy / d * ClickMap.dotRadius)
        var line = Path()
        line.move(to: anchor)
        line.addLine(to: end)
        context.stroke(line, with: .color(color), lineWidth: 1.2)
        context.fill(Path(ellipseIn: CGRect(x: anchor.x - 1.5, y: anchor.y - 1.5, width: 3, height: 3)), with: .color(color))
    }

    static func path(for target: ClickTarget) -> Path {
        var path = MapDrawing.makePath(target.polygons)
        if let dot = target.dot { path.addEllipse(in: rect(at: dot)) }
        return path
    }
}

/// A light wash on the country under the pointer, like Seterra.
private struct HoverLayer: View {
    let parts: [ClickTarget]

    /// Read so a Light / Dark switch redraws this layer right away.
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { context, _ in
            for target in parts {
                let shape = MapDrawing.makePath(target.polygons)
                context.fill(shape, with: .color(Theme.hover), style: FillStyle(eoFill: true))
                if let dot = target.dot {
                    let circle = Path(ellipseIn: ClickDots.rect(at: dot))
                    context.fill(circle, with: .color(Theme.fill3))
                    context.stroke(circle, with: .color(Theme.text), lineWidth: 1.5)
                }
            }
        }
        .id(scheme)
        .allowsHitTesting(false)
    }
}

/// After the click: green target when right. When wrong, the clicked country flashes red
/// and the target shows in yellow with a ring if it is tiny.
private struct ClickResultLayer: View {
    let layout: ClickLayout
    let target: String
    let state: TargetState
    let clicked: String?
    let animate: Bool
    @State private var start = Date()

    /// The red flash: three blinks over 0.9 seconds, then it stays red.
    static let flashLength = 0.9

    /// Read so a Light / Dark switch redraws this layer right away.
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // Reading the scheme makes SwiftUI redraw on a theme switch without restarting the flash.
        let _ = scheme
        // Every part of the country, not just the first (Cyprus has two, China has specks).
        let targetShapes = layout.targets.filter { $0.name == target }
        let wrongShapes = state == .wrong ? layout.targets.filter { $0.name == clicked && $0.name != target } : []
        let flashing = animate && !wrongShapes.isEmpty
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !flashing)) { timeline in
            let t = timeline.date.timeIntervalSince(start)
            let redOpacity: Double = {
                guard flashing, t < Self.flashLength else { return 0.9 }
                return 0.25 + 0.75 * (1 + cos(t / Self.flashLength * 3 * 2 * .pi)) / 2
            }()
            // Right: green target. Wrong: the answer shows in yellow (like while asking).
            let look: TargetState = state == .right ? .right : .asking
            let targetColor = look.color
            let ringColor = state == .right ? Theme.ringGood : Theme.ringTiny

            Canvas { context, _ in
                for wrong in wrongShapes {
                    if wrong.needsLeader, let a = wrong.anchor, let d = wrong.dot {
                        ClickDots.leader(from: a, to: d, in: &context, color: Theme.ringBad)
                    }
                    let path = ClickDots.path(for: wrong)
                    context.fill(path, with: .color(Theme.mapBad.opacity(redOpacity)), style: FillStyle(eoFill: true))
                    context.stroke(path, with: .color(Theme.mapBadOutline), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
                }
                for shape in targetShapes {
                    if shape.needsLeader, let a = shape.anchor, let d = shape.dot {
                        ClickDots.leader(from: a, to: d, in: &context, color: ringColor)
                    }
                    let path = ClickDots.path(for: shape)
                    context.fill(path, with: .color(targetColor), style: FillStyle(eoFill: true))
                    context.stroke(path, with: .color(look.outline), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
                }
                // Small targets (like Sri Lanka) get a ring after any answer, so they are easy to find.
                if let ring = MapDrawing.markerRing(for: targetShapes.flatMap { $0.polygons }) {
                    context.stroke(Path(ellipseIn: ring), with: .color(ringColor),
                                   style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [5, 4]))
                }
            }
            .shadow(color: targetColor.opacity(0.7), radius: 12)
        }
        .allowsHitTesting(false)
        .onAppear { start = Date() }
    }
}
