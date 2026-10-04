import AppKit
import CoreMedia
import CoreVideo
import GameMetalHook
import Metal
import QuartzCore
import SwitchViewerInterpolation

/// 每条日志都带单调时间（相对 hook 加载的 +秒）和本地墙钟。
/// 之前 hook 行没有时间戳，只能靠 ADAPT 的 elapsed 反推，误差到秒级。
///
/// 前缀必须保持 `[SwitchViewerHook]` 原样，时间戳放在它后面：启动器用
/// `line.contains("[SwitchViewerHook]")` 过滤日志，把时间戳塞进方括号里会让闭合
/// 括号消失，启动器一行都匹配不到，直接报"未收到插帧库响应"。
enum HookLog {
    private static let wallOffset = Date().timeIntervalSince1970 - CACurrentMediaTime()
        + Double(TimeZone.current.secondsFromGMT())
    private static let start = CACurrentMediaTime()

    static func stamp(_ now: Double = CACurrentMediaTime()) -> String {
        let wall = (now + wallOffset).truncatingRemainder(dividingBy: 86_400)
        let hours = Int(wall / 3_600)
        let minutes = Int(wall / 60) % 60
        let seconds = Int(wall) % 60
        let milliseconds = Int((wall - wall.rounded(.down)) * 1_000)
        return String(format: "%02d:%02d:%02d.%03d +%9.3f",
                      hours, minutes, seconds, milliseconds, now - start)
    }
}

func report(_ message: String) {
    // Inherited stderr works inside the game's sandbox; no shared container needed.
    fputs("[SwitchViewerHook] \(HookLog.stamp()) \(message)\n", stderr)
}

@_cdecl("SVGameHookStart")
public func startGameHook() {
    DispatchQueue.main.async {
        guard #available(macOS 26.0, *) else { report("ERROR 需要 macOS 26 或更新版本"); return }
        guard GameHookPluginRuntime.plugin != nil else {
            report("ERROR 未知游戏插件：\(GameHookPluginRuntime.selectedID)；已禁用捕获"); return
        }
        SVInstallMetalHooks()
        GameFrameTraceControl.observe(processID: ProcessInfo.processInfo.processIdentifier) { _, _, _, _, _ in
            DispatchQueue.main.async { GameInterpolator.shared.startFrameTrace() }
        }
        GameInterpolationControl.observe(processID: ProcessInfo.processInfo.processIdentifier) { _, _, _, _, _ in
            DispatchQueue.main.async { GameInterpolator.shared.toggleOriginalView() }
        }
        if ProcessInfo.processInfo.environment["SWITCHVIEWER_FRAME_TRACE"] == "1" {
            GameInterpolator.shared.startFrameTrace()
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 17,
               event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.option, .shift],
               !event.isARepeat {
                GameInterpolator.shared.startFrameTrace()
                return nil
            }
            if event.keyCode == 34,
               event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.option, .shift],
               !event.isARepeat {
                GameInterpolator.shared.toggleOriginalView()
                return nil
            }
            return event
        }
        report("LOADED pid=\(ProcessInfo.processInfo.processIdentifier) pipeline=prepared-pair-v24 plugin=\(GameHookPluginRuntime.selectedID) traceControl=darwin-v1 interpolationControl=darwin-v1 cadence=\(GameHookConfiguration().cadence.rawValue) 游戏内 Metal 插帧库已加载，等待画面")
    }
}

@_cdecl("SVGameHookPrepare")
public func prepareGameFrame(_ bufferPointer: UnsafeMutableRawPointer,
                             _ drawablePointer: UnsafeMutableRawPointer,
                             _ layerPointer: UnsafeMutableRawPointer,
                             _ nativeRequestTime: Double, _ nativePresentedTime: Double,
                             _ nativeCallbackTime: Double, _ nativeGPUTime: Double) -> UInt64 {
    guard #available(macOS 26.0, *) else { return 0 }
    let buffer = Unmanaged<AnyObject>.fromOpaque(bufferPointer).takeUnretainedValue() as! MTLCommandBuffer
    let drawable = Unmanaged<AnyObject>.fromOpaque(drawablePointer).takeUnretainedValue() as! CAMetalDrawable
    let layer = Unmanaged<AnyObject>.fromOpaque(layerPointer).takeUnretainedValue() as! CAMetalLayer
    return GameInterpolator.shared.capture(buffer: buffer, drawable: drawable, layer: layer,
                                    nativeRequestTime: nativeRequestTime, nativePresentedTime: nativePresentedTime,
                                    nativeCallbackTime: nativeCallbackTime, nativeGPUTime: nativeGPUTime)
}

@_cdecl("SVGameHookNativePresented")
public func recordNativeGamePresentation(_ captureID: UInt64, _ requested: Double,
                                         _ presented: Double, _ callback: Double) {
    guard #available(macOS 26.0, *) else { return }
    GameInterpolator.shared.recordNativePresentation(captureID: captureID, requested: requested,
                                                    presented: presented, callback: callback)
}

@_cdecl("SVGameHookCaptureFallback")
public func recordGameCaptureFallback(_ requested: Double, _ reason: UnsafePointer<CChar>?) {
    guard #available(macOS 26.0, *), let reason else { return }
    GameInterpolator.shared.recordCaptureFallback(requested: requested, reason: String(cString: reason))
}

@_cdecl("SVGameHookOverlayPresent")
public func overlayPresentRequest(_ sequence: UInt64, _ time: Double, _ requested: Double, _ mode: Int32) {
    if #available(macOS 26.0, *) {
        GameInterpolator.shared.overlayPresentRequest(sequence: sequence, time: time, requested: requested, mode: mode)
    }
}
