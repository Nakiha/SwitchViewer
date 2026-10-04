import Foundation

/// Apple backends; raw values preserve existing launch arguments.
public enum FrameInterpolationMode: Int, CaseIterable {
    case appleLowLatency = 4
    case appleProxy = 5
    public var label: String {
        switch self {
        case .appleLowLatency: return "直接插帧（仅 1080p）"
        case .appleProxy: return "缩放插帧（适配高分辨率）"
        }
    }
}
