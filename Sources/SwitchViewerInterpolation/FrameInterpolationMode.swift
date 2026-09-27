import Foundation

/// Selectable interpolation strategies used by SwitchViewer's live capture path.
public enum FrameInterpolationMode: Int, CaseIterable {
    case opticalFlow
    case frameBlend
    case uiProtected
    case fastMotionBypass

    public var label: String {
        switch self {
        case .opticalFlow: return "标准光流"
        case .frameBlend: return "帧混合（可能有拖影）"
        case .uiProtected: return "静止区域保护（实验）"
        case .fastMotionBypass: return "快速运动跳过插帧（实验）"
        }
    }
}
