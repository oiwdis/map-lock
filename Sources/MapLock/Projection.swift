import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// Map views and projections. This mirrors the web mockup:
// - Asia is split into five smaller views, Russia gets its own view.
// - North America is split into three views. Europe uses a fixed frame.
// - Regions away from the equator use a conic equal-area (Albers) projection
//   with standard parallels fitted to the region.
// - Regions that cross the equator use a Lambert azimuthal equal-area
//   projection centered on the region.
// - Africa fits the mainland, unless the question is about an island country.

enum MapViews {
    static let asiaParts: [(title: String, names: [String])] = [
        ("West Asia", ["Turkey", "Georgia", "Armenia", "Azerbaijan", "Syria", "Lebanon", "Israel",
                       "Palestine", "Jordan", "Iraq", "Iran", "Kuwait", "Saudi Arabia", "Bahrain",
                       "Qatar", "United Arab Emirates", "Oman", "Yemen", "Cyprus", "Northern Cyprus"]),
        ("Central Asia", ["Kazakhstan", "Uzbekistan", "Turkmenistan", "Kyrgyzstan", "Tajikistan", "Afghanistan"]),
        ("South Asia", ["Pakistan", "India", "Nepal", "Bhutan", "Bangladesh", "Sri Lanka", "Maldives",
                        "Siachen Glacier"]),
        ("East Asia", ["China", "Mongolia", "North Korea", "South Korea", "Japan", "Taiwan",
                       "Hong Kong", "Macao"]),
        ("Southeast Asia", ["Myanmar", "Thailand", "Laos", "Cambodia", "Vietnam", "Malaysia", "Singapore",
                            "Brunei", "Indonesia", "Philippines", "Timor-Leste"]),
    ]

    /// Island countries far from the mainland view. They are only added to the
    /// view when they are the question.
    static let farIslands: Set<String> = [
        "Cabo Verde", "Mauritius", "Seychelles", "Comoros", "Sao Tome and Principe", "Maldives",
    ]

    /// Mainland Africa (ignores far islands like the Prince Edward Islands).
    static let africaBox = CGRect(x: -18, y: -35.5, width: 70, height: 73.5)

    /// Europe from Iceland and Portugal in the west to Ukraine and the Caucasus in the east,
    /// and from Norway's North Cape down to Crete and Cyprus. Russia (Asia here, with its own view),
    /// Svalbard and Greenland do not widen it.
    static let europeBox = CGRect(x: -25, y: 34.5, width: 70, height: 37)

    /// Edges of the Europe view that are not European countries here:
    /// Cyprus and the Caucasus in the south east, and the Ukraine and Russia border.
    static let europeExtras: [CGRect] = [
        CGRect(x: 32.2, y: 34.5, width: 2.4, height: 1.3),
        CGRect(x: 40, y: 41, width: 6.5, height: 2.6),
    ]

    /// North America is split into smaller views, like Asia.
    /// `box` is the lon/lat area the view always fits (nil means fit the countries).
    static let northAmericaParts: [(title: String, names: [String], box: CGRect?)] = [
        // Alaska to Newfoundland, down to southern Mexico. Leaves out the far Arctic islands.
        ("Canada, US and Mexico", ["Canada", "United States", "Mexico"],
         CGRect(x: -170, y: 14.5, width: 117, height: 57.5)),
        ("Central America", ["Guatemala", "Belize", "Honduras", "El Salvador", "Nicaragua",
                             "Costa Rica", "Panama"],
         CGRect(x: -92.4, y: 7.1, width: 15.2, height: 11.5)),
        ("Caribbean", ["Cuba", "Bahamas", "Jamaica", "Haiti", "Dominican Republic", "Puerto Rico",
                       "Antigua and Barbuda", "Saint Kitts and Nevis", "Dominica", "Saint Lucia",
                       "Saint Vincent and the Grenadines", "Barbados", "Grenada", "Trinidad and Tobago"],
         CGRect(x: -85.2, y: 9.9, width: 25.9, height: 17.5)),
    ]

    /// Short title for the view a target is shown in (for the header).
    static func title(for target: Country) -> String {
        if target.name == "Russia" { return "Russia" }
        if target.region == .asia, let part = asiaParts.first(where: { $0.names.contains(target.name) }) {
            return part.title
        }
        if target.region == .northAmerica {
            if let part = northAmericaParts.first(where: { $0.names.contains(target.name) }) {
                return part.title
            }
            return target.name
        }
        return target.region.title
    }

    /// Picks the projection and the lon/lat boxes the view must fit.
    static func plan(for target: Country, world: [Country]) -> MapPlan {
        let byName = Dictionary(world.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var boxes: [CGRect] = []

        if target.name == "Russia" {
            boxes = [target.focusBounds]
            return MapPlan(projection: GeoProjection.conic(lon0: 100, lat0: 45, lat1: 75), fit: boxes)
        }

        switch target.region {
        case .asia:
            if let part = asiaParts.first(where: { $0.names.contains(target.name) }) {
                boxes = part.names.compactMap { byName[$0]?.focusBounds }
            } else {
                boxes = [target.focusBounds.insetBy(dx: -10, dy: -8)]
            }
        case .africa:
            boxes = [africaBox]
            if farIslands.contains(target.name) { boxes.append(target.focusBounds) }
        case .europe:
            // Fit the European countries themselves (clipped to the frame), not one big
            // lon/lat box: on a conic map the corners of a big box swing far out.
            boxes = world.filter { $0.region == .europe }
                .map { $0.focusBounds.intersection(europeBox) }
                .filter { !$0.isNull && !$0.isEmpty }
            boxes += europeExtras
            if !europeBox.contains(target.focusBounds) {
                // A place outside the usual frame still gets fully shown.
                boxes.append(target.focusBounds)
                break
            }
            return MapPlan(projection: GeoProjection.conic(lon0: 15, lat0: 43, lat1: 62), fit: boxes)
        case .northAmerica:
            if let part = northAmericaParts.first(where: { $0.names.contains(target.name) }) {
                if let box = part.box {
                    // The countries clipped to the frame, so box corners do not swing out.
                    boxes = part.names.compactMap { byName[$0]?.focusBounds.intersection(box) }
                        .filter { !$0.isNull && !$0.isEmpty }
                    if boxes.isEmpty { boxes = [box] }
                } else {
                    boxes = part.names.compactMap { byName[$0]?.focusBounds }
                }
            } else {
                // Places like Greenland get their own frame with a little room around them.
                let b = target.focusBounds
                boxes = [b.insetBy(dx: -b.width * 0.15, dy: -b.height * 0.15)]
            }
        case .southAmerica:
            boxes = world.filter { $0.region == target.region && (!farIslands.contains($0.name) || $0.name == target.name) }
                .map { $0.focusBounds }
        }
        if !boxes.contains(where: { $0.contains(target.focusBounds) || $0.intersects(target.focusBounds) }) {
            boxes.append(target.focusBounds)
        }

        var union = boxes[0]
        for b in boxes.dropFirst() { union = union.union(b) }
        let lon0 = Double(union.midX)
        let la0 = Double(union.minY), la1 = Double(union.maxY)

        if la0 < 5 && la1 > -5 {
            return MapPlan(projection: GeoProjection.azimuthal(lon0: lon0, lat0: Double(union.midY)), fit: boxes)
        }
        let d = (la1 - la0) / 6
        return MapPlan(projection: GeoProjection.conic(lon0: lon0, lat0: la0 + d, lat1: la1 - d), fit: boxes)
    }
}

/// What to show for one question: the projection and the lon/lat boxes to fit.
struct MapPlan: Sendable {
    let projection: GeoProjection
    let fit: [CGRect]
}

/// Projects longitude / latitude (degrees) to flat x / y with y pointing down.
struct GeoProjection {
    enum Kind {
        /// Albers conic equal-area.
        case conic(n: Double, c: Double, r0: Double)
        /// Lambert azimuthal equal-area.
        case azimuthal(sinLat0: Double, cosLat0: Double)
    }

    let kind: Kind
    let lon0: Double

    private static let rad = Double.pi / 180
    /// Points further than this from the center are pushed onto the edge circle.
    private static let maxAngle = 100.0 * Double.pi / 180

    static func conic(lon0: Double, lat0: Double, lat1: Double) -> GeoProjection {
        let s0 = sin(lat0 * rad)
        let n = (s0 + sin(lat1 * rad)) / 2
        if abs(n) < 1e-6 {
            return azimuthal(lon0: lon0, lat0: (lat0 + lat1) / 2)
        }
        let c = 1 + s0 * (2 * n - s0)
        let r0 = c.squareRoot() / n
        return GeoProjection(kind: .conic(n: n, c: c, r0: r0), lon0: lon0)
    }

    static func azimuthal(lon0: Double, lat0: Double) -> GeoProjection {
        GeoProjection(kind: .azimuthal(sinLat0: sin(lat0 * rad), cosLat0: cos(lat0 * rad)), lon0: lon0)
    }

    private static func wrap(_ degrees: Double) -> Double {
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    /// Projects one point. `previousDelta` keeps a ring continuous across the back meridian
    /// so shapes never jump across the map.
    func project(lon: Double, lat: Double, previousDelta: inout Double?) -> (point: CGPoint, beyondHorizon: Bool) {
        var dl = GeoProjection.wrap(lon - lon0)
        let rad = GeoProjection.rad
        switch kind {
        case let .conic(n, c, r0):
            if let prev = previousDelta {
                while dl - prev > 180 { dl -= 360 }
                while dl - prev < -180 { dl += 360 }
            }
            previousDelta = dl
            let lam = dl * rad
            let phi = lat * rad
            let r = max(0, c - 2 * n * sin(phi)).squareRoot() / n
            let x = r * sin(n * lam)
            let y = r * cos(n * lam) - r0
            return (CGPoint(x: x, y: y), false)

        case let .azimuthal(s0, c0):
            let lam = dl * rad
            let phi = lat * rad
            let sp = sin(phi), cp = cos(phi), cl = cos(lam)
            let cosc = s0 * sp + c0 * cp * cl
            let px = cp * sin(lam)
            let py = c0 * sp - s0 * cp * cl
            if cosc >= cos(GeoProjection.maxAngle) {
                let k = (2 / (1 + cosc)).squareRoot()
                return (CGPoint(x: k * px, y: -k * py), cosc < 0)
            }
            // Past the edge: put it on the edge circle in the right direction.
            let dir = atan2(py, px)
            let edge = 2 * sin(GeoProjection.maxAngle / 2)
            return (CGPoint(x: edge * cos(dir), y: -edge * sin(dir)), true)
        }
    }

    /// Projects a ring. Returns nil if the whole ring is on the far side of the globe.
    func project(ring: [CGPoint]) -> [CGPoint]? {
        var prev: Double? = nil
        var out: [CGPoint] = []
        out.reserveCapacity(ring.count)
        var anyVisible = false
        for p in ring {
            let r = project(lon: Double(p.x), lat: Double(p.y), previousDelta: &prev)
            if !r.beyondHorizon { anyVisible = true }
            out.append(r.point)
        }
        return anyVisible ? out : nil
    }
}

/// Fits projected shapes into a view of a given size.
struct FittedMap {
    let projection: GeoProjection
    let scale: Double
    let offsetX: Double
    let offsetY: Double

    init(projection: GeoProjection, fit boxes: [CGRect], size: CGSize, margin: Double = 30) {
        self.projection = projection
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        let steps = 8
        for box in boxes {
            for i in 0...steps {
                let t = Double(i) / Double(steps)
                let lon = Double(box.minX) + t * Double(box.width)
                let lat = Double(box.minY) + t * Double(box.height)
                let samples = [(lon, Double(box.minY)), (lon, Double(box.maxY)),
                               (Double(box.minX), lat), (Double(box.maxX), lat)]
                for (sLon, sLat) in samples {
                    var prev: Double? = nil
                    let p = projection.project(lon: sLon, lat: sLat, previousDelta: &prev).point
                    minX = min(minX, Double(p.x)); maxX = max(maxX, Double(p.x))
                    minY = min(minY, Double(p.y)); maxY = max(maxY, Double(p.y))
                }
            }
        }
        if !minX.isFinite || maxX - minX <= 0 || maxY - minY <= 0 {
            minX = -1; maxX = 1; minY = -1; maxY = 1
        }
        let w = max(Double(size.width) - 2 * margin, 10)
        let h = max(Double(size.height) - 2 * margin, 10)
        scale = min(w / (maxX - minX), h / (maxY - minY))
        offsetX = Double(size.width) / 2 - (minX + maxX) / 2 * scale
        offsetY = Double(size.height) / 2 - (minY + maxY) / 2 * scale
    }

    func toView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: Double(p.x) * scale + offsetX, y: Double(p.y) * scale + offsetY)
    }

    /// Projected rings in view coordinates, grouped by polygon (first ring is the outline).
    func viewPolygons(for country: Country) -> [[[CGPoint]]] {
        var result: [[[CGPoint]]] = []
        for polygon in country.polygons {
            var rings: [[CGPoint]] = []
            for (i, ring) in polygon.enumerated() {
                guard let projected = projection.project(ring: ring) else {
                    if i == 0 { break } else { continue }
                }
                rings.append(projected.map(toView))
            }
            if !rings.isEmpty { result.append(rings) }
        }
        return result
    }
}

enum Geometry {
    static func area(_ ring: [CGPoint]) -> Double { WorldLoader.area(of: ring) }
    static func bounds(_ ring: [CGPoint]) -> CGRect { WorldLoader.bounds(of: ring) }
}
