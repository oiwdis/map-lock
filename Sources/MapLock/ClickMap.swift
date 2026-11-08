import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// "Click the country": which places can be clicked, where the small-country dots go,
// and what a click at a point hits. Everything here is in view (screen) points.

/// One clickable country, already projected and fitted to the view.
struct ClickTarget {
    let name: String
    /// Polygons in view points (first ring of each is the outline, the rest are holes).
    let polygons: [[[CGPoint]]]
    let bounds: CGRect
    /// Center of the Seterra-style dot, for countries too small to click well. Nil means no dot.
    let dot: CGPoint?
    /// The country's true center. Differs from `dot` when the dot was nudged away from a neighbor.
    let anchor: CGPoint?

    /// Drawn places that are not in the quiz (like Palestine or Greenland). A click inside one
    /// counts as the sea, and the forgiving edge never hands it to a neighbor.
    var isSea: Bool { name.isEmpty }

    /// Whether the dot sits far enough from the true center to need a leader line.
    var needsLeader: Bool {
        guard let dot, let anchor else { return false }
        return hypot(dot.x - anchor.x, dot.y - anchor.y) > ClickMap.leaderMin
    }
}

enum ClickMap {
    /// Dot size as drawn (diameter, points).
    static let dotDiameter: CGFloat = 10
    static var dotRadius: CGFloat { dotDiameter / 2 }
    /// The clickable circle around a dot is a bit bigger than the drawn dot.
    static let hitDiameter: CGFloat = 14
    static var hitRadius: CGFloat { hitDiameter / 2 }
    /// Dots closer than this (center to center) get pushed apart.
    static let dotSpacing: CGFloat = 12
    /// A nudged dot gets a thin line back to its country once it moved more than this.
    static let leaderMin: CGFloat = 3
    /// Countries that get a Seterra-style dot in the whole-region click view: small islands
    /// and microstates whose shape is too tiny to click. Everything else is clicked by its
    /// shape (with `shapeSlop` of give). North and South America get no dots, like Seterra.
    static let dotCountries: [Region: Set<String>] = [
        .asia: ["Bahrain", "Maldives", "Singapore", "Brunei", "Timor-Leste"],
        .africa: ["Cabo Verde", "Sao Tome and Principe", "Comoros", "Mauritius", "Seychelles"],
        .europe: ["Vatican City", "Monaco", "San Marino", "Liechtenstein", "Malta", "Andorra"],
    ]
    /// Fixed starting nudge for a dot, in view points (about 13 points up and left for Bahrain).
    static let dotOffsets: [String: CGPoint] = ["Bahrain": CGPoint(x: -5, y: -12)]
    /// Qatar gets a dot only when its shape is smaller than this on screen.
    static let qatarDotSide: CGFloat = 6
    /// A click this close to a country's edge (outside it) still counts for that country.
    static let shapeSlop: CGFloat = 4
    /// A click in the sea this close to a dot's edge still counts for that dot.
    static let dotSnap: CGFloat = 8

    /// Drawn places that are not asked, but are part of a country that is.
    /// A click on them counts as that country. Other non-quiz places are ignored like the sea.
    /// Former aliases (Somaliland, Northern Cyprus, Hong Kong, Macao, Siachen Glacier)
    /// are merged into the parent country in countries.geojson, so they no longer exist
    /// as separate features. Keep this empty unless a new split piece appears.
    static let clickAliases: [String: String] = [:]

    /// The countries that can be clicked for a question: the target's own region,
    /// the places that are asked (plus the alias pieces), and only the ones on screen. Other drawn
    /// places in the region come back with an empty name so a click on them counts as the sea.
    static func targets(for target: Country, world: [Country], map: FittedMap, size: CGSize,
                        scope: PracticeScope? = nil) -> [ClickTarget] {
        let screen = CGRect(origin: .zero, size: size)
        // Click questions show the whole region (or the whole world for world practice).
        // Every country in that scope can get a dot. Dots stay well inside the map.
        let dotArea = screen.insetBy(dx: dotDiameter, dy: dotDiameter)
        let inScope: (Country) -> Bool = { c in
            switch scope {
            case .none:
                return c.region == target.region
            case .some(.region(let region)):
                return c.region == region
            case .some(.world):
                return true
            case .some(.custom):
                return true
            }
        }
        let chosen: Set<String>? = {
            if case .some(.custom(let countries)) = scope { return Set(countries) }
            return nil
        }()
        var result: [ClickTarget] = []
        for country in world where inScope(country) {
            let name: String
            let inQuiz = country.quizzable && (chosen?.contains(country.name) ?? true)
            if inQuiz {
                name = country.name
            } else if let alias = clickAliases[country.name], chosen?.contains(alias) ?? true {
                name = alias
            } else {
                name = ""   // not asked: a click here is ignored like the sea
            }
            let polygons = map.viewPolygons(for: country)
            guard !polygons.isEmpty else { continue }
            let bounds = boundsOf(polygons)
            guard bounds.intersects(screen) else { continue }
            // Alias pieces never get their own dot.
            let anchor = inQuiz && wantsDot(country, polygons: polygons) ? dotCenter(for: polygons) : nil
            var dot = anchor
            // Bahrain sits right next to Qatar: its dot starts up and to the left of the island,
            // out over the Gulf, with a leader line, so it covers none of Qatar.
            if let a = anchor, let off = dotOffsets[country.name] { dot = CGPoint(x: a.x + off.x, y: a.y + off.y) }
            if let d = dot, !dotArea.contains(d) { dot = CGPoint(x: min(max(d.x, dotArea.minX), dotArea.maxX),
                                                                  y: min(max(d.y, dotArea.minY), dotArea.maxY)) }
            result.append(ClickTarget(name: name, polygons: polygons, bounds: bounds, dot: dot, anchor: anchor))
        }
        return spreadDots(result)
    }

    /// Pushes dots apart so neighbors like Rwanda and Burundi never sit on top of each other.
    static func spreadDots(_ targets: [ClickTarget]) -> [ClickTarget] {
        var dots = targets.map { $0.dot }
        let gap = dotSpacing
        // Small countries (like Qatar next to Bahrain) keep their spot: another country's dot
        // is pushed off them so it never covers them. Their own dot may stay.
        let keepClear = targets.indices.filter { isSmall(targets[$0]) }
            .map { (index: $0, center: CGPoint(x: targets[$0].bounds.midX, y: targets[$0].bounds.midY)) }
        for _ in 0..<12 {
            var moved = false
            for i in dots.indices {
                guard let a = dots[i] else { continue }
                for (k, c) in keepClear where k != i {
                    var dx = a.x - c.x, dy = a.y - c.y
                    var d = hypot(dx, dy)
                    guard d < gap else { continue }
                    if d < 0.01 { dx = 1; dy = 0; d = 1 }
                    dots[i] = CGPoint(x: c.x + dx / d * gap, y: c.y + dy / d * gap)
                    moved = true
                }
            }
            for i in dots.indices {
                guard let a = dots[i] else { continue }
                for j in dots.indices where j > i {
                    guard let b = dots[j] else { continue }
                    var dx = b.x - a.x, dy = b.y - a.y
                    var d = hypot(dx, dy)
                    guard d < gap else { continue }
                    if d < 0.01 { dx = 1; dy = 0; d = 1 }
                    let push = (gap - d) / 2
                    let ux = dx / d, uy = dy / d
                    dots[i] = CGPoint(x: a.x - ux * push, y: a.y - uy * push)
                    dots[j] = CGPoint(x: b.x + ux * push, y: b.y + uy * push)
                    moved = true
                }
            }
            if !moved { break }
        }
        // A nudged dot that ended up on another country's land (Bahrain pushed onto Saudi
        // Arabia) moves to the nearest spot out in the sea, still clear of the other dots.
        let land = targets.filter { !$0.isSea }
        func onOtherLand(_ p: CGPoint, _ i: Int) -> Bool {
            land.contains { $0.name != targets[i].name && $0.bounds.insetBy(dx: -2, dy: -2).contains(p)
                && (contains($0.polygons, p) || edgeDistance(p, $0.polygons) < 2) }
        }
        for i in dots.indices {
            guard let d = dots[i], let start = targets[i].anchor, hypot(d.x - start.x, d.y - start.y) > 0.5,
                  onOtherLand(d, i) else { continue }
            var best: (p: CGPoint, cost: CGFloat)? = nil
            for step in 0..<8 {
                let r = gap + CGFloat(step) * 2
                for k in 0..<24 {
                    let ang = Double(k) / 24 * 2 * Double.pi
                    let p = CGPoint(x: start.x + r * CGFloat(cos(ang)), y: start.y + r * CGFloat(sin(ang)))
                    guard !onOtherLand(p, i) else { continue }
                    let clearOfDots = dots.indices.allSatisfy { j in j == i || dots[j].map { hypot($0.x - p.x, $0.y - p.y) >= gap } ?? true }
                    let clearOfSmall = keepClear.allSatisfy { $0.index == i || hypot($0.center.x - p.x, $0.center.y - p.y) >= gap }
                    guard clearOfDots && clearOfSmall else { continue }
                    let cost = hypot(p.x - d.x, p.y - d.y)
                    if cost < (best?.cost ?? .infinity) { best = (p, cost) }
                }
                if best != nil { break }
            }
            if let best { dots[i] = best.p }
        }
        return zip(targets, dots).map {
            ClickTarget(name: $0.name, polygons: $0.polygons, bounds: $0.bounds, dot: $1, anchor: $0.anchor)
        }
    }

    /// A small country shape (under 12 points on its longest side). Other dots keep off it,
    /// and a click inside it always counts for it.
    static func isSmall(_ t: ClickTarget) -> Bool {
        !t.isSea && max(t.bounds.width, t.bounds.height) < smallSide
    }
    static let smallSide: CGFloat = 12

    static func wantsDot(_ country: Country, polygons: [[[CGPoint]]]) -> Bool {
        if dotCountries[country.region]?.contains(country.name) == true { return true }
        if country.name == "Qatar" {
            let b = boundsOf(polygons)
            return max(b.width, b.height) < qatarDotSide
        }
        return false
    }

    /// Where to put the dot: the area weighted center of all the country's pieces.
    static func dotCenter(for polygons: [[[CGPoint]]]) -> CGPoint? {
        let outlines = polygons.compactMap { $0.first }
        guard !outlines.isEmpty else { return nil }
        let bounds = boundsOf(polygons)

        // Area weighted center of all pieces. For a chain of specks (like the Maldives)
        // this lands in the middle of the chain.
        var sx = 0.0, sy = 0.0, sw = 0.0
        for ring in outlines {
            let a = abs(signedArea(ring))
            let c = ringCenter(ring)
            let w = max(a, 0.01)
            sx += Double(c.x) * w; sy += Double(c.y) * w; sw += w
        }
        guard sw > 0 else { return CGPoint(x: bounds.midX, y: bounds.midY) }
        return CGPoint(x: sx / sw, y: sy / sw)
    }

    /// What a click at `point` picks: a dot hit first (dots are drawn on top),
    /// then the country shapes, then a dot within the snap distance. Nil means the sea.
    static func hit(_ point: CGPoint, in targets: [ClickTarget]) -> String? {
        // 1. Right on a dot. A click inside another small country's shape (Qatar next to the
        //    Bahrain dot) always counts for that country. A click inside a bigger dot-less shape
        //    only goes to the dot when it is on the drawn dot itself.
        if let name = nearestDot(to: point, in: targets, within: hitRadius) {
            let inside = { (t: ClickTarget) in t.bounds.contains(point) && contains(t.polygons, point) }
            if let small = targets.first(where: { isSmall($0) && $0.name != name && inside($0) }) {
                return small.name
            }
            let onDrawnDot = nearestDot(to: point, in: targets, within: dotRadius) != nil
            let inShape = targets.contains { !$0.isSea && $0.dot == nil && inside($0) }
            if onDrawnDot || !inShape { return name }
        }
        // 2. Inside a country shape. Smaller boxes first, so a small country wins over a big
        //    neighbor if the outlines overlap a little.
        let candidates = targets.filter { $0.bounds.insetBy(dx: -1, dy: -1).contains(point) }
            .sorted { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
        for t in candidates where contains(t.polygons, point) {
            return t.isSea ? nil : t.name
        }
        // 3. Just outside a shape: the closest edge within shapeSlop.
        var best: (name: String, d: CGFloat)? = nil
        for t in targets where !t.isSea && t.bounds.insetBy(dx: -shapeSlop, dy: -shapeSlop).contains(point) {
            let d = edgeDistance(point, t.polygons)
            if d <= shapeSlop && d < (best?.d ?? .infinity) { best = (t.name, d) }
        }
        if let best { return best.name }
        // 4. Near a dot, out in the sea.
        return nearestDot(to: point, in: targets, within: hitRadius + dotSnap)
    }

    /// Shortest distance from a point to any outline edge.
    static func edgeDistance(_ p: CGPoint, _ polygons: [[[CGPoint]]]) -> CGFloat {
        var best = CGFloat.infinity
        for polygon in polygons {
            guard let ring = polygon.first, ring.count >= 2 else { continue }
            var j = ring.count - 1
            for i in 0..<ring.count {
                let a = ring[j], b = ring[i]
                let dx = b.x - a.x, dy = b.y - a.y
                let len2 = dx * dx + dy * dy
                var t = len2 > 0 ? ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2 : 0
                t = min(max(t, 0), 1)
                best = min(best, hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy)))
                j = i
            }
        }
        return best
    }

    private static func nearestDot(to point: CGPoint, in targets: [ClickTarget], within limit: CGFloat) -> String? {
        var best: (name: String, d: CGFloat)? = nil
        for t in targets {
            guard let c = t.dot else { continue }
            let d = hypot(point.x - c.x, point.y - c.y)
            if d <= limit && d < (best?.d ?? .infinity) { best = (t.name, d) }
        }
        return best?.name
    }

    /// Even-odd point in polygon over all rings, so holes (like Lesotho inside South Africa) work.
    static func contains(_ polygons: [[[CGPoint]]], _ p: CGPoint) -> Bool {
        var inside = false
        for polygon in polygons {
            for ring in polygon where ring.count >= 3 {
                var j = ring.count - 1
                for i in 0..<ring.count {
                    let a = ring[i], b = ring[j]
                    if (a.y > p.y) != (b.y > p.y) {
                        let x = (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x
                        if p.x < x { inside.toggle() }
                    }
                    j = i
                }
            }
        }
        return inside
    }

    static func boundsOf(_ polygons: [[[CGPoint]]]) -> CGRect {
        var minX = CGFloat.infinity, minY = CGFloat.infinity
        var maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        for polygon in polygons {
            guard let ring = polygon.first else { continue }
            for p in ring {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
        }
        guard minX.isFinite else { return .null }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func signedArea(_ ring: [CGPoint]) -> Double {
        guard ring.count >= 3 else { return 0 }
        var s = 0.0
        var j = ring.count - 1
        for i in 0..<ring.count {
            s += Double(ring[j].x) * Double(ring[i].y) - Double(ring[i].x) * Double(ring[j].y)
            j = i
        }
        return s / 2
    }

    /// Centroid of one ring (falls back to the box center for slivers).
    static func ringCenter(_ ring: [CGPoint]) -> CGPoint {
        let a = signedArea(ring)
        if abs(a) < 1e-6 {
            let b = WorldLoader.bounds(of: ring)
            return CGPoint(x: b.midX, y: b.midY)
        }
        var cx = 0.0, cy = 0.0
        var j = ring.count - 1
        for i in 0..<ring.count {
            let f = Double(ring[j].x) * Double(ring[i].y) - Double(ring[i].x) * Double(ring[j].y)
            cx += (Double(ring[j].x) + Double(ring[i].x)) * f
            cy += (Double(ring[j].y) + Double(ring[i].y)) * f
            j = i
        }
        return CGPoint(x: cx / (6 * a), y: cy / (6 * a))
    }
}

/// The ring drawn around a target that is too small to see well, in both quiz types.
enum MapMarks {
    /// Small means under `maxArea` square points, or under `maxSide` points on its long side
    /// (so thin or island countries like Sri Lanka get a ring too).
    static let maxArea: Double = 300
    static let maxSide: CGFloat = 22

    static func ring(for polygons: [[[CGPoint]]]) -> CGRect? {
        let outlines = polygons.compactMap { $0.first }
        guard !outlines.isEmpty else { return nil }
        let areas = outlines.map { Geometry.area($0) }
        let total = areas.reduce(0, +)

        // Center on the main pieces (skip far away specks).
        let largest = areas.max() ?? 0
        var box: CGRect? = nil
        for (ring, area) in zip(outlines, areas) where area >= largest * 0.15 || largest == 0 {
            let b = Geometry.bounds(ring)
            box = box.map { $0.union(b) } ?? b
        }
        guard let b = box else { return nil }
        guard total < maxArea || max(b.width, b.height) < maxSide else { return nil }
        let radius = max(16, max(b.width, b.height) / 2 + 10)
        return CGRect(x: b.midX - radius, y: b.midY - radius, width: radius * 2, height: radius * 2)
    }
}
