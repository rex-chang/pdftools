import Foundation

/// A PDF file queued for merge. Mirrors the Go `FileItem` struct.
struct FileItem: Identifiable, Equatable {
    let id = UUID()
    let path: String
    let name: String
    let size: Int64
    let pageCount: Int

    init(path: String, size: Int64, pageCount: Int) {
        self.path = path
        self.name = (path as NSString).lastPathComponent
        self.size = size
        self.pageCount = pageCount
    }

    /// Equality based on path (used for dedup), ignoring the generated id.
    static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        lhs.path == rhs.path
    }
}
