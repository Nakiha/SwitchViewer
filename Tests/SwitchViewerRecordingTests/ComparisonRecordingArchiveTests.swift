import XCTest
@testable import SwitchViewerRecording

final class ComparisonRecordingArchiveTests: XCTestCase {
    private func fixture(_ base: URL, state: String = "completed") throws -> URL {
        let source = base.appendingPathComponent("Game/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(repeating: 42, count: 1_100_000).write(to: source.appendingPathComponent("original.mov"))
        try Data(repeating: 73, count: 1_100_000).write(to: source.appendingPathComponent("processed.mov"))
        try JSONSerialization.data(withJSONObject: ["state": state]).write(to: source.appendingPathComponent("recording.json"))
        return source
    }
    func testTransferVerifiesBothFilesAndRemovesPrivateCopy() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = try fixture(base)
        let original = try Data(contentsOf: source.appendingPathComponent("original.mov"))
        let processed = try Data(contentsOf: source.appendingPathComponent("processed.mov"))
        let root = base.appendingPathComponent("Movies")
        let result = try ComparisonRecordingArchive.transfer(from: source, to: root)
        XCTAssertNil(result.cleanupError)
        XCTAssertEqual(result.directory, root.appendingPathComponent(source.lastPathComponent, isDirectory: true))
        XCTAssertEqual(try Data(contentsOf: result.directory.appendingPathComponent("original.mov")), original)
        XCTAssertEqual(try Data(contentsOf: result.directory.appendingPathComponent("processed.mov")), processed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [source.lastPathComponent])
    }
    func testExistingDestinationIsNeverOverwritten() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = try fixture(base), root = base.appendingPathComponent("Movies")
        let existing = root.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: existing.appendingPathComponent("original.mov"))
        let saved = try ComparisonRecordingArchive.transfer(from: source, to: root)
        XCTAssertNotEqual(saved.directory.lastPathComponent, existing.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: existing.appendingPathComponent("original.mov")), Data("keep".utf8))
    }
    func testFailedTransferPreservesSourceAndIncompleteRecordingIsRejected() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = try fixture(base), blocked = base.appendingPathComponent("NotADirectory")
        try Data().write(to: blocked)
        XCTAssertThrowsError(try ComparisonRecordingArchive.transfer(from: source, to: blocked))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("processed.mov").path))
        let incomplete = try fixture(base, state: "incomplete")
        XCTAssertThrowsError(try ComparisonRecordingArchive.transfer(from: incomplete, to: base.appendingPathComponent("Movies")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: incomplete.path))
    }
    func testPermissionErrorsDistinguishSourceAccessFromDestinationWriteFailure() {
        let source = URL(fileURLWithPath: "/Game/Recordings/" + UUID().uuidString)
        let denied = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoPermission.rawValue,
                             userInfo: [NSURLErrorKey: source])
        XCTAssertTrue(ComparisonRecordingArchive.needsSourceAuthorization(denied, source: source))
        let wrapped = NSError(domain: "Archive", code: 1, userInfo: [NSUnderlyingErrorKey: denied])
        XCTAssertTrue(ComparisonRecordingArchive.needsSourceAuthorization(wrapped, source: source))
        let destination = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteNoPermission.rawValue,
                                  userInfo: [NSFilePathErrorKey: "/Movies/SwitchViewer"])
        XCTAssertFalse(ComparisonRecordingArchive.needsSourceAuthorization(destination, source: source))
        XCTAssertFalse(ComparisonRecordingArchive.needsSourceAuthorization(CocoaError(.fileNoSuchFile), source: source))
    }

}
