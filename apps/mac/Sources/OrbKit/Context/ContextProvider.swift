import Foundation

/// One thing that orb knows about in a call, besides your voice: a folder, a file, later an open document or a page.
public struct ContextItem: Identifiable, Hashable, Sendable {
    public var id: String          // unique across providers, e.g. "files:/Users/me/Desktop/Notes"
    public var provider: String    // the provider's id
    public var title: String
    public var url: URL?

    public init(id: String, provider: String, title: String, url: URL? = nil) {
        self.id = id
        self.provider = provider
        self.title = title
        self.url = url
    }
}

/// A kind of context. A new kind (the document you have open, a web page, the clipboard) is a new provider.
public protocol ContextProvider: Sendable {
    var id: String { get }
    var title: String { get }
    /// Items that can be offered without a picker (for files: the folders on the Desktop).
    func suggestions() async -> [ContextItem]
    /// The text that the service gets for these items, in the order to pack (the most relevant first).
    func sources(for items: [ContextItem]) async -> [Source]
}
