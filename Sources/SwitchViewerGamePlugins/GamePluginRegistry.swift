import Foundation

public struct GamePluginRegistry {
    public static let builtIn = GamePluginRegistry(plugins: [WutheringWavesPlugin()])
    public let plugins: [any GameIntegrationPlugin]
    public let fallback = GenericMetalGamePlugin()

    public init(plugins: [any GameIntegrationPlugin]) {
        self.plugins = plugins
    }

    public func plugin(id: String) -> (any GameIntegrationPlugin)? {
        if id == fallback.descriptor.id { return fallback }
        return plugins.first { $0.descriptor.id == id }
    }

    public func plugin(for application: GameApplication) -> any GameIntegrationPlugin {
        plugins.first { $0.matches(application) } ?? fallback
    }

    /// Resolvers are supplied by the host, so unit tests need no installed game
    /// and this library does not depend on NSWorkspace or UI permissions.
    public func installedApplication(for plugin: any GameIntegrationPlugin,
                                     isExecutableApplication: (URL) -> Bool,
                                     applicationForIdentifier: (String) -> URL?) -> URL? {
        for path in plugin.descriptor.applicationPaths {
            let url = URL(fileURLWithPath: path)
            if isExecutableApplication(url) { return url }
        }
        for identifier in plugin.descriptor.bundleIdentifiers {
            if let url = applicationForIdentifier(identifier), isExecutableApplication(url) { return url }
        }
        return nil
    }
}
