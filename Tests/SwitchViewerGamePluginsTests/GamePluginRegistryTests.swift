import Foundation
import XCTest
@testable import SwitchViewerGamePlugins

final class GamePluginRegistryTests: XCTestCase {
    private let registry = GamePluginRegistry.builtIn

    func testRenamedWuwaIsMatchedByBundleIdentity() {
        let app = GameApplication(bundleIdentifier: "com.kurogame.mingchao", url: URL(fileURLWithPath: "/Games/Renamed.app"))
        XCTAssertEqual(registry.plugin(for: app).descriptor.id, "wuthering-waves")
    }

    func testUnrelatedAppNamedWuwaUsesGenericAdapter() {
        let app = GameApplication(bundleIdentifier: "example.other", url: URL(fileURLWithPath: "/Applications/鸣潮.app"))
        XCTAssertEqual(registry.plugin(for: app).descriptor.id, "generic-metal")
    }

    func testUnknownPluginIDNeverSilentlyFallsBack() {
        XCTAssertNil(registry.plugin(id: "removed-plugin"))
        XCTAssertEqual(registry.plugin(id: "generic-metal")?.descriptor.id, "generic-metal")
    }

    func testDiscoveryFallsBackToBundleResolverAndRejectsMissingExecutable() {
        let moved = URL(fileURLWithPath: "/Games/Renamed.app")
        let plugin = WutheringWavesPlugin()
        let found = registry.installedApplication(for: plugin, isExecutableApplication: { $0 == moved },
            applicationForIdentifier: { $0 == "com.kurogame.mingchao" ? moved : nil })
        XCTAssertEqual(found, moved)
        XCTAssertNil(registry.installedApplication(for: plugin, isExecutableApplication: { _ in false },
            applicationForIdentifier: { _ in moved }))
    }

    func testSurfacePolicyRejectsOverlayHDRSmallAndInvalidSurfaces() {
        let plugin = WutheringWavesPlugin()
        for format: UInt in [80, 81] {
            XCTAssertTrue(plugin.acceptsSurface(.init(width: 1920, height: 1080, pixelFormat: format, layerName: nil)))
        }
        XCTAssertFalse(plugin.acceptsSurface(.init(width: 1920, height: 1080, pixelFormat: 80, layerName: "SwitchViewer.Interpolation")))
        XCTAssertFalse(plugin.acceptsSurface(.init(width: 1920, height: 1080, pixelFormat: 115, layerName: nil)))
        XCTAssertFalse(plugin.acceptsSurface(.init(width: 800, height: 600, pixelFormat: 80, layerName: nil)))
        XCTAssertFalse(plugin.acceptsSurface(.init(width: .nan, height: 1080, pixelFormat: 80, layerName: nil)))
        XCTAssertFalse(plugin.acceptsSurface(.init(width: .infinity, height: 1080, pixelFormat: 80, layerName: nil)))
    }

    func testNewAdapterCanChangeSurfacePolicyWithoutChangingCore() {
        struct SmallGamePlugin: GameIntegrationPlugin {
            let descriptor = GamePluginDescriptor(id: "small-game", name: "Small", bundleIdentifiers: ["example.small"])
            func acceptsSurface(_ surface: GameSurface) -> Bool { surface.width == 800 && surface.height == 600 }
        }
        let extended = GamePluginRegistry(plugins: [SmallGamePlugin(), WutheringWavesPlugin()])
        let app = GameApplication(bundleIdentifier: "example.small", url: URL(fileURLWithPath: "/Games/Small.app"))
        let plugin = extended.plugin(for: app)
        XCTAssertEqual(plugin.descriptor.id, "small-game")
        XCTAssertTrue(plugin.acceptsSurface(.init(width: 800, height: 600, pixelFormat: 80, layerName: nil)))
        XCTAssertEqual(extended.plugin(for: .init(bundleIdentifier: nil, url: app.url)).descriptor.id, "generic-metal")
    }
}
