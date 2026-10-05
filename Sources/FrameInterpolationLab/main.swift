import CoreVideo
import CoreImage
import Foundation
import Metal
import SwitchViewerInterpolation
import AVFoundation
import ImageIO

private struct FrameSize {
    let width: Int
    let height: Int
    var label: String { "\(width)×\(height)" }
}

private func makePatternFrame(size: FrameSize, shift: Int) throws -> CVPixelBuffer {
    let format = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    let attributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: format,
        kCVPixelBufferWidthKey as String: size.width,
        kCVPixelBufferHeightKey as String: size.height,
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:]
    ]
    var result: CVPixelBuffer?
    let status = CVPixelBufferCreate(kCFAllocatorDefault, size.width, size.height,
                                     format, attributes as CFDictionary, &result)
    guard status == kCVReturnSuccess, let buffer = result else {
        throw NSError(domain: "FrameInterpolationLab", code: Int(status),
                      userInfo: [NSLocalizedDescriptionKey: "创建测试帧失败"])
    }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
          let uvBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else {
        throw NSError(domain: "FrameInterpolationLab", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "测试帧平面不可写"])
    }
    let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    let uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
    let blockWidth = min(384, size.width / 3)
    let blockHeight = min(320, size.height / 3)
    let originX = size.width / 2 - blockWidth / 2
    let originY = size.height / 2 - blockHeight / 2
    for y in 0..<size.height {
        let row = yBase.advanced(by: y * yStride).assumingMemoryBound(to: UInt8.self)
        for x in 0..<size.width {
            let localX = x - originX - shift
            let localY = y - originY
            if localX >= 0, localX < blockWidth, localY >= 0, localY < blockHeight {
                // Deterministic noise avoids periodic patterns that can confuse motion estimation.
                let cellX = UInt32(localX / 4)
                let cellY = UInt32(localY / 4)
                var hash = cellX &* 374_761_393 &+ cellY &* 668_265_263 &+ 0x9E37_79B9
                hash = (hash ^ (hash >> 13)) &* 1_274_126_177
                hash ^= hash >> 16
                row[x] = UInt8(48 + hash % 184)
            } else {
                row[x] = 16
            }
        }
    }
    for y in 0..<(size.height / 2) {
        memset(uvBase.advanced(by: y * uvStride), 128, uvStride)
    }
    return buffer
}

private func weightedCenterX(_ buffer: CVPixelBuffer, row: Int) -> Double? {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
    let width = CVPixelBufferGetWidth(buffer)
    let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    let pixels = base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self)
    var weightSum = 0.0
    var xSum = 0.0
    for x in 0..<width {
        let weight = Double(max(0, Int(pixels[x]) - 16))
        weightSum += weight
        xSum += Double(x) * weight
    }
    return weightSum > 0 ? xSum / weightSum : nil
}

private func meanAbsoluteError(_ actual: CVPixelBuffer, _ expected: CVPixelBuffer,
                              size: FrameSize) -> Double {
    CVPixelBufferLockBaseAddress(actual, .readOnly)
    CVPixelBufferLockBaseAddress(expected, .readOnly)
    defer {
        CVPixelBufferUnlockBaseAddress(expected, .readOnly)
        CVPixelBufferUnlockBaseAddress(actual, .readOnly)
    }
    guard let actualBase = CVPixelBufferGetBaseAddressOfPlane(actual, 0),
          let expectedBase = CVPixelBufferGetBaseAddressOfPlane(expected, 0) else { return .infinity }
    let actualStride = CVPixelBufferGetBytesPerRowOfPlane(actual, 0)
    let expectedStride = CVPixelBufferGetBytesPerRowOfPlane(expected, 0)
    let actualPixels = actualBase.assumingMemoryBound(to: UInt8.self)
    let expectedPixels = expectedBase.assumingMemoryBound(to: UInt8.self)
    let x0 = size.width / 2 - 220
    let x1 = size.width / 2 + 220
    let y0 = size.height / 2 - 180
    let y1 = size.height / 2 + 180
    var error = 0.0
    var count = 0
    for y in y0..<y1 {
        for x in x0..<x1 {
            let a = actualPixels[y * actualStride + x]
            let b = expectedPixels[y * expectedStride + x]
            error += Double(abs(Int(a) - Int(b)))
            count += 1
        }
    }
    return error / Double(max(1, count))
}

private func meanBlendError(_ first: CVPixelBuffer, _ second: CVPixelBuffer,
                            _ expected: CVPixelBuffer, size: FrameSize) -> Double {
    CVPixelBufferLockBaseAddress(first, .readOnly)
    CVPixelBufferLockBaseAddress(second, .readOnly)
    CVPixelBufferLockBaseAddress(expected, .readOnly)
    defer {
        CVPixelBufferUnlockBaseAddress(expected, .readOnly)
        CVPixelBufferUnlockBaseAddress(second, .readOnly)
        CVPixelBufferUnlockBaseAddress(first, .readOnly)
    }
    guard let firstBase = CVPixelBufferGetBaseAddressOfPlane(first, 0),
          let secondBase = CVPixelBufferGetBaseAddressOfPlane(second, 0),
          let expectedBase = CVPixelBufferGetBaseAddressOfPlane(expected, 0) else { return .infinity }
    let firstStride = CVPixelBufferGetBytesPerRowOfPlane(first, 0)
    let secondStride = CVPixelBufferGetBytesPerRowOfPlane(second, 0)
    let expectedStride = CVPixelBufferGetBytesPerRowOfPlane(expected, 0)
    let a = firstBase.assumingMemoryBound(to: UInt8.self)
    let b = secondBase.assumingMemoryBound(to: UInt8.self)
    let e = expectedBase.assumingMemoryBound(to: UInt8.self)
    let x0 = size.width / 2 - 220
    let x1 = size.width / 2 + 220
    let y0 = size.height / 2 - 180
    let y1 = size.height / 2 + 180
    var error = 0.0
    var count = 0
    for y in y0..<y1 {
        for x in x0..<x1 {
            let blend = (Int(a[y * firstStride + x]) + Int(b[y * secondStride + x])) / 2
            error += Double(abs(blend - Int(e[y * expectedStride + x])))
            count += 1
        }
    }
    return error / Double(max(1, count))
}

private func makeMixedCadenceFrame(index: Int, gameFPS: Int,
                                   width: Int = 960, height: Int = 540) throws -> CVPixelBuffer {
    let format = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    let attributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: format,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:]
    ]
    var output: CVPixelBuffer?
    let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format,
                                     attributes as CFDictionary, &output)
    guard status == kCVReturnSuccess, let buffer = output else {
        throw NSError(domain: "FrameInterpolationLab", code: Int(status),
                      userInfo: [NSLocalizedDescriptionKey: "创建混合帧率合成图失败"])
    }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
          let uvBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else {
        throw NSError(domain: "FrameInterpolationLab", code: 15,
                      userInfo: [NSLocalizedDescriptionKey: "混合帧率画面不可写"])
    }
    let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    let uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
    let gameTick = index * gameFPS / 60
    let gameShift = gameTick * 8
    for y in 0..<height {
        let row = yBase.advanced(by: y * yStride).assumingMemoryBound(to: UInt8.self)
        for x in 0..<width {
            if y < 70 {
                // Simulated 60 Hz console UI: a small indicator moves on every input frame.
                let markerX = (index * 11) % (width - 24)
                row[x] = (x >= markerX && x < markerX + 24 && y >= 20 && y < 42) ? 220 : 32
            } else {
                let localX = (x - gameShift) / 8
                let localY = y / 8
                var hash = UInt32(localX & 0xFFFF) &* 374_761_393
                    &+ UInt32(localY & 0xFFFF) &* 668_265_263 &+ 0x9E37_79B9
                hash = (hash ^ (hash >> 13)) &* 1_274_126_177
                hash ^= hash >> 16
                row[x] = UInt8(40 + hash % 190)
            }
        }
    }
    for y in 0..<(height / 2) {
        memset(uvBase.advanced(by: y * uvStride), 128, uvStride)
    }
    return buffer
}

private func runSyntheticCadenceTest(gameFPS: Int) throws {
    let detector = SwitchFrameCadenceDetector()
    var last: SwitchFrameCadenceDetector.Result?
    var warmupPassThroughs = 0
    var repeatedFrameSkips = 0
    var interpolationCalls = 0
    for index in 0..<48 {
        let frame = try makeMixedCadenceFrame(index: index, gameFPS: gameFPS)
        let result = detector.observe(frame, presentationTime: Double(index) / 60.0)
        if result.captureFPS == nil {
            warmupPassThroughs += 1
        } else if result.gameFPS != nil && result.repeatedGameFrame {
            repeatedFrameSkips += 1
            guard !result.shouldInterpolate else {
                throw NSError(domain: "FrameInterpolationLab", code: 17,
                              userInfo: [NSLocalizedDescriptionKey: "重复游戏帧被错误标记为需要插帧"])
            }
        } else if result.shouldInterpolate {
            interpolationCalls += 1
        }
        last = result
    }
    guard let result = last else { throw NSError(domain: "FrameInterpolationLab", code: 8) }
    let expectedRepeated = (47 * gameFPS / 60) == (46 * gameFPS / 60)
    print(String(format: "合成混合画面：输入 60fps，游戏 %dfps，UI 60fps → 检测游戏 %.1ffps，周期=%@，置信度 %.0f%%，重复槽位=%@",
                 gameFPS, result.gameFPS ?? 0,
                 result.cadencePeriod.map(String.init) ?? "未判定",
                 result.confidence * 100,
                 result.repeatedGameFrame ? "是" : "否"))
    print("策略计数：启动观察直通 \(warmupPassThroughs) 帧；跳过重复帧插帧 \(repeatedFrameSkips) 次；需要插帧 \(interpolationCalls) 次")
    guard abs((result.gameFPS ?? 0) - Double(gameFPS)) < 1,
          result.confidence >= 0.68,
          result.repeatedGameFrame == expectedRepeated,
          repeatedFrameSkips > 0,
          interpolationCalls > 0 else {
        throw NSError(domain: "FrameInterpolationLab", code: 9,
                      userInfo: [NSLocalizedDescriptionKey: "混合帧率检测没有通过"])
    }
}

private func runNative60CadenceTest() throws {
    let detector = SwitchFrameCadenceDetector()
    var result: SwitchFrameCadenceDetector.Result?
    for index in 0..<48 {
        let frame = try makeMixedCadenceFrame(index: index, gameFPS: 60)
        result = detector.observe(frame, presentationTime: Double(index) / 60.0)
    }
    guard let result, result.captureFPS != nil, result.gameFPS == nil, result.shouldInterpolate else {
        throw NSError(domain: "FrameInterpolationLab", code: 18,
                      userInfo: [NSLocalizedDescriptionKey: "原生 60fps 内容应在预热后继续进入正常插帧器"])
    }
    print("合成原生 60fps 混合画面：预热后没有误判重复节奏，继续正常插帧")
}

private func analyzeClip(_ path: String) throws {
    let url = URL(fileURLWithPath: path)
    let asset = AVURLAsset(url: url)
    guard let track = asset.tracks(withMediaType: .video).first else {
        throw NSError(domain: "FrameInterpolationLab", code: 10,
                      userInfo: [NSLocalizedDescriptionKey: "视频没有视频轨道"])
    }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    ])
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else {
        throw NSError(domain: "FrameInterpolationLab", code: 11,
                      userInfo: [NSLocalizedDescriptionKey: "无法解码视频轨道"])
    }
    reader.add(output)
    guard reader.startReading() else {
        throw reader.error ?? NSError(domain: "FrameInterpolationLab", code: 12)
    }
    let detector = SwitchFrameCadenceDetector()
    struct CaptureMetric: Decodable {
        let frame: Int
        let meanLumaDelta: Double
    }
    let metricsURL = url.deletingPathExtension().appendingPathExtension("json")
    let captureMetrics = (try? Data(contentsOf: metricsURL))
        .flatMap { try? JSONDecoder().decode([CaptureMetric].self, from: $0) }
    var frames = 0
    var classified = 0
    var repeated = 0
    var changed = 0
    var referenceMatches = 0
    var referenceComparisons = 0
    var latest: SwitchFrameCadenceDetector.Result?
    var cadenceTimings: [Double] = []
    while let sample = output.copyNextSampleBuffer(),
          let pixelBuffer = CMSampleBufferGetImageBuffer(sample) {
        let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
        let cadenceStart = ProcessInfo.processInfo.systemUptime
        let result = detector.observe(pixelBuffer, presentationTime: seconds)
        cadenceTimings.append((ProcessInfo.processInfo.systemUptime - cadenceStart) * 1_000)
        if result.gameFPS != nil {
            classified += 1
            if result.repeatedGameFrame { repeated += 1 } else { changed += 1 }
            if let metric = captureMetrics?.first(where: { $0.frame == frames }), frames > 0 {
                let referenceRepeats = metric.meanLumaDelta < 0.05
                if referenceRepeats == result.repeatedGameFrame { referenceMatches += 1 }
                referenceComparisons += 1
            }
        }
        latest = result
        frames += 1
    }
    guard reader.status == .completed else {
        throw reader.error ?? NSError(domain: "FrameInterpolationLab", code: 13,
                                      userInfo: [NSLocalizedDescriptionKey: "视频读取未完成"])
    }
    guard let result = latest else { throw NSError(domain: "FrameInterpolationLab", code: 14) }
    print("素材：\(path)")
    print("解码帧：\(frames)，连续分类成功的帧：\(classified)")
    print("分类槽位：游戏重复帧 \(repeated)，游戏更新帧 \(changed)")
    if referenceComparisons > 0 {
        print(String(format: "与采集原始 Y 平面指标对照：%d/%d 帧一致（%.1f%%）",
                     referenceMatches, referenceComparisons,
                     100 * Double(referenceMatches) / Double(referenceComparisons)))
    }
    print(String(format: "采集节奏：%.1fHz；检测游戏内容：%@；置信度：%.0f%%；运动区域覆盖：%.1f%%；当前帧是游戏重复帧：%@",
                 result.captureFPS ?? 0, result.gameFPS.map { String(format: "%.1fHz", $0) } ?? "未判定",
                 result.confidence * 100, result.repeatedMotionCoverage * 100,
                 result.repeatedGameFrame ? "是" : "否"))
    print("检测到的重复节奏：\(result.cadencePeriod.map(String.init) ?? "未判定") 个采集间隔为一周期")
    func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * fraction)) - 1))
        return sorted[index]
    }
    print(String(format: "逐帧节奏检测耗时：P50 %.2fms / P95 %.2fms（%d帧）",
                 percentile(cadenceTimings, 0.50), percentile(cadenceTimings, 0.95), cadenceTimings.count))
}

private func readClipFramePair(_ clipPath: String, previousFrameIndex: Int,
                               currentFrameIndex: Int) throws -> (CVPixelBuffer, CVPixelBuffer, CMTime, CMTime) {
    let url = URL(fileURLWithPath: clipPath)
    let asset = AVURLAsset(url: url)
    guard let track = asset.tracks(withMediaType: .video).first else {
        throw NSError(domain: "FrameInterpolationLab", code: 31,
                      userInfo: [NSLocalizedDescriptionKey: "采集样本没有视频轨道"])
    }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    ])
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else {
        throw NSError(domain: "FrameInterpolationLab", code: 32,
                      userInfo: [NSLocalizedDescriptionKey: "无法解码采集样本"])
    }
    reader.add(output)
    guard reader.startReading() else {
        throw reader.error ?? NSError(domain: "FrameInterpolationLab", code: 33)
    }

    var previous: CVPixelBuffer?
    var current: CVPixelBuffer?
    var previousTime = CMTime.invalid
    var currentTime = CMTime.invalid
    var frameIndex = 0
    while let sample = output.copyNextSampleBuffer() {
        if frameIndex == previousFrameIndex, let buffer = CMSampleBufferGetImageBuffer(sample) {
            previous = buffer
            previousTime = CMSampleBufferGetPresentationTimeStamp(sample)
        }
        if frameIndex == currentFrameIndex, let buffer = CMSampleBufferGetImageBuffer(sample) {
            current = buffer
            currentTime = CMSampleBufferGetPresentationTimeStamp(sample)
            break
        }
        frameIndex += 1
    }
    guard let previous, let current else {
        throw NSError(domain: "FrameInterpolationLab", code: 34,
                      userInfo: [NSLocalizedDescriptionKey: "样本中没有所选帧；可用 --apple-*-frames=上一帧,当前帧 调整帧号"])
    }
    return (previous, current, previousTime, currentTime)
}

private func runAppleTiledProbe(clipPath: String, previousFrameIndex: Int = 169,
                                currentFrameIndex: Int = 171,
                                sessionCount: Int = 4) throws {
    guard #available(macOS 26.0, *) else {
        throw NSError(domain: "FrameInterpolationLab", code: 30,
                      userInfo: [NSLocalizedDescriptionKey: "Apple 低延迟插帧需要 macOS 26 或更新版本"])
    }
    let (previous, current, previousTime, currentTime) = try readClipFramePair(
        clipPath, previousFrameIndex: previousFrameIndex, currentFrameIndex: currentFrameIndex)
    let width = CVPixelBufferGetWidth(current)
    let height = CVPixelBufferGetHeight(current)
    guard width == 3840, height == 2160 else {
        throw NSError(domain: "FrameInterpolationLab", code: 35,
                      userInfo: [NSLocalizedDescriptionKey: "分块探针要求 3840×2160 样本，实际为 \(width)×\(height)"])
    }

    let interpolator = try AppleTiledFrameInterpolator(width: width, height: height,
                                                       pixelFormat: CVPixelBufferGetPixelFormatType(current),
                                                       maxConcurrentSessions: sessionCount)
    print("VTFrameProcessor 会话依次启动耗时：" + interpolator.sessionStartMilliseconds.enumerated().map {
        String(format: "#%d %.1fms", $0.offset + 1, $0.element)
    }.joined(separator: "，"))
    let warmup = try interpolator.interpolate(previous: previous, current: current,
                                              previousPresentationTimeStamp: previousTime,
                                              currentPresentationTimeStamp: currentTime)
    let interval = CMTimeSubtract(currentTime, previousTime)
    var measuredRuns: [AppleTiledFrameInterpolator.Result] = []
    for run in 0..<5 {
        let offset = Int32((run + 1) * 2)
        let runPreviousTime = CMTimeAdd(previousTime, CMTimeMultiply(interval, multiplier: offset))
        let runCurrentTime = CMTimeAdd(currentTime, CMTimeMultiply(interval, multiplier: offset))
        measuredRuns.append(try interpolator.interpolate(previous: previous, current: current,
                                                         previousPresentationTimeStamp: runPreviousTime,
                                                         currentPresentationTimeStamp: runCurrentTime))
    }
    let measured = measuredRuns[measuredRuns.count - 1]
    func median(_ values: [Double]) -> Double {
        values.sorted()[values.count / 2]
    }
    print("Apple 分块插帧：\(width)×\(height) NV12，2×2 个 1920×1080 tiles，并行会话=\(measured.concurrentSessionCount)")
    print(String(format: "真实采集帧 %d→%d；首次耗时 %.1f ms；后续 5 次中位数 %.1f ms（准备 %.1f / Apple %.1f / 拼接 %.1f）；合成帧输出 %d×%d；tile 数=%d",
                 previousFrameIndex, currentFrameIndex,
                 warmup.processingMilliseconds,
                 median(measuredRuns.map(\.processingMilliseconds)),
                 median(measuredRuns.map(\.preparationMilliseconds)),
                 median(measuredRuns.map(\.processorMilliseconds)),
                 median(measuredRuns.map(\.stitchingMilliseconds)),
                 CVPixelBufferGetWidth(measured.pixelBuffer), CVPixelBufferGetHeight(measured.pixelBuffer),
                 measured.tileCount))
    print("五次处理分段（准备 / VideoToolbox 请求到回调阶段 / 拼接，ms）：" +
          measuredRuns.enumerated().map { index, result in
              String(format: "#%d %.1f / %.1f / %.1f", index + 1,
                     result.preparationMilliseconds, result.processorMilliseconds,
                     result.stitchingMilliseconds)
          }.joined(separator: "；"))
    print("最后一次各路请求时间线（起始偏移 / process 调用耗时 / 请求至回调耗时 / 回调偏移，ms；回调耗时不等于纯 GPU 执行时间）：")
    for timing in measured.tileTimings {
        print(String(format: "tile %d → session %d：%.2f / %.2f / %.2f / %.2f",
                     timing.tileIndex + 1, timing.processorIndex + 1,
                     timing.requestStartOffsetMilliseconds, timing.processCallMilliseconds,
                     timing.callbackLatencyMilliseconds, timing.completionOffsetMilliseconds))
    }
    func printSamples(_ buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let bufferWidth = CVPixelBufferGetWidth(buffer)
        let bufferHeight = CVPixelBufferGetHeight(buffer)
        for (name, x, y) in [("左上", bufferWidth / 4, bufferHeight / 4),
                             ("右上", bufferWidth * 3 / 4, bufferHeight / 4),
                             ("左下", bufferWidth / 4, bufferHeight * 3 / 4),
                             ("右下", bufferWidth * 3 / 4, bufferHeight * 3 / 4)] {
            let luma = yBase.advanced(by: y * yStride + x).assumingMemoryBound(to: UInt8.self).pointee
            let chroma = uvBase.advanced(by: (y / 2) * uvStride + x).assumingMemoryBound(to: UInt8.self)
            print("\(name)：Y=\(luma)，UV=\(chroma[0]),\(chroma[1])")
        }
    }
    print("合成帧四象限中心采样：")
    printSamples(measured.pixelBuffer)

    let imageURL = try writeProbeImage(measured.pixelBuffer,
                                       path: "/tmp/SwitchViewer-apple-tiled-midpoint.png")
    print("合成帧截图：\(imageURL.path)")
}

private func runAppleDownsampleProbe(clipPath: String, previousFrameIndex: Int = 169,
                                     currentFrameIndex: Int = 171) throws {
    guard #available(macOS 26.0, *) else {
        throw NSError(domain: "FrameInterpolationLab", code: 50,
                      userInfo: [NSLocalizedDescriptionKey: "Apple 低延迟插帧需要 macOS 26 或更新版本"])
    }
    let (previous, current, previousTime, currentTime) = try readClipFramePair(
        clipPath, previousFrameIndex: previousFrameIndex, currentFrameIndex: currentFrameIndex)
    let interpolator = try AppleDownsampledFrameInterpolator(
        width: CVPixelBufferGetWidth(current), height: CVPixelBufferGetHeight(current),
        pixelFormat: CVPixelBufferGetPixelFormatType(current))
    func interpolateSynchronously(previous: CVPixelBuffer, current: CVPixelBuffer,
                                  previousTime: CMTime, currentTime: CMTime) throws
        -> AppleDownsampledFrameInterpolator.Result {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var output: AppleDownsampledFrameInterpolator.Result?
        var processingError: Error?
        try interpolator.submit(previous: previous, current: current,
                                previousPresentationTimeStamp: previousTime,
                                currentPresentationTimeStamp: currentTime) { result, error in
            lock.lock()
            output = result
            processingError = error
            lock.unlock()
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 5) == .success else {
            throw NSError(domain: "FrameInterpolationLab", code: 51,
                          userInfo: [NSLocalizedDescriptionKey: "Apple 代理插帧探针超时"])
        }
        lock.lock()
        let result = output
        let error = processingError
        lock.unlock()
        if let error { throw error }
        guard let result else {
            throw NSError(domain: "FrameInterpolationLab", code: 52,
                          userInfo: [NSLocalizedDescriptionKey: "Apple 代理插帧没有生成结果"])
        }
        return result
    }

    let warmup = try interpolateSynchronously(previous: previous, current: current,
                                              previousTime: previousTime, currentTime: currentTime)
    let interval = CMTimeSubtract(currentTime, previousTime)
    var measuredRuns: [AppleDownsampledFrameInterpolator.Result] = []
    for run in 0..<5 {
        let offset = Int32((run + 1) * 2)
        measuredRuns.append(try interpolateSynchronously(
            previous: previous, current: current,
            previousTime: CMTimeAdd(previousTime, CMTimeMultiply(interval, multiplier: offset)),
            currentTime: CMTimeAdd(currentTime, CMTimeMultiply(interval, multiplier: offset))))
    }
    let measured = measuredRuns[measuredRuns.count - 1]
    func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
    print("Apple 全画面 1080p 代理插帧：Metal NV12 缩小与 Apple 插帧串入同一 command buffer，渲染器直接缩放插帧输出")
    print(String(format: "真实采集帧 %d→%d；首次 %.1f ms；后续 5 次中位数 %.1f ms（proxy 编码 CPU %.1f / command buffer GPU %.1f / commit 到完成 %.1f）；输出 %d×%d",
                 previousFrameIndex, currentFrameIndex, warmup.processingMilliseconds,
                 median(measuredRuns.map(\.processingMilliseconds)),
                 median(measuredRuns.map(\.proxyEncodeCPUMilliseconds)),
                 median(measuredRuns.map(\.commandBufferGPUExecutionMilliseconds)),
                 median(measuredRuns.map(\.commandBufferCommitToCompleteMilliseconds)),
                 measured.outputWidth, measured.outputHeight))
    func printColorRangeStats(_ label: String, _ buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let y = yBase.assumingMemoryBound(to: UInt8.self)
        let uv = uvBase.assumingMemoryBound(to: UInt8.self)
        var ySum = UInt64(0), uSum = UInt64(0), vSum = UInt64(0)
        for row in 0..<height {
            for column in 0..<width { ySum += UInt64(y[row * yStride + column]) }
        }
        for row in 0..<(height / 2) {
            for column in stride(from: 0, to: width, by: 2) {
                uSum += UInt64(uv[row * uvStride + column])
                vSum += UInt64(uv[row * uvStride + column + 1])
            }
        }
        let pixelCount = Double(width * height)
        print(String(format: "%@ 全帧均值：Y=%.1f U=%.1f V=%.1f",
                     label, Double(ySum) / pixelCount,
                     Double(uSum) / (pixelCount / 4), Double(vSum) / (pixelCount / 4)))
    }
    printColorRangeStats("原始4K", current)
    printColorRangeStats("代理插帧回4K", measured.pixelBuffer)
    let imageURL = try writeProbeImage(measured.pixelBuffer,
                                       path: "/tmp/SwitchViewer-apple-downsampled-4k-midpoint.png")
    let sourceURL = try writeProbeImage(current,
                                        path: "/tmp/SwitchViewer-apple-downsampled-source.png")
    print("合成帧截图：\(imageURL.path)")
    print("原始 4K 帧截图：\(sourceURL.path)")
}

private func writeProbeImage(_ buffer: CVPixelBuffer, path: String) throws -> URL {
    guard let device = MTLCreateSystemDefaultDevice() else {
        throw NSError(domain: "FrameInterpolationLab", code: 60,
                      userInfo: [NSLocalizedDescriptionKey: "没有 Metal GPU，不能导出探针画面"])
    }
    let context = CIContext(mtlDevice: device)
    let image = CIImage(cvPixelBuffer: buffer)
    guard let cgImage = context.createCGImage(image, from: image.extent) else {
        throw NSError(domain: "FrameInterpolationLab", code: 61,
                      userInfo: [NSLocalizedDescriptionKey: "无法将插帧结果转换为 PNG"])
    }
    let imageURL = URL(fileURLWithPath: path)
    guard let destination = CGImageDestinationCreateWithURL(imageURL as CFURL,
                                                             "public.png" as CFString, 1, nil) else {
        throw NSError(domain: "FrameInterpolationLab", code: 62,
                      userInfo: [NSLocalizedDescriptionKey: "创建 PNG 探针输出失败"])
    }
    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "FrameInterpolationLab", code: 63,
                      userInfo: [NSLocalizedDescriptionKey: "写入 PNG 探针输出失败"])
    }
    return imageURL
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    let arguments = Set(args)
    if let input = args.first(where: { $0.hasPrefix("--multiframe-replay=") }) {
        let path = String(input.split(separator: "=", maxSplits: 1).last!)
        let output = args.first(where: { $0.hasPrefix("--multiframe-output=") })?.split(separator: "=", maxSplits: 1).last.map(String.init) ?? "Artifacts/multiframe-replay.json"
        try runMultiFramePlayoutReplay(inputPath: path, outputPath: output)
        exit(0)
    }
    if let input = args.first(where: { $0.hasPrefix("--multiframe-probe=") }) {
        let path = String(input.split(separator: "=", maxSplits: 1).last!)
        let output = args.first(where: { $0.hasPrefix("--multiframe-output=") })?.split(separator: "=", maxSplits: 1).last.map(String.init) ?? "Artifacts/multiframe-probe.json"
        let samples = Int(args.first(where: { $0.hasPrefix("--multiframe-samples=") })?.split(separator: "=", maxSplits: 1).last ?? "90") ?? 90
        guard samples >= 10 && samples <= 500 else { throw NSError(domain: "MultiFrameProbe.SampleCount", code: samples) }
        let stride = Int(args.first(where: { $0.hasPrefix("--multiframe-stride=") })?.split(separator: "=", maxSplits: 1).last ?? "1") ?? 1
        guard stride >= 1 && stride <= 4 else { throw NSError(domain: "MultiFrameProbe.InputStride", code: stride) }
        try runMultiFrameProbe(clipPath: path, outputPath: output, sampleCount: samples, inputStride: stride)
        exit(0)
    }
    if let probeArgument = args.first(where: { $0.hasPrefix("--apple-downsample-probe=") }) {
        let path = String(probeArgument.split(separator: "=", maxSplits: 1).last ?? "")
        let framePair = args.first(where: { $0.hasPrefix("--apple-downsample-frames=") })?
            .split(separator: "=", maxSplits: 1).last.map(String.init) ?? "169,171"
        let pair = framePair.split(separator: ",").compactMap { Int($0) }
        guard pair.count == 2 else {
            throw NSError(domain: "FrameInterpolationLab", code: 64,
                          userInfo: [NSLocalizedDescriptionKey: "--apple-downsample-frames 格式应为 上一帧,当前帧"])
        }
        try runAppleDownsampleProbe(clipPath: path, previousFrameIndex: pair[0], currentFrameIndex: pair[1])
        exit(0)
    }
    if let probeArgument = args.first(where: { $0.hasPrefix("--apple-tiled-probe=") }) {
        let path = String(probeArgument.split(separator: "=", maxSplits: 1).last ?? "")
        let framePair = args.first(where: { $0.hasPrefix("--apple-tiled-frames=") })?
            .split(separator: "=", maxSplits: 1).last.map(String.init) ?? "169,171"
        let sessions = Int(args.first(where: { $0.hasPrefix("--apple-tiled-sessions=") })?
            .split(separator: "=", maxSplits: 1).last ?? "4") ?? 4
        let pair = framePair.split(separator: ",").compactMap { Int($0) }
        guard pair.count == 2 else {
            throw NSError(domain: "FrameInterpolationLab", code: 40,
                          userInfo: [NSLocalizedDescriptionKey: "--apple-tiled-frames 格式应为 上一帧,当前帧"])
        }
        try runAppleTiledProbe(clipPath: path, previousFrameIndex: pair[0],
                               currentFrameIndex: pair[1], sessionCount: sessions)
        exit(0)
    }
    if let clipArgument = args.first(where: { $0.hasPrefix("--analyze-clip=") }) {
        try analyzeClip(String(clipArgument.split(separator: "=", maxSplits: 1).last ?? ""))
        try runSyntheticCadenceTest(gameFPS: 30)
        try runSyntheticCadenceTest(gameFPS: 40)
        try runNative60CadenceTest()
        exit(0)
    }
    if arguments.contains("--test-cadence") {
        try runSyntheticCadenceTest(gameFPS: 30)
        try runSyntheticCadenceTest(gameFPS: 40)
        try runNative60CadenceTest()
        exit(0)
    }
    print("使用 --apple-downsample-probe、--apple-tiled-probe 或 --test-cadence 运行 Apple 插帧检查。")
} catch {
    fputs("探针失败：\(error)\n", stderr)
    exit(1)
}
