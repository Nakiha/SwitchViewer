// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwitchViewer",
    platforms: [.macOS(.v13)],
    products: [.library(name: "SwitchViewerGameHook", type: .dynamic, targets: ["SwitchViewerGameHook"])],
    targets: [
        .target(name: "GameMetalHook", linkerSettings: [.linkedFramework("Metal"), .linkedFramework("QuartzCore")]),
        .target(name: "SwitchViewerGamePlugins"),
        .target(name: "SwitchViewerGameHook", dependencies: ["GameMetalHook", "SwitchViewerInterpolation", "SwitchViewerGamePlugins"]),
        .executableTarget(name: "GameHookFixture"),
        .target(name: "SwitchViewerInterpolation"),
        .executableTarget(
            name: "SwitchViewer",
            dependencies: ["SwitchViewerInterpolation", "SwitchViewerGamePlugins"]
        ),
        .executableTarget(
            name: "FrameInterpolationLab",
            dependencies: ["SwitchViewerInterpolation"]
        ),
        .testTarget(name: "SwitchViewerInterpolationTests", dependencies: ["SwitchViewerInterpolation"]),
        .testTarget(name: "SwitchViewerGamePluginsTests", dependencies: ["SwitchViewerGamePlugins"])
    ]
)
