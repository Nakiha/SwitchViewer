import AppKit

/// User-selected access to generated recordings, without whole-container access.
final class GameRecordingFolderAccess {
    private let defaults: UserDefaults
    private let key = "gameRecordingFolderBookmarks"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static func accepts(_ selected: URL, for source: URL) -> Bool {
        guard UUID(uuidString: source.lastPathComponent) != nil else { return false }
        let selected = selected.standardizedFileURL.path
        let parent = source.deletingLastPathComponent()
        return selected == source.standardizedFileURL.path || (parent.lastPathComponent == "Recordings" && selected == parent.standardizedFileURL.path)
    }
    func remember(_ selected: URL) {
        // A bookmark may be unavailable for an ad-hoc development signature.
        // The explicit picker grant still permits this attempt in that case.
        guard let data = try? selected.bookmarkData(options: .withSecurityScope,
            includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        var bookmarks = defaults.dictionary(forKey: key) as? [String: Data] ?? [:]
        bookmarks[selected.standardizedFileURL.path] = data
        defaults.set(bookmarks, forKey: key)
    }
    func restoredAccess(for source: URL) -> URL? {
        let bookmarks = defaults.dictionary(forKey: key) as? [String: Data] ?? [:]
        for candidate in [source, source.deletingLastPathComponent()] {
            guard let data = bookmarks[candidate.standardizedFileURL.path] else { continue }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                                     relativeTo: nil, bookmarkDataIsStale: &stale),
                  Self.accepts(url, for: source) else { continue }
            if stale { remember(url) }
            return url
        }
        return nil
    }
    func chooseAccess(for source: URL, completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "授权读取录制素材"
        panel.message = "请选择当前素材文件夹或其上一级 Recordings 文件夹，允许 SwitchViewer 将素材保存到“影片 / SwitchViewer”。"
        panel.prompt = "授权并转移"
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = source.deletingLastPathComponent()
        panel.begin { [self] response in
            guard response == .OK, let selected = panel.url else { completion(nil); return }
            guard Self.accepts(selected, for: source) else { completion(selected); return }
            remember(selected)
            completion(selected)
        }
    }
}
