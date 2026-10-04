import Foundation

public struct WutheringWavesPlugin: GameIntegrationPlugin {
    public init() {}
    public let descriptor = GamePluginDescriptor(
        id: "wuthering-waves", name: "鸣潮",
        bundleIdentifiers: ["com.kurogame.mingchao"],
        applicationPaths: ["/Applications/鸣潮.app"],
        installationURLs: [
            URL(string: "macappstore://apps.apple.com/cn/app/id6450693428")!,
            URL(string: "https://apps.apple.com/cn/app/id6450693428?platform=mac")!
        ])
}
