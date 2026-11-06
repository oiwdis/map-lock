import SwiftUI

enum TargetState: Equatable {
    case asking, right, wrong

    var color: Color {
        switch self {
        // Map colors, picked to read on the land in Light and Dark.
        case .asking: return Theme.mapTarget
        case .right: return Theme.mapGood
        case .wrong: return Theme.mapBad
        }
    }

    /// Dark edge around the fill, so yellow and lime read on light sea and land.
    var outline: Color {
        switch self {
        case .asking: return Theme.mapTargetOutline
        case .right: return Theme.mapGoodOutline
        case .wrong: return Theme.mapBadOutline
        }
    }

    /// Ring around a tiny target. Orange in Light, since yellow vanishes on the light sea.
    var ring: Color {
        switch self {
        case .asking: return Theme.ringTiny
        case .right: return Theme.ringGood
        case .wrong: return Theme.ringBad
        }
    }
}

/// The map for one question: a still base map plus a glowing target layer on top.
/// Pinch / scroll zoom and drag pan (same controls as the click map).
struct MapView: View {
    let world: [Country]
    let target: Country
    let state: TargetState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var zoom = MapZoomState()

    var body: some View {
        let plan = MapViews.plan(for: target, world: world)
        GeometryReader { geo in
            ZStack {
                BaseMap(world: world, target: target, plan: plan, scheme: scheme, zoom: zoom)
                    .equatable()
                TargetLayer(target: target, plan: plan, state: state, animate: !reduceMotion,
                            zoom: zoom)
                MapInteractionOverlay(
                    size: geo.size,
                    zoom: zoom,
                    clicksEnabled: false,
                    onZoomChange: { zoom = $0 }
                )
                VStack {
                    HStack {
                        Spacer()
                        MapZoomControls(zoom: $zoom, size: geo.size)
                    }
                    Spacer()
                }
                .padding(10)
            }
            .clipShape(Rectangle())
            .contentShape(Rectangle())
        }
        .onChange(of: target.name) { _, _ in
            zoom.reset()
        }
    }
}

/// Every country except the target. Only redraws when the question or zoom changes.
private struct BaseMap: View, Equatable {
    let world: [Country]
    let target: Country
    let plan: MapPlan
    /// Part of the equality so a Light / Dark switch redraws the map.
    let scheme: ColorScheme
    let zoom: MapZoomState

    nonisolated static func == (lhs: BaseMap, rhs: BaseMap) -> Bool {
        lhs.target.name == rhs.target.name
            && lhs.world.count == rhs.world.count
            && lhs.scheme == rhs.scheme
            && lhs.zoom == rhs.zoom
    }

    var body: some View {
        let world = self.world
        let target = self.target
        let plan = self.plan
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
            let map = FittedMap(projection: plan.projection, fit: plan.fit, size: size)
            let visible = rect.insetBy(dx: -40 / inv, dy: -40 / inv)
            for country in world where country.name != target.name && country.region == target.region {
                let path = MapDrawing.makePath(map.viewPolygons(for: country))
                guard path.boundingRect.intersects(visible) else { continue }
                let fill = Theme.land  // only the region is drawn; everything else is sea
                mapContext.fill(path, with: .color(fill), style: FillStyle(eoFill: true))
                mapContext.stroke(path, with: .color(Theme.border),
                               style: StrokeStyle(lineWidth: 0.6 / inv, lineJoin: .round))
            }
        }
        .allowsHitTesting(false)
    }
}

/// The target with a soft glow, plus a dashed ring for tiny places.
/// While asking, the glow breathes and the ring turns slowly (unless Reduce Motion is on).
private struct TargetLayer: View {
    let target: Country
    let plan: MapPlan
    let state: TargetState
    let animate: Bool
    let zoom: MapZoomState

    /// Read so a Light / Dark switch redraws this layer right away.
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let paused = !(animate && state == .asking)
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { timeline in
            let t = paused ? 0 : timeline.date.timeIntervalSinceReferenceDate
            // 1.8 second breathing cycle, like the mockup's glow.
            let breath = paused ? 0.0 : (1 - cos(t * 2 * .pi / 1.8)) / 2
            let color = state.color
            let glowRadius = state == .asking ? 10 + 8 * breath : 12
            let glowOpacity = state == .asking ? 0.55 + 0.3 * breath : 0.7
            let dashPhase = CGFloat(t.truncatingRemainder(dividingBy: 6) / 6 * 54)
            let inv = max(zoom.scale, 0.001)

            Canvas { context, size in
                var ctx = context
                ctx.beginMapZoom(zoom, size: size)
                let map = FittedMap(projection: plan.projection, fit: plan.fit, size: size)
                let polygons = map.viewPolygons(for: target)
                let path = MapDrawing.makePath(polygons)
                ctx.fill(path, with: .color(color), style: FillStyle(eoFill: true))
                ctx.stroke(path, with: .color(state.outline),
                           style: StrokeStyle(lineWidth: 1 / inv, lineJoin: .round))

                if let ring = MapDrawing.markerRing(for: polygons) {
                    ctx.stroke(
                        Path(ellipseIn: ring),
                        with: .color(state.ring),
                        style: StrokeStyle(lineWidth: 2.5 / inv, lineCap: .round,
                                           dash: [5 / inv, 4 / inv], dashPhase: -dashPhase / inv)
                    )
                }
            }
            .shadow(color: color.opacity(glowOpacity), radius: glowRadius)
        }
        .id(scheme)
        .allowsHitTesting(false)
    }
}

enum MapDrawing {
    static func makePath(_ polygons: [[[CGPoint]]]) -> Path {
        var path = Path()
        for polygon in polygons {
            for ring in polygon {
                guard let first = ring.first else { continue }
                path.move(to: first)
                for point in ring.dropFirst() {
                    path.addLine(to: point)
                }
                path.closeSubpath()
            }
        }
        return path
    }

    /// A circle around the target when it is too small to see well (see MapMarks).
    static func markerRing(for polygons: [[[CGPoint]]]) -> CGRect? {
        MapMarks.ring(for: polygons)
    }
}
