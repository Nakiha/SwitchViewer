import QuartzCore
import SwitchViewerGamePlugins

/// Selected once at load time. An unknown explicit ID disables capture rather
/// than silently applying another game's adapter. Legacy launches use generic.
enum GameHookPluginRuntime {
    static let selectedID = ProcessInfo.processInfo.environment["SWITCHVIEWER_GAME_PLUGIN"] ?? "generic-metal"
    static let plugin = GamePluginRegistry.builtIn.plugin(id: selectedID)
}

@_cdecl("SVGameHookAcceptsLayer")
public func gameHookAcceptsLayer(_ pointer: UnsafeMutableRawPointer) -> Int32 {
    guard let plugin = GameHookPluginRuntime.plugin else { return 0 }
    let layer = Unmanaged<CAMetalLayer>.fromOpaque(pointer).takeUnretainedValue()
    // This ownership boundary must hold even for adapters overriding the policy.
    guard layer.name != "SwitchViewer.Interpolation" else { return 0 }
    let surface = GameSurface(width: layer.drawableSize.width, height: layer.drawableSize.height,
                              pixelFormat: layer.pixelFormat.rawValue, layerName: layer.name)
    return plugin.acceptsSurface(surface) ? 1 : 0
}
