import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The parts of the world you can turn on and off.
enum Region: String, CaseIterable, Codable, Hashable {
    case africa = "Africa"
    case asia = "Asia"
    case europe = "Europe"
    case northAmerica = "North America"
    case southAmerica = "South America"

    var title: String { rawValue }
}

/// One country (or territory) from the bundled map file.
/// Coordinates are plain longitude (x) and latitude (y) in degrees.
struct Country: Identifiable {
    let name: String
    let region: Region
    /// polygon -> rings (first ring is the outline, the rest are holes) -> points
    let polygons: [[[CGPoint]]]
    /// Whether this place shows up as a quiz question.
    let quizzable: Bool
    /// Box around every part of the country, in raw longitude and latitude (-180...180).
    let rawBounds: CGRect
    /// Box around the main parts of the country, used to center the map.
    /// Can reach past 180 degrees for places that cross the date line (Russia).
    let focusBounds: CGRect

    var id: String { name }
    var center: CGPoint { CGPoint(x: focusBounds.midX, y: focusBounds.midY) }
}

/// Places that are drawn on the map but never asked about,
/// because they are territories or not widely recognized countries.
let nonQuizPlaces: Set<String> = [
    "Somaliland",
    "Northern Cyprus",
    "Greenland",
    "Puerto Rico",
    "Falkland Islands",
    "Hong Kong",
    "Macao",
    "Siachen Glacier",
]

// MARK: - GeoJSON decoding

private struct FeatureCollectionDTO: Decodable {
    let features: [FeatureDTO]
}

private struct FeatureDTO: Decodable {
    let properties: PropertiesDTO
    let geometry: GeometryDTO?
}

private struct PropertiesDTO: Decodable {
    let name: String
    let continent: String
}

private struct GeometryDTO: Decodable {
    /// Always stored as a list of polygons, so Polygon and MultiPolygon look the same.
    let polygons: [[[[Double]]]]

    enum CodingKeys: String, CodingKey {
        case type
        case coordinates
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "Polygon":
            let one = try container.decode([[[Double]]].self, forKey: .coordinates)
            polygons = [one]
        case "MultiPolygon":
            polygons = try container.decode([[[[Double]]]].self, forKey: .coordinates)
        default:
            polygons = []
        }
    }
}

enum WorldLoader {
    /// Parses a GeoJSON FeatureCollection whose features have "name" and "continent" properties.
    static func parse(_ data: Data) throws -> [Country] {
        let collection = try JSONDecoder().decode(FeatureCollectionDTO.self, from: data)
        var result: [Country] = []
        result.reserveCapacity(collection.features.count)

        for feature in collection.features {
            guard let region = Region(rawValue: feature.properties.continent),
                  let geometry = feature.geometry else { continue }

            var polygons: [[[CGPoint]]] = []
            for polygon in geometry.polygons {
                var rings: [[CGPoint]] = []
                for ring in polygon {
                    var points: [CGPoint] = []
                    points.reserveCapacity(ring.count)
                    for pair in ring where pair.count >= 2 {
                        points.append(CGPoint(x: pair[0], y: pair[1]))
                    }
                    if points.count >= 3 { rings.append(points) }
                }
                if !rings.isEmpty { polygons.append(rings) }
            }
            if polygons.isEmpty { continue }

            let name = feature.properties.name
            result.append(Country(
                name: name,
                region: region,
                polygons: polygons,
                quizzable: !nonQuizPlaces.contains(name),
                rawBounds: boundsOfAll(polygons),
                focusBounds: focusBounds(polygons)
            ))
        }
        return result
    }

    // MARK: Bounds helpers

    static func bounds(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points {
            if p.x < minX { minX = p.x }
            if p.x > maxX { maxX = p.x }
            if p.y < minY { minY = p.y }
            if p.y > maxY { maxY = p.y }
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func boundsOfAll(_ polygons: [[[CGPoint]]]) -> CGRect {
        var box: CGRect? = nil
        for polygon in polygons {
            guard let outer = polygon.first else { continue }
            let b = bounds(of: outer)
            box = box.map { $0.union(b) } ?? b
        }
        return box ?? .zero
    }

    /// Area of a ring in square degrees (always positive).
    static func area(of ring: [CGPoint]) -> Double {
        guard ring.count >= 3 else { return 0 }
        var sum: Double = 0
        for i in 0..<ring.count {
            let a = ring[i]
            let b = ring[(i + 1) % ring.count]
            sum += Double(a.x * b.y - b.x * a.y)
        }
        return abs(sum) / 2
    }

    /// Box around the bigger pieces of a country (skips far away tiny islands like Hawaii
    /// for the US view) and handles the date line by shifting pieces by 360 degrees
    /// when that gives a tighter box.
    static func focusBounds(_ polygons: [[[CGPoint]]]) -> CGRect {
        var pieces: [(box: CGRect, area: Double)] = []
        for polygon in polygons {
            guard let outer = polygon.first else { continue }
            pieces.append((bounds(of: outer), area(of: outer)))
        }
        guard let largest = pieces.map({ $0.area }).max() else { return .zero }

        let main = pieces.filter { $0.area >= largest * 0.15 }.map { $0.box }
        let boxes = main.isEmpty ? pieces.map { $0.box } : main

        func union(_ list: [CGRect]) -> CGRect {
            var u = list[0]
            for b in list.dropFirst() { u = u.union(b) }
            return u
        }

        let plain = union(boxes)
        if plain.width <= 180 { return plain }

        // Try moving the western pieces east by 360 degrees.
        let shifted = boxes.map { $0.midX < 0 ? $0.offsetBy(dx: 360, dy: 0) : $0 }
        let shiftedBox = union(shifted)
        return shiftedBox.width < plain.width ? shiftedBox : plain
    }
}
