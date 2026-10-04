import Foundation
import VideoToolbox

#if !targetEnvironment(simulator)
@available(macOS 26.0, iOS 26.0, *)
enum FrameProcessorSessionCleanup {
    static let queue = DispatchQueue(label: "switchviewer.frame-processor-cleanup", qos: .utility)

    static func end(_ processors: [VTFrameProcessor]) {
        // The last owner may be released while VideoToolbox disposes its completion
        // block. endSession synchronously drains that processor's private queue,
        // so neither ending nor releasing the processor may happen on that queue.
        queue.async {
            processors.forEach { $0.endSession() }
        }
    }
}
#endif
