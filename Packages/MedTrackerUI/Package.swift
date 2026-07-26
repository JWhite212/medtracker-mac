// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MedTrackerUI",
    platforms: [.macOS(.v15)],
    products: [.library(name: "MedTrackerUI", targets: ["MedTrackerUI"])],
    dependencies: [
        .package(path: "../MedTrackerApp"),
        .package(path: "../MedTrackerCore"),
        .package(path: "../MedTrackerTestSupport"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.17.0"),
    ],
    targets: [
        .target(
            name: "MedTrackerUI",
            dependencies: ["MedTrackerApp", "MedTrackerCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MedTrackerUITests",
            dependencies: [
                "MedTrackerUI",
                "MedTrackerTestSupport",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            exclude: ["__Snapshots__"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
