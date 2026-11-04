// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MapLock",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "MapLock",
            path: "Sources/MapLock",
            resources: [
                .copy("Resources/countries.geojson")
            ]
        )
    ]
)
