import Foundation
import SwiftUI

/// Owns the PDF file queue: items, selection, and content-duplicate
/// detection. Extracted from the former monolithic AppState so queue logic
/// can be tested and reasoned about independently of merge/invoice state.
@MainActor
final class FileQueueStore: ObservableObject {

    // MARK: Queue

    @Published var items: [FileItem] = []
    @Published var selectedIndex: Int? = nil

    // MARK: Duplicates

    /// Indices of items whose content (SHA-256) appears more than once in
    /// the queue. Stored as @Published so the UI reads it once per render
    /// rather than recomputing O(N) on every access. Recomputed by
    /// `recomputeDuplicates()` whenever the queue mutates.
    @Published private(set) var duplicateIndices: Set<Int> = []

    /// True when the queue contains at least one content-duplicate pair.
    var hasDuplicates: Bool { !duplicateIndices.isEmpty }

    /// Tracks addFiles operations so we can show a "正在添加…" indicator.
    @Published var isAddingFiles: Bool = false

    // MARK: Derived

    var paths: [String] { items.map(\.path) }
    var selectedItem: FileItem? {
        guard let i = selectedIndex, items.indices.contains(i) else { return nil }
        return items[i]
    }
    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }

    // MARK: Mutations

    /// Add PDF file paths, skipping path-duplicates and unreadable files.
    /// Also computes a content SHA-256 so cross-path content duplicates can
    /// be flagged in the UI.
    ///
    /// Heavy work (SHA-256 + PDF parse for page count) runs on a detached
    /// task so the UI doesn't freeze while hashing large/many files.
    func addFiles(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        isAddingFiles = true
        // Snapshot the current paths under the actor lock for dedup.
        let existing = Set(items.map(\.path))
        Task.detached(priority: .userInitiated) { [weak self] in
            var added: [FileItem] = []
            for p in paths {
                if Task.isCancelled { break }
                if existing.contains(p) { continue }
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: p) else { continue }
                let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                let pages = PDFMerger.pageCount(at: p)
                let sha = FileHasher.sha256(ofFile: p)
                added.append(FileItem(path: p, size: size, pageCount: pages, sha256: sha))
            }
            await self?.applyAddedFiles(added)
        }
    }

    /// Merge newly-hashed items into the queue on the main actor and
    /// recompute the duplicate set. Runs after the detached hashing task.
    private func applyAddedFiles(_ added: [FileItem]) {
        guard !added.isEmpty else {
            isAddingFiles = false
            return
        }
        // Re-check dedup against the live list (the queue may have changed
        // while we were hashing).
        for item in added where !items.contains(where: { $0.path == item.path }) {
            items.append(item)
        }
        recomputeDuplicates()
        if selectedIndex == nil, !items.isEmpty { selectedIndex = 0 }
        isAddingFiles = false
    }

    func removeSelected() {
        guard let idx = selectedIndex, items.indices.contains(idx) else { return }
        items.remove(at: idx)
        if items.isEmpty {
            selectedIndex = nil
        } else if let i = selectedIndex, i >= items.count {
            selectedIndex = items.count - 1
        }
        recomputeDuplicates()
    }

    func moveUp() {
        guard var idx = selectedIndex, idx > 0, idx < items.count else { return }
        idx -= 1
        items.swapAt(idx, idx + 1)
        selectedIndex = idx
        recomputeDuplicates()
    }

    func moveDown() {
        guard var idx = selectedIndex, idx >= 0, idx < items.count - 1 else { return }
        idx += 1
        items.swapAt(idx, idx - 1)
        selectedIndex = idx
        recomputeDuplicates()
    }

    func sortByName() {
        items.sort { $0.name < $1.name }
        recomputeDuplicates()
    }

    func clear() {
        items.removeAll()
        selectedIndex = nil
        recomputeDuplicates()
    }

    // MARK: Duplicate computation

    /// Recompute `duplicateIndices` from the current items. O(N).
    /// Items with an empty sha256 (hash failed) are never considered
    /// duplicates of anything.
    private func recomputeDuplicates() {
        var counts: [String: Int] = [:]
        for it in items where !it.sha256.isEmpty {
            counts[it.sha256, default: 0] += 1
        }
        var out = Set<Int>()
        for (i, it) in items.enumerated() where (counts[it.sha256] ?? 0) > 1 {
            out.insert(i)
        }
        duplicateIndices = out
    }
}
