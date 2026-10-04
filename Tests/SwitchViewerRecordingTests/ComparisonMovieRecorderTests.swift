import XCTest
import AVFoundation
import QuartzCore
@testable import SwitchViewerRecording

final class ComparisonMovieRecorderTests: XCTestCase {
    private func buffer(_ color: UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 64, 36, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let result = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(result, [])
        defer { CVPixelBufferUnlockBaseAddress(result, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(result))
        for y in 0..<36 {
            let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(result)).assumingMemoryBound(to: UInt8.self)
            for x in 0..<64 { row[x * 4] = color; row[x * 4 + 1] = color; row[x * 4 + 2] = color; row[x * 4 + 3] = 255 }
        }
        return result
    }
    private func times(_ url: URL) async throws -> [Double] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 320, height: 180))
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetTotalSampleSize(sample) > 0 else { continue }
            times.append(CMTimeGetSeconds(CMSampleBufferGetOutputPresentationTimeStamp(sample)))
        }
        XCTAssertEqual(reader.status, .completed)
        return times
    }
    private func hasBrightFrame(_ url: URL) async throws -> Bool {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first),
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let row = CVPixelBufferGetBaseAddress(buffer)!.advanced(by: 90 * CVPixelBufferGetBytesPerRow(buffer))
                .assumingMemoryBound(to: UInt8.self)
            let value = row[160 * 4 + 1]
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            if value > 140 { return true }
        }
        return false
    }
    func testMoviesShareContentClockAndPreserveGeneratedFrames() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let started = expectation(description: "started")
        let finished = expectation(description: "finished")
        var folder: URL?
        let recorder = ComparisonMovieRecorder { event in
            switch event {
            case .started(let url): folder = url; started.fulfill()
            case .finished: finished.fulfill()
            case .failed(let message): XCTFail(message); finished.fulfill()
            default: break
            }
        }
        recorder.start(root: root, duration: 5, width: 320, height: 180, hostTime: 1000)
        await fulfillment(of: [started], timeout: 10)
        let original = try buffer(40), generated = try buffer(180)
        // A duplicate/out-of-order output must be counted, never retimed.
        for i in 0..<39 {
            let time = 1000.1 + Double(i) / 60
            if i % 2 == 0 { recorder.append(original, track: .original, hostTime: time) }
            recorder.append(i % 2 == 0 ? original : generated, track: .processed,
                hostTime: time, generated: i % 2 != 0)
            try await Task.sleep(nanoseconds: 15_000_000)
        }
        recorder.append(original, track: .processed, hostTime: 1000.1)
        recorder.stop(hostTime: 1001)
        await fulfillment(of: [finished], timeout: 15)
        XCTAssertFalse(recorder.isBusy)
        let directory = try XCTUnwrap(folder)
        let sourceTimes = try await times(directory.appendingPathComponent("original.mov"))
        let outputTimes = try await times(directory.appendingPathComponent("processed.mov"))
        let sourceBright = try await hasBrightFrame(directory.appendingPathComponent("original.mov"))
        let processedBright = try await hasBrightFrame(directory.appendingPathComponent("processed.mov"))
        XCTAssertFalse(sourceBright)
        XCTAssertTrue(processedBright, "the encoded processed movie contains the distinct generated image")
        XCTAssertEqual(sourceTimes.count, 20)
        XCTAssertEqual(outputTimes.count, 39)
        XCTAssertEqual(try XCTUnwrap(sourceTimes.first), 0.1, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(outputTimes.first), 0.1, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(outputTimes.last), 0.1 + 38.0 / 60, accuracy: 0.0001)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("recording.json"))) as? [String: Any])
        XCTAssertEqual(json["state"] as? String, "completed")
        let tracks = try XCTUnwrap(json["tracks"] as? [String: [String: Int]])
        XCTAssertEqual(tracks["processed"]?["generatedFrames"], 19)
        XCTAssertEqual(tracks["processed"]?["droppedByRecorder"], 1)
        XCTAssertEqual(tracks["original"]?["droppedByRecorder"], 0)
    }
    func testAutomaticStopReportsEmptyPairAsIncomplete() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let done = expectation(description: "automatic stop")
        var directory: URL?
        let recorder = ComparisonMovieRecorder { event in
            switch event {
            case .started(let url): directory = url
            case .failed: done.fulfill()
            case .finished: XCTFail("empty recording must not succeed"); done.fulfill()
            default: break
            }
        }
        recorder.start(root: root, duration: 0.1, width: 320, height: 180)
        wait(for: [done], timeout: 10)
        XCTAssertFalse(recorder.isBusy)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: XCTUnwrap(directory).appendingPathComponent("recording.json"))) as? [String: Any])
        XCTAssertEqual(json["state"] as? String, "incomplete")
    }
    func testStopDuringSetupDoesNotLeaveRecorderRunning() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let done = expectation(description: "stop during setup")
        let recorder = ComparisonMovieRecorder { event in
            if case .failed = event { done.fulfill() }
        }
        recorder.start(root: root, width: 320, height: 180)
        recorder.stop()
        wait(for: [done], timeout: 10)
        XCTAssertFalse(recorder.isBusy)
        XCTAssertFalse(recorder.isRecording)
    }
    func testUnwritableDestinationReportsFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: root) // A file cannot be used as a recording directory.
        defer { try? FileManager.default.removeItem(at: root) }
        let failed = expectation(description: "destination failure")
        let recorder = ComparisonMovieRecorder { event in
            if case .failed = event { failed.fulfill() }
        }
        recorder.start(root: root)
        wait(for: [failed], timeout: 5)
        XCTAssertFalse(recorder.isBusy)
    }

}
