import AVFoundation
import CoreImage
import Metal
import QuartzCore

/// Two variable-frame-rate movies on one content clock. Only confirmed output
/// frames are offered by callers. This is editing material, not a latency trace.
public final class ComparisonMovieRecorder {
    public enum Track: String, CaseIterable { case original, processed }
    public enum Event {
        case started(URL), finishing, finished(URL), failed(String)
    }
    private final class Movie {
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        var firstTime: Double?
        var lastTime = -Double.infinity
        var frames = 0
        var generated = 0
        var dropped = 0
        init(url: URL, width: Int, height: Int) throws {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width, AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 24_000_000,
                    AVVideoAllowFrameReorderingKey: false,
                    AVVideoExpectedSourceFrameRateKey: 120],
                AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]])
            input.expectsMediaDataInRealTime = true
            adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                    kCVPixelBufferMetalCompatibilityKey as String: true,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
            guard writer.canAdd(input) else { throw RecorderError.message("无法建立视频编码器") }
            writer.add(input)
            guard writer.startWriting() else { throw writer.error ?? RecorderError.message("无法开始写入视频") }
            writer.startSession(atSourceTime: .zero)
        }
    }
    private enum RecorderError: Error, LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }
    private let queue = DispatchQueue(label: "switchviewer.comparison-recording", qos: .utility)
    private let lock = NSLock()
    private var stopRequested = false
    private var accepting = false
    private var busy = false
    private var pending = 0
    private var overload: [Track: Int] = [:]
    private var origin = 0.0
    private var maximumDuration = 30.0
    // Queue confined below this line.
    private var movies: [Track: Movie] = [:]
    private var directory: URL?
    private var timer: DispatchSourceTimer?
    private var width = 1920
    private var height = 1080
    private let context: CIContext
    private let colorSpace = CGColorSpace(name: CGColorSpace.itur_709)!
    private let onEvent: (Event) -> Void

    public init(onEvent: @escaping (Event) -> Void) {
        self.onEvent = onEvent
        if let device = MTLCreateSystemDefaultDevice() { context = CIContext(mtlDevice: device) }
        else { context = CIContext() }
    }
    public var isBusy: Bool { lock.lock(); defer { lock.unlock() }; return busy }
    public var isRecording: Bool { lock.lock(); defer { lock.unlock() }; return accepting }

    /// The sandboxed game uses its own writable Movies directory. The launcher
    /// learns the actual location through the inherited log, never guesses it.
    public static func recordingsDirectory() -> URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Movies/SwitchViewer", isDirectory: true)
    }
    public func start(root: URL = ComparisonMovieRecorder.recordingsDirectory(),
                      duration: Double = 30, width: Int = 1920, height: Int = 1080,
                      hostTime: Double = CACurrentMediaTime()) {
        guard duration.isFinite, duration > 0, hostTime.isFinite,
              width > 0, height > 0, width % 2 == 0, height % 2 == 0 else {
            onEvent(.failed("录制参数无效")); return
        }
        lock.lock()
        guard !busy else { lock.unlock(); return }
        busy = true
        accepting = false
        stopRequested = false
        overload = [:]
        origin = hostTime
        maximumDuration = min(30, duration)
        lock.unlock()
        queue.async { [self] in
            do {
                self.width = width; self.height = height
                let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                directory = folder
                for track in Track.allCases {
                    movies[track] = try Movie(url: folder.appendingPathComponent(track.rawValue + ".mov"), width: width, height: height)
                }
                try writeManifest(state: "recording", duration: 0)
                lock.lock(); accepting = !stopRequested; lock.unlock()
                onEvent(.started(folder))
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + min(30, duration))
                timer.setEventHandler { [weak self] in self?.stop() }
                self.timer = timer
                timer.resume()
            } catch { abort(error.localizedDescription) }
        }
    }
    public func append(_ buffer: CVPixelBuffer, track: Track, hostTime: Double,
                       generated: Bool = false, referenceAspect: Double? = nil) {
        lock.lock()
        let time = hostTime - origin
        guard accepting, time.isFinite, time >= 0, time < maximumDuration else { lock.unlock(); return }
        guard pending < 8 else {
            overload[track, default: 0] += 1; lock.unlock(); return
        }
        pending += 1
        // Enqueue under the same lock as stop so every accepted frame drains
        // before finalization. Retaining CV buffers prevents pool reuse.
        queue.async { [self] in
            defer { lock.lock(); pending -= 1; lock.unlock() }
            autoreleasepool {
                guard let movie = movies[track] else { return }
                guard movie.writer.status == .writing else { abort(movie.writer.error?.localizedDescription ?? "视频写入失败"); return }
                guard time > movie.lastTime, movie.input.isReadyForMoreMediaData else { movie.dropped += 1; return }
                var output: CVPixelBuffer?
                guard let pool = movie.adaptor.pixelBufferPool,
                      CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool,
                        [kCVPixelBufferPoolAllocationThresholdKey: 8] as CFDictionary, &output) == kCVReturnSuccess,
                      let output else { movie.dropped += 1; return }
                let image = CIImage(cvPixelBuffer: buffer)
                let aspect = referenceAspect.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
                    ?? image.extent.width / image.extent.height
                let fittedHeight = min(Double(height), Double(width) / aspect)
                let fittedWidth = fittedHeight * aspect
                let fitted = image.transformed(by: CGAffineTransform(scaleX: fittedWidth / image.extent.width,
                    y: fittedHeight / image.extent.height)).transformed(by: CGAffineTransform(
                        translationX: (Double(width) - fittedWidth) / 2, y: (Double(height) - fittedHeight) / 2))
                let bounds = CGRect(x: 0, y: 0, width: width, height: height)
                let black = CIImage(color: .black).cropped(to: bounds)
                context.render(fitted.composited(over: black), to: output, bounds: bounds, colorSpace: colorSpace)
                if movie.adaptor.append(output, withPresentationTime: CMTime(seconds: time, preferredTimescale: 600_000)) {
                    if movie.firstTime == nil { movie.firstTime = time }
                    movie.lastTime = time; movie.frames += 1
                    if generated { movie.generated += 1 }
                } else if movie.writer.status == .failed { abort(movie.writer.error?.localizedDescription ?? "视频写入失败") }
                else { movie.dropped += 1 }
            }
        }
        lock.unlock()
    }
    public func stop(hostTime: Double = CACurrentMediaTime()) {
        lock.lock()
        guard busy else { lock.unlock(); return }
        stopRequested = true
        accepting = false
        let end = min(maximumDuration, max(0, hostTime - origin))
        queue.async { [self] in finish(duration: end) }
        lock.unlock()
    }
    private var finishing = false
    private func finish(duration: Double) {
        guard !finishing, !movies.isEmpty else { return }
        finishing = true
        timer?.cancel(); timer = nil
        onEvent(.finishing)
        let group = DispatchGroup()
        for movie in movies.values {
            guard movie.writer.status == .writing else { continue }
            guard movie.frames > 0 else { movie.writer.cancelWriting(); continue }
            let end = max(duration, movie.lastTime + 1.0 / 120)
            movie.writer.endSession(atSourceTime: CMTime(seconds: end, preferredTimescale: 600_000))
            movie.input.markAsFinished()
            group.enter()
            movie.writer.finishWriting { group.leave() }
        }
        group.notify(queue: queue) { [self] in
            do {
                let valid = movies.values.allSatisfy { $0.writer.status == .completed && $0.frames > 0 }
                    && (movies[.processed]?.generated ?? 0) > 0
                try writeManifest(state: valid ? "completed" : "incomplete", duration: duration)
                let folder = directory!
                let failure = movies.values.compactMap { $0.writer.error?.localizedDescription }.first
                clear()
                onEvent(valid ? .finished(folder) : .failed(failure ?? "未录到完整的两路画面或生成帧，请开启插帧并保持画面运行后再录制"))
            } catch { abort(error.localizedDescription) }
        }
    }
    private func writeManifest(state: String, duration: Double) throws {
        guard let directory else { return }
        lock.lock(); let overload = self.overload; let origin = self.origin; lock.unlock()
        let tracks = Dictionary(uniqueKeysWithValues: movies.map { key, movie in
            (key.rawValue, ["frames": movie.frames, "generatedFrames": movie.generated,
                "droppedByRecorder": movie.dropped + (overload[key] ?? 0)])
        })
        let manifest: [String: Any] = ["schema": 1, "state": state, "hostTimeOrigin": origin,
            "durationSeconds": duration, "width": width, "height": height, "audio": false,
            "timeline": "shared source-content host clock; variable frame rate; processed frames confirmed presented",
            "limitations": "frame buffers before final display shader; excludes UI, display pacing and latency; recording adds load",
            "tracks": tracks,
            "firstContentTimeSeconds": Dictionary(uniqueKeysWithValues: movies.compactMap { key, movie in
                movie.firstTime.map { (key.rawValue, $0) }
            })]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("recording.json"), options: .atomic)
    }
    private func abort(_ message: String) {
        for movie in movies.values { if movie.writer.status == .writing { movie.writer.cancelWriting() } }
        try? writeManifest(state: "failed", duration: 0)
        clear()
        onEvent(.failed(message))
    }
    private func clear() {
        timer?.cancel(); timer = nil
        movies = [:]; directory = nil; finishing = false
        lock.lock(); accepting = false; busy = false; lock.unlock()
    }
}
