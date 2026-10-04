import Cocoa
import AVFoundation
import CoreImage
import CoreMedia
import IOKit.pwr_mgt
import Metal
import VideoToolbox
import simd
import SwitchViewerInterpolation

enum VideoSourceKind: Equatable {
    case captureCard
    case screen
}

/// 命令行入口，用于脚本化启动与无人值守测试：
///   --screen-target=display:first | display:&lt;id&gt; | app:&lt;名称子串&gt; | title:&lt;标题子串&gt;
///   --request-screen-permission   启动时申请“屏幕录制”权限
///   --interpolation-mode=&lt;原始值或标签&gt;
///   --enable-interpolation        首个帧到达后自动开启插帧
///   --click-through               启动即开启鼠标穿透
struct LaunchOptions {
    var screenTarget: String?
    var requestScreenPermission = false
    var interpolationMode: FrameInterpolationMode?
    var enableInterpolation = false
    var clickThrough = false

    static func parse(_ arguments: [String]) -> LaunchOptions {
        var options = LaunchOptions()
        for argument in arguments.dropFirst() {
            switch argument {
            case "--request-screen-permission": options.requestScreenPermission = true
            case "--enable-interpolation": options.enableInterpolation = true
            case "--click-through": options.clickThrough = true
            default:
                if let value = value(of: "--screen-target=", in: argument) {
                    options.screenTarget = value
                } else if let value = value(of: "--interpolation-mode=", in: argument) {
                    options.interpolationMode = FrameInterpolationMode.allCases.first {
                        $0.label == value || String($0.rawValue) == value
                    }
                }
            }
        }
        return options
    }

    private static func value(of prefix: String, in argument: String) -> String? {
        guard argument.hasPrefix(prefix) else { return nil }
        let value = String(argument.dropFirst(prefix.count))
        return value.isEmpty ? nil : value
    }
}

