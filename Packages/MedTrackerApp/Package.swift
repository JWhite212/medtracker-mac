// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MedTrackerApp",
    platforms: [.macOS(.v15)],
    products: [.library(name: "MedTrackerApp", targets: ["MedTrackerApp"])],
    dependencies: [
        .package(path: "../MedTrackerCore"),
        .package(path: "../MedTrackerData"),
        .package(path: "../MedTrackerSync"),
        .package(path: "../MedTrackerTestSupport"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "MedTrackerApp",
            dependencies: [
                "MedTrackerCore",
                "MedTrackerData",
                "MedTrackerSync",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]   // ⇒ SWIFT_STRICT_CONCURRENCY complete
        ),
        .testTarget(
            name: "MedTrackerAppTests",
            dependencies: [
                "MedTrackerApp",
                "MedTrackerTestSupport",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
