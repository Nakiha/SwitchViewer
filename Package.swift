// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwitchViewer",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "SwitchViewerInterpolation"),
        .executableTarget(
            name: "SwitchViewer",
            dependencies: ["SwitchViewerInterpolation"]
        ),
        .executableTarget(
            name: "FrameInterpolationLab",
            dependencies: ["SwitchViewerInterpolation"]
        )
    ]
)
