// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MapLock",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .executableTarget(
            name: "MapLock",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/MapLock",
            resources: [
                .copy("Resources/countries.geojson")
            ]
        )
    ]
)
