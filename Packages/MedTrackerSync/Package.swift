// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MedTrackerSync",
    platforms: [.macOS(.v15)],
    products: [.library(name: "MedTrackerSync", targets: ["MedTrackerSync"])],
    dependencies: [
        .package(path: "../MedTrackerData"),
        .package(path: "../MedTrackerCore"),
    ],
    targets: [
        .target(
            name: "MedTrackerSync",
            dependencies: ["MedTrackerData", "MedTrackerCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MedTrackerSyncTests",
            dependencies: ["MedTrackerSync"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
