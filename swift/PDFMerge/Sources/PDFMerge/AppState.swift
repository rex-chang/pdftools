import Foundation
import SwiftUI

/// Central app state. Mirrors the Go `App`/`FileList`/`Settings` trio,
/// but using `@Published` so SwiftUI drives all UI refresh automatically —
/// no manual `List.Refresh()` / `updateToolbarState()` needed.
@MainActor
final class AppState: ObservableObject {

    // MARK: File queue (mirrors FileList.Items / selectedID)
    @Published var items: [FileItem] = []
    @Published var selectedIndex: Int? = nil

    // MARK: Output settings (mirrors Settings.OutputName/OutputDir)
    @Published var outputName: String
    @Published var outputDir: String

    // MARK: Merge progress / status (mirrors Settings.StatusLabel + Progress*)
    @Published var statusText: String = ""
    @Published var statusVisible: Bool = false
    @Published var isMerging: Bool = false
    @Published var progressValue: Double? = nil   // nil = indeterminate; 0..1 = bar
    @Published var lastMessage: String? = nil     // completion / error alert

    // MARK: Invoice dialog
    @Published var invoiceResults: [InvoiceData] = []
    @Published var invoiceDebugTexts: [String] = []
    @Published var showInvoiceDialog: Bool = false

    // MARK: Extraction progress (OCR can take 1-3s per broken file)
    @Published var isExtracting: Bool = false
    @Published var extractStatus: String = ""
    private var extractTask: Task<Void, Never>? = nil

    // Private: background task handles for cancellation.
    private var mergeTask: Task<Void, Never>? = nil
    /// Tracks addFiles operations so we can show a "正在添加…" indicator and
    /// avoid overlapping adds stomping on each other's dedup checks.
    @Published var isAddingFiles: Bool = false

    init() {
        self.outputName = "合并_" + Self.timestamp() + ".pdf"
        self.outputDir = FileManager.default.homeDirectoryForCurrentUser.path
    }

    // MARK: Queue mutations

    /// Add PDF file paths, skipping duplicates and unreadable files.
    /// Mirrors Go `FileList.AddFiles` (dedup by path + stat + page count).
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

    var paths: [String] { items.map(\.path) }
    var selectedItem: FileItem? {
        guard let i = selectedIndex, items.indices.contains(i) else { return nil }
        return items[i]
    }

    /// Indices of items whose content (SHA-256) appears more than once in
    /// the queue. Stored as @Published so the UI reads it once per render
    /// rather than recomputing O(N) on every access (the previous computed
    /// property was invoked N+2 times per list render). Recomputed by
    /// `recomputeDuplicates()` whenever the queue mutates.
    @Published var duplicateIndices: Set<Int> = []

    /// Recompute `duplicateIndices` from the current items. O(N).
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

    /// True when the queue contains at least one content-duplicate pair.
    var hasDuplicates: Bool { !duplicateIndices.isEmpty }

    var canMerge: Bool { items.count >= 2 && !isMerging }
    var canExtract: Bool { !items.isEmpty && !isMerging && !isExtracting }

    /// Output URL of the most recent successful merge, so the success alert
    /// can offer "在 Finder 中显示". Nil until a merge succeeds.
    @Published var lastMergeOutput: URL? = nil

    // MARK: Merge

    func merge() {
        guard items.count >= 2 else {
            lastMessage = "请至少添加 2 个 PDF 文件"
            return
        }
        let dir = outputDir.trimmingCharacters(in: .whitespaces)
        var name = outputName.trimmingCharacters(in: .whitespaces)
        guard !dir.isEmpty, !name.isEmpty else {
            lastMessage = "输出路径为空"
            return
        }
        // Ensure a .pdf extension so macOS treats the file as a PDF.
        if (name as NSString).pathExtension.lowercased() != "pdf" {
            name += ".pdf"
        }
        let outputPath = (dir as NSString).appendingPathComponent(name)

        // Cancel any in-flight merge (mirrors Go's context cancel swap).
        mergeTask?.cancel()

        let inputs = paths
        isMerging = true
        progressValue = nil
        statusVisible = true
        statusText = "合并中..."

        // `Task.detached` runs OFF the main actor — without it, the heavy
        // PDFKit parsing + file writes would freeze the UI. Cancellation is
        // cooperative: PDFMerger.merge calls Task.checkCancellation() between
        // files, so cancel() actually stops it mid-queue.
        mergeTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let result = try PDFMerger.merge(inputs, to: outputPath)
                await self?.finishMergeSuccess(result: result, name: name, outputPath: outputPath)
            } catch is CancellationError {
                await self?.finishMergeCancelled()
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                await self?.finishMergeError(message: msg)
            }
        }
    }

    private func finishMergeSuccess(result: (merged: Int, skipped: [String]), name: String, outputPath: String) {
        isMerging = false
        progressValue = 1.0
        lastMergeOutput = URL(fileURLWithPath: outputPath)
        var statusMsg = "已合并 \(result.merged) 页 → \(name)"
        if !result.skipped.isEmpty {
            statusMsg += "\n跳过 \(result.skipped.count) 个: " + result.skipped.joined(separator: ", ")
        }
        statusText = statusMsg
        lastMessage = "成功合并 \(result.merged) 页到:\n\(outputPath)"
    }

    private func finishMergeCancelled() {
        isMerging = false
        progressValue = nil
        statusText = "已取消"
    }

    private func finishMergeError(message: String) {
        isMerging = false
        progressValue = nil
        statusText = "错误: \(message)"
        lastMessage = "合并失败: \(message)"
    }

    /// Cancel an in-flight merge (cooperative — stops after the current
    /// file). No-op if nothing is running.
    func cancelMerge() {
        mergeTask?.cancel()
    }

    // MARK: Invoice extraction

    func extractInvoices() {
        guard !items.isEmpty, !isExtracting else { return }
        let inputs = paths
        isExtracting = true
        extractStatus = "提取中 0/\(inputs.count)…"
        // `Task.detached` so OCR (1-3s per broken PDF) runs off the main
        // actor and progress updates actually reach the screen. Cancellation
        // is cooperative: extractAll checks Task.isCancelled between files.
        extractTask = Task.detached(priority: .userInitiated) { [weak self] in
            let results = InvoiceExtractor.extractAll(paths: inputs) { done, total, name in
                // Inline MainActor hop avoids spawning a new Task per callback.
                Task { @MainActor in
                    self?.extractStatus = "提取中 \(done)/\(total): \(name)"
                }
            }
            let debug = inputs.map { InvoiceExtractor.debugText(at: $0) }
            await self?.finishExtraction(results: results, debug: debug)
        }
    }

    /// Cancel an in-flight extraction (cooperative — stops after the
    /// current file). No-op if nothing is running.
    func cancelExtraction() {
        extractTask?.cancel()
    }

    private func finishExtraction(results: [InvoiceData], debug: [String]) {
        invoiceResults = results
        invoiceDebugTexts = debug
        isExtracting = false
        extractStatus = ""
        // If cancelled mid-way, only show results if we got at least one.
        if !results.isEmpty {
            showInvoiceDialog = true
        }
    }

    // MARK: Helpers

    /// yyyyMMdd_HHmmss, matching Go's time.Now().Format("20060102_150405").
    private static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: Date())
    }
}
