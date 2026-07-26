// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MedTrackerCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "MedTrackerCore", targets: ["MedTrackerCore"])],
    targets: [
        .target(name: "MedTrackerCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "MedTrackerCoreTests", dependencies: ["MedTrackerCore"],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
