// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MedTrackerData",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MedTrackerData", targets: ["MedTrackerData"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(path: "../MedTrackerCore"),
    ],
    targets: [
        .target(
            name: "MedTrackerData",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                "MedTrackerCore",
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MedTrackerDataTests",
            dependencies: ["MedTrackerData"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
