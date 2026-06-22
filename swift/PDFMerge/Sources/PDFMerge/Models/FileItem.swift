import Foundation
import CryptoKit

/// A PDF file queued for merge. Mirrors the Go `FileItem` struct.
///
/// Identifiable by path: the path is already unique in the queue (addFiles
/// dedups by path), so using it as `id` keeps SwiftUI's diffing consistent
/// with `==` (which also compares only path). The previous `id = UUID()`
/// created a new value per init, which could drift out of sync with `==`
/// and bite us if a FileItem were ever put in a Set or compared with ==.
struct FileItem: Identifiable, Equatable, Hashable {
    var id: String { path }
    let path: String
    let name: String
    let size: Int64
    let pageCount: Int
    /// SHA-256 of file contents; empty if the file could not be hashed.
    /// Two items with the same sha256 are content-duplicates even when their
    /// paths differ (e.g. the same invoice copied from two folders).
    let sha256: String

    init(path: String, size: Int64, pageCount: Int, sha256: String) {
        self.path = path
        self.name = (path as NSString).lastPathComponent
        self.size = size
        self.pageCount = pageCount
        self.sha256 = sha256
    }

    /// Equality based on path, matching `id`. (Identifiable + Equatable
    /// should agree.)
    static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        lhs.path == rhs.path
    }

    /// Hashing also tracks path only — consistent with == and id.
    func hash(into hasher: inout Hasher) {
        hasher.combine(path)
    }
}

/// Compute the SHA-256 hex digest of a file's contents. Returns "" on any
/// I/O error. Uses CryptoKit's streaming hasher so large PDFs don't need to
/// fit in memory at once.
enum FileHasher {
    static func sha256(ofFile path: String) -> String {
        guard let stream = InputStream(fileAtPath: path) else { return "" }
        stream.open()
        defer { stream.close() }
        var hasher = SHA256()
        let bufferSize = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read < 0 { return "" }            // stream error
            if read == 0 { break }
            hasher.update(data: UnsafeBufferPointer(start: buffer, count: read))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

