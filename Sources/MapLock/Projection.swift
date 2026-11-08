import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// Map views and projections. This mirrors the web mockup:
// - Asia is split into five smaller views, Russia gets its own view.
// - North America is split into three views. Europe uses a fixed frame.
// - Every view uses a flat Miller map like Seterra: parallels and meridians are
//   straight lines, so shapes are not bent. Miller is Mercator with the far north
//   toned down, so Russia and Canada do not get huge and the Gulf stays readable. It is centered on the view's middle
//   longitude, so Russia's far east (Chukotka) stays joined across 180 degrees.
// - Africa fits the mainland, unless the question is about an island country.

enum MapViews {
    static let asiaParts: [(title: String, names: [String])] = [
        ("West Asia", ["Turkey", "Georgia", "Armenia", "Azerbaijan", "Syria", "Lebanon", "Israel",
                       "Palestine", "Jordan", "Iraq", "Iran", "Kuwait", "Saudi Arabia", "Bahrain",
                       "Qatar", "United Arab Emirates", "Oman", "Yemen", "Cyprus"]),
        ("Central Asia", ["Kazakhstan", "Uzbekistan", "Turkmenistan", "Kyrgyzstan", "Tajikistan", "Afghanistan"]),
        ("South Asia", ["Pakistan", "India", "Nepal", "Bhutan", "Bangladesh", "Sri Lanka", "Maldives"]),
        ("East Asia", ["China", "Mongolia", "North Korea", "South Korea", "Japan", "Taiwan"]),
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
                       "Trinidad and Tobago"],
         CGRect(x: -85.2, y: 9.9, width: 25.9, height: 17.5)),
    ]

    /// Parts of Russia outside its main box: Kaliningrad, and the tip of Chukotka past
    /// 180 degrees (written as 180 to 191 so it stays joined to the rest, not wrapped).
    static let russiaExtras: [CGRect] = [
        CGRect(x: 19.6, y: 54.3, width: 3.4, height: 1.1),
        CGRect(x: 180, y: 64.2, width: 11, height: 7.5),
    ]

    /// Middle longitude of the boxes, used as the map's center line.
    static func centerLon(_ boxes: [CGRect]) -> Double {
        guard var union = boxes.first else { return 0 }
        for b in boxes.dropFirst() { union = union.union(b) }
        return Double(union.midX)
    }

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
            boxes = [target.focusBounds] + russiaExtras
            return MapPlan(projection: GeoProjection.miller(lon0: centerLon(boxes)), fit: boxes)
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
            // Fit the European countries themselves, clipped to the frame.
            boxes = world.filter { $0.region == .europe }
                .map { $0.focusBounds.intersection(europeBox) }
                .filter { !$0.isNull && !$0.isEmpty }
            boxes += europeExtras
            if !europeBox.contains(target.focusBounds) {
                // A place outside the usual frame still gets fully shown.
                boxes.append(target.focusBounds)
                break
            }
            return MapPlan(projection: GeoProjection.miller(lon0: centerLon(boxes)), fit: boxes)
        case .northAmerica:
            if let part = northAmericaParts.first(where: { $0.names.contains(target.name) }) {
                if let box = part.box {
                    // The countries clipped to the frame.
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

        return MapPlan(projection: GeoProjection.miller(lon0: centerLon(boxes)), fit: boxes)
    }
}

extension MapViews {
    /// Lon/lat frame for the North America click view: the Yukon and Alaska border at 141 W
    /// (Alaska cut off, the panhandle along the BC coast stays) to
    /// Newfoundland and the Lesser Antilles, Hudson Bay down to Panama. Asia and South America
    /// fit their own countries (see regionPlan).
    static let clickFrames: [Region: CGRect] = [
        .northAmerica: CGRect(x: -141, y: 7, width: 89, height: 55),
    ]

    /// Width / height for the click map card, so the region fills it instead of leaving
    /// wide empty sides on a wide screen. Kept between 1.2 and 2.4.
    static func clickAspect(for target: Country, world: [Country]) -> Double {
        let plan = regionPlan(for: target, world: world)
        let map = FittedMap(projection: plan.projection, fit: plan.fit, size: CGSize(width: 1000, height: 1000), margin: 0)
        return min(max(map.fitAspect, 1.2), 2.4)
    }

    /// Title for the whole-region view used by "Click the country".
    static func regionTitle(for target: Country) -> String { target.region.title }

    /// Label on the map card for a practice or click scope.
    static func scopeTitle(_ scope: PracticeScope?, target: Country) -> String {
        switch scope {
        case .some(.world): return "World"
        case .some(.region(let r)): return r.title
        case .some(.custom(let countries)): return CustomSets.displayTitle(countries: countries)
        case .none: return regionTitle(for: target)
        }
    }

    /// The whole region at once, for "Click the country": all of Asia (Russia too),
    /// all of Africa with its islands, the usual Europe frame, all of North America
    /// (Central America and the Caribbean too) and all of South America.
    /// The view is the same for every country in a region, so it gives nothing away.
    static func regionPlan(for target: Country, world: [Country]) -> MapPlan {
        let inRegion = world.filter { $0.region == target.region }
        var boxes: [CGRect] = []
        switch target.region {
        case .europe:
            // Europe keeps its fixed frame.
            return plan(for: inRegion.first { $0.quizzable } ?? target, world: world)
        case .africa:
            boxes = [africaBox] + inRegion.filter { farIslands.contains($0.name) }.map { $0.focusBounds }
        case .asia:
            // Every Asian country, Russia included, so nothing is cut off.
            boxes = inRegion.filter { $0.quizzable }.map { $0.focusBounds } + russiaExtras
        case .northAmerica:
            // The countries clipped to a fixed frame (Alaska and the far Arctic cut off).
            // The map itself is cut with a straight edge at the Yukon and Alaska border,
            // so Alaska never shows in the margin.
            let frame = clickFrames[.northAmerica]!
            boxes = inRegion.filter { $0.quizzable }
                .map { $0.focusBounds.intersection(frame) }
                .filter { !$0.isNull && !$0.isEmpty }
            return MapPlan(projection: GeoProjection.miller(lon0: centerLon(boxes), clipWestLon: Double(frame.minX)), fit: boxes)
        case .southAmerica:
            // Tight on the continent plus the Falklands. Only South America is drawn.
            boxes = inRegion.filter { $0.quizzable || $0.name == "Falkland Islands" }.map { $0.focusBounds }
        }
        if boxes.isEmpty { return plan(for: target, world: world) }
        return MapPlan(projection: GeoProjection.miller(lon0: centerLon(boxes)), fit: boxes)
    }

    /// Flat Miller view of every included country (no Oceania in the data). Used for
    /// Whole world practice tests. Russia extras keep Chukotka and Kaliningrad on screen.
    static func worldPlan(world: [Country]) -> MapPlan {
        var boxes = world.filter { $0.quizzable }.map { $0.focusBounds }
        boxes += russiaExtras
        if boxes.isEmpty {
            boxes = [CGRect(x: -170, y: -55, width: 340, height: 130)]
        }
        return MapPlan(projection: GeoProjection.miller(lon0: centerLon(boxes)), fit: boxes)
    }

    /// Flat view fitted to the chosen countries. Neighbors still draw, dimmed, outside the quiz.
    static func customPlan(countries: [String], world: [Country]) -> MapPlan {
        let chosen = Set(countries)
        var boxes = world.filter { chosen.contains($0.name) }.map { $0.focusBounds }
        if chosen.contains("Russia") { boxes += russiaExtras }
        if boxes.isEmpty { return worldPlan(world: world) }
        return MapPlan(projection: GeoProjection.miller(lon0: centerLon(boxes)), fit: boxes)
    }

    static func clickAspect(scope: PracticeScope, world: [Country]) -> Double {
        switch scope {
        case .world: return 2.0
        case .region(let region):
            guard let sample = world.first(where: { $0.quizzable && $0.region == region }) else { return 1.6 }
            return clickAspect(for: sample, world: world)
        case .custom(let countries):
            let plan = customPlan(countries: countries, world: world)
            let map = FittedMap(projection: plan.projection, fit: plan.fit, size: CGSize(width: 1000, height: 1000), margin: 0)
            return min(max(map.fitAspect, 1.2), 2.4)
        }
    }

    /// Plan for a practice scope: one continent, the whole world, or a custom list.
    static func scopePlan(_ scope: PracticeScope, target: Country, world: [Country]) -> MapPlan {
        switch scope {
        case .world: return worldPlan(world: world)
        case .region:
            return regionPlan(for: target, world: world)
        case .custom(let countries):
            return customPlan(countries: countries, world: world)
        }
    }

}

/// What to show for one question: the projection and the lon/lat boxes to fit.
struct MapPlan: Sendable {
    let projection: GeoProjection
    let fit: [CGRect]
}

/// Projects longitude / latitude (degrees) to flat x / y with y pointing down.
/// Miller cylindrical: x = longitude, y = 1.25 * ln(tan(45 deg + 0.4 * latitude)), in radians.
struct GeoProjection: Sendable {
    /// Center longitude. Longitudes are measured from here (wrapped to -180...180), so a
    /// region that crosses 180 degrees, like Russia's Chukotka, is not split across the map.
    let lon0: Double

    private static let rad = Double.pi / 180
    /// Longitude (degrees) west of which nothing is drawn or clicked. Used to cut Alaska off
    /// the North America click map with a straight edge. Nil means no cut.
    var clipWestLon: Double? = nil

    private static let maxLat = 89.0

    static func miller(lon0: Double, clipWestLon: Double? = nil) -> GeoProjection {
        GeoProjection(lon0: lon0, clipWestLon: clipWestLon)
    }

    /// Projected x of the west cut, if there is one.
    var clipWestX: Double? {
        clipWestLon.map { GeoProjection.wrap($0 - lon0) * GeoProjection.rad }
    }

    private static func wrap(_ degrees: Double) -> Double {
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    /// Projects one point. `previousDelta` keeps a ring continuous across the back meridian
    /// so shapes never jump across the map.
    func project(lon: Double, lat: Double, previousDelta: inout Double?) -> CGPoint {
        var dl = GeoProjection.wrap(lon - lon0)
        if let prev = previousDelta {
            while dl - prev > 180 { dl -= 360 }
            while dl - prev < -180 { dl += 360 }
        }
        previousDelta = dl
        let phi = min(max(lat, -GeoProjection.maxLat), GeoProjection.maxLat) * GeoProjection.rad
        let x = dl * GeoProjection.rad
        let y = -1.25 * log(tan(Double.pi / 4 + 0.4 * phi))
        return CGPoint(x: x, y: y)
    }

    /// Projects a ring.
    func project(ring: [CGPoint]) -> [CGPoint] {
        var prev: Double? = nil
        return ring.map { project(lon: Double($0.x), lat: Double($0.y), previousDelta: &prev) }
    }
}

/// Fits projected shapes into a view of a given size.
struct FittedMap {
    let projection: GeoProjection
    let scale: Double
    let offsetX: Double
    let offsetY: Double
    /// Width / height of the fitted area before scaling (projected units).
    let fitAspect: Double

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
                    let p = projection.project(lon: sLon, lat: sLat, previousDelta: &prev)
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
        fitAspect = (maxX - minX) / (maxY - minY)
        scale = min(w / (maxX - minX), h / (maxY - minY))
        offsetX = Double(size.width) / 2 - (minX + maxX) / 2 * scale
        offsetY = Double(size.height) / 2 - (minY + maxY) / 2 * scale
    }

    /// Cuts a ring at a vertical line, keeping the part east of it (Sutherland-Hodgman).
    static func clipWest(_ ring: [CGPoint], x cx: Double) -> [CGPoint] {
        guard var prev = ring.last else { return [] }
        var out: [CGPoint] = []
        for p in ring {
            let pin = Double(p.x) >= cx, qin = Double(prev.x) >= cx
            if pin != qin {
                let t = (cx - Double(prev.x)) / (Double(p.x) - Double(prev.x))
                out.append(CGPoint(x: cx, y: Double(prev.y) + t * (Double(p.y) - Double(prev.y))))
            }
            if pin { out.append(p) }
            prev = p
        }
        return out
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
                var projected = projection.project(ring: ring)
                if let cx = projection.clipWestX {
                    projected = FittedMap.clipWest(projected, x: cx)
                    // Outline cut away: drop the whole piece. A cut-away hole is just skipped.
                    if projected.count < 3 { if i == 0 { break } else { continue } }
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
