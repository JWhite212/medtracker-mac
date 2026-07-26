// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MedTrackerSync",
    platforms: [.macOS(.v15)],
    products: [.library(name: "MedTrackerSync", targets: ["MedTrackerSync"])],
    dependencies: [
        .package(path: "../MedTrackerData"),
        .package(path: "../MedTrackerCore"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "MedTrackerSync",
            dependencies: [
                "MedTrackerData",
                "MedTrackerCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MedTrackerSyncTests",
            dependencies: [
                "MedTrackerSync",
                "MedTrackerData",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
