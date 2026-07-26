// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MedTrackerTestSupport",
    platforms: [.macOS(.v15)],
    products: [.library(name: "MedTrackerTestSupport", targets: ["MedTrackerTestSupport"])],
    dependencies: [
        .package(path: "../MedTrackerSync"),
        .package(path: "../MedTrackerData"),
        .package(path: "../MedTrackerCore"),
    ],
    targets: [
        .target(
            name: "MedTrackerTestSupport",
            dependencies: ["MedTrackerSync", "MedTrackerData", "MedTrackerCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MedTrackerTestSupportTests",
            dependencies: ["MedTrackerTestSupport"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
