import Foundation

/// The first context provider: files, one by one or a whole folder (its files, not its subfolders).
public struct FilesProvider: ContextProvider {
    public let id = "files"
    public let title = "Files"
    let desktop: URL

    public init(desktop: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Desktop")) {
        self.desktop = desktop
    }

    public func item(for url: URL) -> ContextItem {
        ContextItem(id: "files:" + url.path, provider: id, title: url.lastPathComponent, url: url)
    }

    /// The folders directly on the Desktop, newest first. The first listing asks macOS for the Desktop permission.
    public func suggestions() async -> [ContextItem] {
        Self.entries(of: desktop).filter(\.isFolder).map { item(for: $0.url) }
    }

    /// Each item's readable files: a folder gives its files newest first. Extraction stops at the request limits.
    public func sources(for items: [ContextItem]) async -> [Source] {
        var out: [Source] = [], total = 0
        for url in items.compactMap(\.url).flatMap(Self.files(in:)) {
            guard out.count < SourcePack.maxSources, total < SourcePack.maxTotalChars else { break }
            if let s = Extractor.source(of: url) {
                out.append(s)
                total += min(s.text.count, SourcePack.maxSourceChars)
            }
        }
        return SourcePack.fit(out)
    }

    /// The readable files of a folder, newest first; a file is itself.
    public static func files(in url: URL) -> [URL] {
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        guard isFolder else { return Extractor.kind(of: url) == nil ? [] : [url] }
        return entries(of: url).filter { !$0.isFolder && Extractor.kind(of: $0.url) != nil }.map(\.url)
    }

    struct Entry { var url: URL; var isFolder: Bool; var changed: Date }

    static func entries(of folder: URL) -> [Entry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                 options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { url -> Entry? in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isPackage != true else { return nil }
            return Entry(url: url, isFolder: v.isDirectory == true, changed: v.contentModificationDate ?? .distantPast)
        }.sorted { $0.changed > $1.changed }
    }
}
