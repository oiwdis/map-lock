import SwiftUI

/// The map for a "Click the country" question: the whole region with nothing highlighted.
/// Small countries get a Seterra-style dot. A click picks a country (see ClickMap.swift).
/// Pinch / scroll zoom and drag pan; hits stay correct at any zoom.
struct ClickMapView: View {
    let world: [Country]
    let target: Country
    let state: TargetState
    /// The country that was clicked, once answered (nil for "I don't know").
    let clicked: String?
    let enabled: Bool
    /// Whole-world practice uses the flat world map; nil keeps the region view.
    var mapScope: PracticeScope? = nil
    let onClick: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: String? = nil
    @State private var cache = ClickLayoutCache()
    @State private var zoom = MapZoomState()
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            let layout = cache.layout(for: target, world: world, size: geo.size, scope: mapScope)
            let hoverParts: [ClickTarget] = hovered.map { name in layout.targets.filter { $0.name == name } } ?? []
            ZStack {
                ClickBaseMap(world: world, layout: layout, scheme: scheme, zoom: zoom)
                    .equatable()
                if enabled, !hoverParts.isEmpty {
                    HoverLayer(parts: hoverParts, zoom: zoom, size: geo.size)
                }
                if state != .asking {
                    ClickResultLayer(layout: layout, target: target.name, state: state,
                                     clicked: clicked, animate: !reduceMotion, zoom: zoom, size: geo.size)
                        .id(clicked ?? "-")
                }

                MapInteractionOverlay(
                    size: geo.size,
                    zoom: zoom,
                    clicksEnabled: enabled,
                    onZoomChange: { zoom = $0 },
                    onClick: { viewPoint in
                        let mapPt = zoom.mapPoint(from: viewPoint, in: geo.size)
                        guard let name = ClickMap.hit(mapPt, in: layout.targets) else { return }
                        hovered = nil
                        onClick(name)
                    },
                    onHover: { viewPoint in
                        guard let viewPoint else {
                            if hovered != nil { hovered = nil }
                            return
                        }
                        let mapPt = zoom.mapPoint(from: viewPoint, in: geo.size)
                        let name = ClickMap.hit(mapPt, in: layout.targets)
                        if name != hovered { hovered = name }
                    }
                )

                VStack {
                    HStack {
                        Spacer()
                        MapZoomControls(zoom: $zoom, size: geo.size)
                    }
                    Spacer()
                }
                .padding(10)
                .allowsHitTesting(true)
            }
            .clipShape(Rectangle())
            .contentShape(Rectangle())
        }
        .onChange(of: target.name) { _, _ in
            hovered = nil
            zoom.reset()
        }
        .onChange(of: mapScope) { _, _ in
            zoom.reset()
        }
    }
}

/// Everything ClickMap works out for one region view at one size.
struct ClickLayout {
    let key: String
    let plan: MapPlan
    let map: FittedMap
    let region: Region
    let targets: [ClickTarget]
    /// Whole-world practice draws every region, not only the target's.
    var drawsAllRegions: Bool = false
}

/// Keeps the layout between redraws (hover changes redraw often). Not observed on purpose.
final class ClickLayoutCache {
    private var last: ClickLayout? = nil

    func layout(for target: Country, world: [Country], size: CGSize,
                scope: PracticeScope? = nil) -> ClickLayout {
        let scopeKey: String = {
            switch scope {
            case .none: return target.region.rawValue
            case .some(.world): return "world"
            case .some(.region(let r)): return r.rawValue
            }
        }()
        let key = "\(scopeKey)|\(Int(size.width))x\(Int(size.height))|\(world.count)"
        if let last, last.key == key { return last }
        let plan: MapPlan
        if let scope {
            plan = MapViews.scopePlan(scope, target: target, world: world)
        } else {
            plan = MapViews.regionPlan(for: target, world: world)
        }
        let map = FittedMap(projection: plan.projection, fit: plan.fit, size: size)
        let targets = ClickMap.targets(for: target, world: world, map: map, size: size, scope: scope)
        let worldScope: Bool = { if case .some(.world) = scope { return true }; return false }()
        let layoutRegion: Region = {
            if case .some(.region(let r)) = scope { return r }
            return target.region
        }()
        let made = ClickLayout(key: key, plan: plan, map: map, region: layoutRegion,
                               targets: targets, drawsAllRegions: worldScope)
        last = made
        return made
    }
}

/// All countries, no highlight, plus the neutral dots. Only redraws when the view or zoom changes.
private struct ClickBaseMap: View, Equatable {
    let world: [Country]
    let layout: ClickLayout
    let scheme: ColorScheme
    let zoom: MapZoomState

    nonisolated static func == (lhs: ClickBaseMap, rhs: ClickBaseMap) -> Bool {
        lhs.layout.key == rhs.layout.key && lhs.scheme == rhs.scheme && lhs.zoom == rhs.zoom
    }

    var body: some View {
        let world = self.world
        let layout = self.layout
        let zoom = self.zoom
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
            var mapContext = context
            mapContext.beginMapZoom(zoom, size: size)
            let inv = max(zoom.scale, 0.001)
            let visible = rect.insetBy(dx: -40 / inv, dy: -40 / inv)
            for country in world where layout.drawsAllRegions || country.region == layout.region {
                let path = MapDrawing.makePath(layout.map.viewPolygons(for: country))
                guard path.boundingRect.intersects(visible) else { continue }
                mapContext.fill(path, with: .color(Theme.land), style: FillStyle(eoFill: true))
                mapContext.stroke(path, with: .color(Theme.border),
                                  style: StrokeStyle(lineWidth: 0.6 / inv, lineJoin: .round))
            }
            // Dots: constant on-screen size => radius / zoom in map space.
            for t in layout.targets {
                guard let dot = t.dot else { continue }
                if t.needsLeader, let anchor = t.anchor {
                    ClickDots.leader(from: anchor, to: dot, in: &mapContext, color: Theme.leader,
                                     scale: inv)
                }
                let r = ClickMap.dotRadius / inv
                let circle = Path(ellipseIn: CGRect(x: dot.x - r, y: dot.y - r, width: r * 2, height: r * 2))
                mapContext.fill(circle, with: .color(Theme.dotFill))
                mapContext.stroke(circle, with: .color(Theme.dotStroke), lineWidth: 1.5 / inv)
            }
        }
        .allowsHitTesting(false)
    }
}

enum ClickDots {
    static func rect(at center: CGPoint, scale: CGFloat = 1) -> CGRect {
        let r = ClickMap.dotRadius / max(scale, 0.001)
        return CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
    }

    static func leader(from anchor: CGPoint, to dot: CGPoint, in context: inout GraphicsContext,
                       color: Color, scale: CGFloat = 1) {
        let inv = max(scale, 0.001)
        let dx = dot.x - anchor.x, dy = dot.y - anchor.y
        let d = hypot(dx, dy)
        guard d > 0 else { return }
        let end = CGPoint(x: dot.x - dx / d * ClickMap.dotRadius / inv,
                          y: dot.y - dy / d * ClickMap.dotRadius / inv)
        var line = Path()
        line.move(to: anchor)
        line.addLine(to: end)
        context.stroke(line, with: .color(color), lineWidth: 1.2 / inv)
        let ar = 1.5 / inv
        context.fill(Path(ellipseIn: CGRect(x: anchor.x - ar, y: anchor.y - ar, width: ar * 2, height: ar * 2)),
                     with: .color(color))
    }

    static func path(for target: ClickTarget, scale: CGFloat = 1) -> Path {
        var path = MapDrawing.makePath(target.polygons)
        if let dot = target.dot { path.addEllipse(in: rect(at: dot, scale: scale)) }
        return path
    }
}

private struct HoverLayer: View {
    let parts: [ClickTarget]
    let zoom: MapZoomState
    let size: CGSize
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { context, size in
            var ctx = context
            ctx.beginMapZoom(zoom, size: size)
            let inv = max(zoom.scale, 0.001)
            for target in parts {
                let shape = MapDrawing.makePath(target.polygons)
                ctx.fill(shape, with: .color(Theme.hover), style: FillStyle(eoFill: true))
                if let dot = target.dot {
                    let circle = Path(ellipseIn: ClickDots.rect(at: dot, scale: inv))
                    ctx.fill(circle, with: .color(Theme.fill3))
                    ctx.stroke(circle, with: .color(Theme.text), lineWidth: 1.5 / inv)
                }
            }
        }
        .id(scheme)
        .allowsHitTesting(false)
    }
}

private struct ClickResultLayer: View {
    let layout: ClickLayout
    let target: String
    let state: TargetState
    let clicked: String?
    let animate: Bool
    let zoom: MapZoomState
    let size: CGSize
    @State private var start = Date()

    static let flashLength = 0.9
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let _ = scheme
        let targetShapes = layout.targets.filter { $0.name == target }
        let wrongShapes = state == .wrong ? layout.targets.filter { $0.name == clicked && $0.name != target } : []
        let flashing = animate && !wrongShapes.isEmpty
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !flashing)) { timeline in
            let t = timeline.date.timeIntervalSince(start)
            let redOpacity: Double = {
                guard flashing, t < Self.flashLength else { return 0.9 }
                return 0.25 + 0.75 * (1 + cos(t / Self.flashLength * 3 * 2 * .pi)) / 2
            }()
            let look: TargetState = state == .right ? .right : .asking
            let targetColor = look.color
            let ringColor = state == .right ? Theme.ringGood : Theme.ringTiny
            let inv = max(zoom.scale, 0.001)

            Canvas { context, size in
                var ctx = context
                ctx.beginMapZoom(zoom, size: size)
                for wrong in wrongShapes {
                    if wrong.needsLeader, let a = wrong.anchor, let d = wrong.dot {
                        ClickDots.leader(from: a, to: d, in: &ctx, color: Theme.ringBad, scale: inv)
                    }
                    let path = ClickDots.path(for: wrong, scale: inv)
                    ctx.fill(path, with: .color(Theme.mapBad.opacity(redOpacity)), style: FillStyle(eoFill: true))
                    ctx.stroke(path, with: .color(Theme.mapBadOutline),
                               style: StrokeStyle(lineWidth: 1.2 / inv, lineJoin: .round))
                }
                for shape in targetShapes {
                    if shape.needsLeader, let a = shape.anchor, let d = shape.dot {
                        ClickDots.leader(from: a, to: d, in: &ctx, color: ringColor, scale: inv)
                    }
                    let path = ClickDots.path(for: shape, scale: inv)
                    ctx.fill(path, with: .color(targetColor), style: FillStyle(eoFill: true))
                    ctx.stroke(path, with: .color(look.outline),
                               style: StrokeStyle(lineWidth: 1.2 / inv, lineJoin: .round))
                }
                if let ring = MapDrawing.markerRing(for: targetShapes.flatMap { $0.polygons }) {
                    ctx.stroke(Path(ellipseIn: ring), with: .color(ringColor),
                               style: StrokeStyle(lineWidth: 2.5 / inv, lineCap: .round, dash: [5 / inv, 4 / inv]))
                }
            }
            .shadow(color: targetColor.opacity(0.7), radius: 12)
        }
        .allowsHitTesting(false)
        .onAppear { start = Date() }
    }
}
