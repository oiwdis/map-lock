import SwiftUI

enum TargetState: Equatable {
    case asking, right, wrong

    var color: Color {
        switch self {
        case .asking: return Theme.target
        case .right: return Theme.good
        case .wrong: return Theme.bad
        }
    }
}

/// The map for one question: a still base map plus a glowing target layer on top.
/// See Projection.swift for the view and projection logic.
struct MapView: View {
    let world: [Country]
    let target: Country
    let state: TargetState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let plan = MapViews.plan(for: target, world: world)
        ZStack {
            BaseMap(world: world, target: target, plan: plan)
                .equatable()
            TargetLayer(target: target, plan: plan, state: state, animate: !reduceMotion)
        }
    }
}

/// Every country except the target. Only redraws when the question changes.
private struct BaseMap: View, Equatable {
    let world: [Country]
    let target: Country
    let plan: MapPlan

    nonisolated static func == (lhs: BaseMap, rhs: BaseMap) -> Bool {
        lhs.target.name == rhs.target.name && lhs.world.count == rhs.world.count
    }

    var body: some View {
        let world = self.world
        let target = self.target
        let plan = self.plan
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

            let map = FittedMap(projection: plan.projection, fit: plan.fit, size: size)
            let visible = rect.insetBy(dx: -20, dy: -20)
            for country in world where country.name != target.name {
                let path = MapDrawing.makePath(map.viewPolygons(for: country))
                guard path.boundingRect.intersects(visible) else { continue }
                let fill = country.region == target.region ? Theme.land : Theme.landFar
                context.fill(path, with: .color(fill), style: FillStyle(eoFill: true))
                context.stroke(path, with: .color(Theme.border),
                               style: StrokeStyle(lineWidth: 0.6, lineJoin: .round))
            }
        }
    }
}

/// The target with a soft glow, plus a dashed ring for tiny places.
/// While asking, the glow breathes and the ring turns slowly (unless Reduce Motion is on).
private struct TargetLayer: View {
    let target: Country
    let plan: MapPlan
    let state: TargetState
    let animate: Bool

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

            Canvas { context, size in
                let map = FittedMap(projection: plan.projection, fit: plan.fit, size: size)
                let polygons = map.viewPolygons(for: target)
                let path = MapDrawing.makePath(polygons)
                context.fill(path, with: .color(color), style: FillStyle(eoFill: true))
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 0.8, lineJoin: .round))

                if let ring = MapDrawing.markerRing(for: polygons) {
                    context.stroke(
                        Path(ellipseIn: ring),
                        with: .color(color),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [5, 4], dashPhase: -dashPhase)
                    )
                }
            }
            .shadow(color: color.opacity(glowOpacity), radius: glowRadius)
        }
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

    /// A circle around the target when it is too small to see well.
    static func markerRing(for polygons: [[[CGPoint]]]) -> CGRect? {
        let outlines = polygons.compactMap { $0.first }
        guard !outlines.isEmpty else { return nil }
        let areas = outlines.map { Geometry.area($0) }
        let total = areas.reduce(0, +)
        guard total < 120 else { return nil }

        // Center on the main pieces (skip far away specks).
        let largest = areas.max() ?? 0
        var box: CGRect? = nil
        for (ring, area) in zip(outlines, areas) where area >= largest * 0.15 || largest == 0 {
            let b = Geometry.bounds(ring)
            box = box.map { $0.union(b) } ?? b
        }
        guard let b = box else { return nil }
        let radius = max(16, max(b.width, b.height) / 2 + 10)
        return CGRect(x: b.midX - radius, y: b.midY - radius, width: radius * 2, height: radius * 2)
    }
}
