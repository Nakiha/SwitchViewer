import Foundation

/// Value-only descriptions keep discovery and game policy independent of AppKit
/// and the injection process. Neither matching nor discovery launches an app.
public struct GameApplication: Sendable {
    public let bundleIdentifier: String?
    public let url: URL

    public init(bundleIdentifier: String?, url: URL) {
        self.bundleIdentifier = bundleIdentifier
        self.url = url
    }
}

public struct GameSurface: Sendable {
    public let width: Double
    public let height: Double
    public let pixelFormat: UInt
    public let layerName: String?

    public init(width: Double, height: Double, pixelFormat: UInt, layerName: String?) {
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.layerName = layerName
    }
}

public struct GamePluginDescriptor: Sendable {
    public let id: String
    public let name: String
    public let bundleIdentifiers: [String]
    public let applicationPaths: [String]
    public let installationURLs: [URL]

    public init(id: String, name: String, bundleIdentifiers: [String] = [],
                applicationPaths: [String] = [], installationURLs: [URL] = []) {
        self.id = id
        self.name = name
        self.bundleIdentifiers = bundleIdentifiers
        self.applicationPaths = applicationPaths
        self.installationURLs = installationURLs
    }
}

/// A game adapter owns discovery and surface eligibility. Texture ownership,
/// frame ordering, interpolation and watchdogs stay in the shared hook core.
/// Implementations must be immutable: surface checks can run on game threads.
public protocol GameIntegrationPlugin: Sendable {
    var descriptor: GamePluginDescriptor { get }
    func matches(_ application: GameApplication) -> Bool
    func acceptsSurface(_ surface: GameSurface) -> Bool
}

public extension GameIntegrationPlugin {
    func matches(_ application: GameApplication) -> Bool {
        guard let identifier = application.bundleIdentifier else { return false }
        return descriptor.bundleIdentifiers.contains(identifier)
    }

    func acceptsSurface(_ surface: GameSurface) -> Bool {
        // Metal BGRA8Unorm / BGRA8Unorm_sRGB. Other formats have no validated
        // color conversion path. Always exclude our own output from recapture.
        surface.layerName != "SwitchViewer.Interpolation"
            && surface.width.isFinite && surface.height.isFinite
            && surface.width >= 1024 && surface.height >= 576
            && [UInt(80), UInt(81)].contains(surface.pixelFormat)
    }
}
