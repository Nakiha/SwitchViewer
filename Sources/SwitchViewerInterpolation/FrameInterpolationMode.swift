import Foundation

/// Selectable interpolation strategies used by SwitchViewer's live capture path.
public enum FrameInterpolationMode: Int, CaseIterable {
    case opticalFlow
    case frameBlend
    case uiProtected
    case bidirectionalOpticalFlow
    case appleLowLatency
    /// Downsamples any input to the largest proxy Apple accepts (576p/720p/1080p),
    /// interpolates there, and lets the renderer scale the midpoint up to the
    /// drawable. Works for the 4K capture card and for screen capture alike.
    case appleProxy

    public var label: String {
        switch self {
        case .opticalFlow: return "标准光流（自研）"
        case .frameBlend: return "帧混合（可能有拖影）"
        case .uiProtected: return "静止区域保护（实验）"
        case .bidirectionalOpticalFlow: return "双向光流（实验）"
        case .appleLowLatency: return "Apple 低延迟插帧（仅 1080p）"
        case .appleProxy: return "Apple 低延迟插帧（代理缩放，细节软化）"
        }
    }
}
