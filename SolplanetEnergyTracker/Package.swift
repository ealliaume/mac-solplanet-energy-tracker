// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SolplanetEnergyTracker",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", from: "0.57.0"),
    ],
    targets: [
        .target(
            name: "SolplanetEnergyTrackerLib",
            path: "Sources/SolplanetEnergyTracker",
            plugins: [.plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins")]
        ),
        .target(
            name: "AppIconKit",
            path: "Sources/AppIconKit",
            plugins: [.plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins")]
        ),
        .executableTarget(
            name: "SolplanetBatteryEnergyTracker",
            dependencies: ["SolplanetEnergyTrackerLib", "AppIconKit"],
            path: "Sources/App",
            plugins: [.plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins")]
        ),
        .executableTarget(
            name: "IconExporter",
            dependencies: ["AppIconKit"],
            path: "Sources/IconExporter",
            plugins: [.plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins")]
        ),
        .testTarget(
            name: "SolplanetEnergyTrackerTests",
            dependencies: ["SolplanetEnergyTrackerLib", "SolplanetBatteryEnergyTracker"],
            path: "Tests/SolplanetEnergyTrackerTests",
            resources: [.copy("Fixtures")],
            plugins: [.plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins")]
        ),
    ]
)
