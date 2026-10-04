// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwitchViewer",
    platforms: [.macOS(.v13)],
    products: [.library(name: "SwitchViewerGameHook", type: .dynamic, targets: ["SwitchViewerGameHook"])],
    targets: [
        .target(name: "GameMetalHook", linkerSettings: [.linkedFramework("Metal"), .linkedFramework("QuartzCore")]),
        .target(name: "SwitchViewerGameHook", dependencies: ["GameMetalHook", "SwitchViewerInterpolation"]),
        .executableTarget(name: "GameHookFixture"),
        .target(name: "SwitchViewerInterpolation"),
        .executableTarget(
            name: "SwitchViewer",
            dependencies: ["SwitchViewerInterpolation"]
        ),
        .executableTarget(
            name: "FrameInterpolationLab",
            dependencies: ["SwitchViewerInterpolation"]
        ),
        .testTarget(name: "SwitchViewerInterpolationTests", dependencies: ["SwitchViewerInterpolation"])
    ]
)
