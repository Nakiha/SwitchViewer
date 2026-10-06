import Cocoa
import AVFoundation
import CoreImage
import CoreMedia
import IOKit.pwr_mgt
import Metal
import VideoToolbox
import simd
import SwitchViewerInterpolation

final class RollingDiagnosticsLog {
    private let queue = DispatchQueue(label: "switchviewer.diagnostics-log")
    let directoryURL: URL
    private let fileURL: URL
    private let maxFileBytes = 2 * 1024 * 1024
    private let archiveCount = 5

    init() {
        // SWITCHVIEWER_LOG_DIR 覆盖日志目录；沙箱内运行或想把日志放到别处时用。
        if let override = ProcessInfo.processInfo.environment["SWITCHVIEWER_LOG_DIR"],
           !override.isEmpty {
            directoryURL = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library", isDirectory: true)
            directoryURL = library.appendingPathComponent("Logs/SwitchViewer", isDirectory: true)
        }
        fileURL = directoryURL.appendingPathComponent("switchviewer.log")
    }

    func append(_ message: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS ZZZZZ"
            let line = "[\(formatter.string(from: Date()))] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            do {
                try FileManager.default.createDirectory(at: self.directoryURL,
                                                        withIntermediateDirectories: true)
                try self.rotateIfNeeded(incomingBytes: data.count)
                if FileManager.default.fileExists(atPath: self.fileURL.path) {
                    let handle = try FileHandle(forWritingTo: self.fileURL)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } else {
                    try data.write(to: self.fileURL, options: .atomic)
                }
            } catch {
                NSLog("SwitchViewer diagnostic log write failed: %@", error.localizedDescription)
            }
        }
    }

    func flush() {
        queue.sync {}
    }

    private func archiveURL(_ index: Int) -> URL {
        directoryURL.appendingPathComponent("switchviewer.\(index).log")
    }

    private func rotateIfNeeded(incomingBytes: Int) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path),
              let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
              let size = (attrs[.size] as? NSNumber)?.intValue,
              size + incomingBytes > maxFileBytes else { return }

        let oldest = archiveURL(archiveCount)
        if fm.fileExists(atPath: oldest.path) { try fm.removeItem(at: oldest) }
        if archiveCount > 1 {
            for index in stride(from: archiveCount - 1, through: 1, by: -1) {
                let source = archiveURL(index)
                let destination = archiveURL(index + 1)
                if fm.fileExists(atPath: source.path) {
                    if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                    try fm.moveItem(at: source, to: destination)
                }
            }
        }
        try fm.moveItem(at: fileURL, to: archiveURL(1))
    }
}

typealias FrameInterpolationCompletion = (CVPixelBuffer?, String?, TimeInterval?, InterpolationFramePosition?) -> Void

final class PresentationFrameTiming {
    enum Stage: Hashable {
        case processingReady
        case presentationEnqueued
        case presentationQueueStarted
        case drawableWaitStarted
        case drawableAcquired
        case commandBufferSubmitStarted
        case gpuCompleted
    }

    let captureCallbackHostTime: CFTimeInterval
    private let lock = NSLock()
    private var hostTimes: [Stage: CFTimeInterval]

    init(captureCallbackHostTime: CFTimeInterval,
         processingReadyHostTime: CFTimeInterval = presentationHostTimeNow()) {
        self.captureCallbackHostTime = captureCallbackHostTime
        hostTimes = [.processingReady: processingReadyHostTime]
    }

    func mark(_ stage: Stage, at hostTime: CFTimeInterval = presentationHostTimeNow()) {
        lock.lock()
        hostTimes[stage] = hostTime
        lock.unlock()
    }

    func milliseconds(from start: Stage, to end: Stage) -> Double? {
        lock.lock()
        let startTime = hostTimes[start]
        let endTime = hostTimes[end]
        lock.unlock()
        guard let startTime, let endTime, endTime >= startTime else { return nil }
        return (endTime - startTime) * 1_000
    }

    func milliseconds(from start: Stage, toHostTime endTime: CFTimeInterval) -> Double? {
        lock.lock()
        let startTime = hostTimes[start]
        lock.unlock()
        guard let startTime, endTime >= startTime else { return nil }
        return (endTime - startTime) * 1_000
    }

    func callbackToDisplayMilliseconds(_ presentedTime: CFTimeInterval) -> Double? {
        guard presentedTime.isFinite, presentedTime > captureCallbackHostTime else { return nil }
        return (presentedTime - captureCallbackHostTime) * 1_000
    }

    func callbackToReadyMilliseconds() -> Double? {
        guard let readyTime = timestamp(.processingReady),
              readyTime >= captureCallbackHostTime else { return nil }
        return (readyTime - captureCallbackHostTime) * 1_000
    }

    private func timestamp(_ stage: Stage) -> CFTimeInterval? {
        lock.lock()
        let value = hostTimes[stage]
        lock.unlock()
        return value
    }
}

final class CaptureDisplayAwakeAssertion {
    private let lock = NSLock()
    private var assertionID: IOPMAssertionID = 0

    func setEnabled(_ enabled: Bool) -> (changed: Bool, result: IOReturn) {
        lock.lock()
        defer { lock.unlock() }

        if enabled {
            guard assertionID == 0 else { return (false, kIOReturnSuccess) }
            var newAssertionID: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "SwitchViewer 正在采集视频" as CFString,
                &newAssertionID)
            if result == kIOReturnSuccess { assertionID = newAssertionID }
            return (result == kIOReturnSuccess, result)
        }

        guard assertionID != 0 else { return (false, kIOReturnSuccess) }
        let result = IOPMAssertionRelease(assertionID)
        if result == kIOReturnSuccess { assertionID = 0 }
        return (result == kIOReturnSuccess, result)
    }

    deinit {
        if assertionID != 0 { IOPMAssertionRelease(assertionID) }
    }
}

