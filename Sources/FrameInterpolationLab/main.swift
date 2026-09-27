import CoreVideo
import Foundation
import Metal
import SwitchViewerInterpolation
import Vision
import AVFoundation

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

private func run(size: FrameSize, repeats: Int, shift: Int, flowScale: Float,
                 engine: FullResolutionFrameInterpolator) throws {
    let previous = try makePatternFrame(size: size, shift: 0)
    let current = try makePatternFrame(size: size, shift: shift)
    let ideal = try makePatternFrame(size: size, shift: shift / 2)
    var preprocessSamples: [Double] = []
    var flowSamples: [Double] = []
    var renderSamples: [Double] = []
    var result: FullResolutionFrameInterpolator.Result?
    for _ in 0..<repeats {
        let measured = try engine.interpolate(previous: previous, current: current)
        preprocessSamples.append(measured.preprocessingMilliseconds)
        flowSamples.append(measured.opticalFlowMilliseconds)
        renderSamples.append(measured.synthesisMilliseconds)
        result = measured
    }
    guard let result else { return }
    let previousCenter = weightedCenterX(previous, row: size.height / 2) ?? -1
    let currentCenter = weightedCenterX(current, row: size.height / 2) ?? -1
    let generatedCenter = weightedCenterX(result.pixelBuffer, row: size.height / 2) ?? -1
    let expectedCenter = (previousCenter + currentCenter) / 2
    let centerError = abs(generatedCenter - expectedCenter)
    let interpolationError = meanAbsoluteError(result.pixelBuffer, ideal, size: size)
    let blendError = meanBlendError(previous, current, ideal, size: size)
    let flowWidth = result.flowWidth
    let flowHeight = result.flowHeight
    let format = String(result.opticalFlowPixelFormat, radix: 16)
    print("尺寸：\(size.label)，输入：NV12，Vision 光流：\(flowWidth)×\(flowHeight)，像素格式：0x\(format)")
    print(String(format: "中心光流采样：x=%.3f, y=%.3f；块中心误差：%.1f px（目标约 %.1f px）",
                 result.centerFlowX, result.centerFlowY, centerError, expectedCenter))
    print(String(format: "合成帧对理想中间帧的亮度误差：%.2f；简单叠帧对照误差：%.2f",
                 interpolationError, blendError))
    let sampleText = flowSamples.map { String(format: "%.1f", $0) }.joined(separator: ", ")
    let averagePreprocess = preprocessSamples.reduce(0, +) / Double(preprocessSamples.count)
    let averageFlow = flowSamples.reduce(0, +) / Double(flowSamples.count)
    let averageRender = renderSamples.reduce(0, +) / Double(renderSamples.count)
    print(String(format: "平均耗时：输入缩小 %.1f ms，光流 %.1f ms，4K Metal 合成 %.1f ms，总计 %.1f ms",
                 averagePreprocess, averageFlow, averageRender,
                 averagePreprocess + averageFlow + averageRender))
    print("每次光流耗时（ms）：\(sampleText)；30fps 插帧预算 33.3ms，60fps 插帧预算 16.7ms")
    let sortedTotal = zip(flowSamples, renderSamples).map(+).sorted()
    if let fastest = sortedTotal.first, let slowest = sortedTotal.last {
        print(String(format: "总耗时范围：%.1f–%.1f ms", fastest, slowest))
    }
    let expectedFlowWidth = max(2, (Int(Float(size.width) * flowScale) / 2) * 2)
    let expectedFlowHeight = max(2, (Int(Float(size.height) * flowScale) / 2) * 2)
    if flowWidth == expectedFlowWidth && flowHeight == expectedFlowHeight && centerError <= 12
        && interpolationError < blendError * 0.95 {
        print("结果：\(size.label) 全分辨率输出通过；合成帧改善了中间运动位置")
    } else {
        print("结果：探针未通过视觉位移校验；不要将此模块接入实时播放")
    }
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
    while let sample = output.copyNextSampleBuffer(),
          let pixelBuffer = CMSampleBufferGetImageBuffer(sample) {
        let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
        let result = detector.observe(pixelBuffer, presentationTime: seconds)
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
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    let arguments = Set(args)
    let requestedRepeats = Int(args.first(where: { $0.hasPrefix("--repeats=") })?
        .split(separator: "=").last ?? "3") ?? 3
    let repeats = arguments.contains("--quick") ? 1 : max(1, requestedRepeats)
    let shift = Int(args.first(where: { $0.hasPrefix("--shift=") })?
        .split(separator: "=").last ?? "16") ?? 16
    let flowScale = Float(args.first(where: { $0.hasPrefix("--flow-scale=") })?
        .split(separator: "=").last ?? "1") ?? 1
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
    guard let device = MTLCreateSystemDefaultDevice() else {
        throw NSError(domain: "FrameInterpolationLab", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "没有 Metal GPU"])
    }
    let accuracy: VNGenerateOpticalFlowRequest.ComputationAccuracy = arguments.contains("--low-accuracy") ? .low : .medium
    print("设备：\(device.name)；精度：\(arguments.contains("--low-accuracy") ? "低" : "中")；重复次数：\(repeats)")
    let engine = try FullResolutionFrameInterpolator(device: device,
                                                     computationAccuracy: accuracy,
                                                     flowScale: flowScale)
    if arguments.contains("--4k-only") {
        try run(size: FrameSize(width: 3840, height: 2160), repeats: repeats,
                shift: shift, flowScale: flowScale, engine: engine)
    } else if arguments.contains("--1080p-only") {
        try run(size: FrameSize(width: 1920, height: 1080), repeats: repeats,
                shift: shift, flowScale: flowScale, engine: engine)
    } else {
        try run(size: FrameSize(width: 1920, height: 1080), repeats: repeats,
                shift: shift, flowScale: flowScale, engine: engine)
        try run(size: FrameSize(width: 3840, height: 2160), repeats: repeats,
                shift: shift, flowScale: flowScale, engine: engine)
    }
} catch {
    fputs("探针失败：\(error)\n", stderr)
    exit(1)
}
