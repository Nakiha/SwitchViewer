import Foundation
import CryptoKit

/// Run in the unsandboxed launcher after the game has closed both movie writers.
public enum ComparisonRecordingArchive {
    public struct Saved {
        public let directory: URL
        public let cleanupError: String?
    }
    public static func transfer(from source: URL,
                                to root: URL = ComparisonMovieRecorder.recordingsDirectory()) throws -> Saved {
        let fm = FileManager.default
        let names = ["original.mov", "processed.mov", "recording.json"]
        guard UUID(uuidString: source.lastPathComponent) != nil,
              (try source.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let children = try fm.contentsOfDirectory(atPath: source.path)
        guard Set(children).subtracting(names + [".DS_Store"]).isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        for name in names {
            let values = try source.appendingPathComponent(name).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CocoaError(.fileReadCorruptFile) }
        }
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: source.appendingPathComponent("recording.json"))) as? [String: Any]
        guard manifest?["state"] as? String == "completed" else { throw CocoaError(.fileReadCorruptFile) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var destination = root.appendingPathComponent(source.lastPathComponent, isDirectory: true)
        while fm.fileExists(atPath: destination.path) {
            destination = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        }
        let stage = root.appendingPathComponent(".import-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: stage) }
        for name in names {
            let from = source.appendingPathComponent(name), to = stage.appendingPathComponent(name)
            try fm.copyItem(at: from, to: to)
            guard try digest(from) == digest(to) else { throw CocoaError(.fileReadCorruptFile) }
        }
        try fm.moveItem(at: stage, to: destination)
        do {
            try fm.removeItem(at: source)
            return Saved(directory: destination, cleanupError: nil)
        } catch {
            // The verified public copy is usable even if sandbox cleanup fails.
            return Saved(directory: destination, cleanupError: error.localizedDescription)
        }
    }
    private static func digest(_ url: URL) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty { hash.update(data: bytes) }
        return hash.finalize()
    }
}
