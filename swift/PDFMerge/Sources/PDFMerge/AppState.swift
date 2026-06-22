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

    // Private: background merge task for cancellation.
    private var mergeTask: Task<Void, Never>? = nil

    init() {
        self.outputName = "合并_" + Self.timestamp() + ".pdf"
        self.outputDir = FileManager.default.homeDirectoryForCurrentUser.path
    }

    // MARK: Queue mutations

    /// Add PDF file paths, skipping duplicates and unreadable files.
    /// Mirrors Go `FileList.AddFiles` (dedup + stat + page count).
    func addFiles(_ paths: [String]) {
        var changed = false
        for p in paths {
            guard !items.contains(where: { $0.path == p }) else { continue }
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: p) else { continue }
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let pages = PDFMerger.pageCount(at: p)
            items.append(FileItem(path: p, size: size, pageCount: pages))
            changed = true
        }
        if changed {
            if selectedIndex == nil { selectedIndex = 0 }
        }
    }

    func removeSelected() {
        guard let idx = selectedIndex, items.indices.contains(idx) else { return }
        items.remove(at: idx)
        if items.isEmpty {
            selectedIndex = nil
        } else if let i = selectedIndex, i >= items.count {
            selectedIndex = items.count - 1
        }
    }

    func moveUp() {
        guard var idx = selectedIndex, idx > 0, idx < items.count else { return }
        idx -= 1
        items.swapAt(idx, idx + 1)
        selectedIndex = idx
    }

    func moveDown() {
        guard var idx = selectedIndex, idx >= 0, idx < items.count - 1 else { return }
        idx += 1
        items.swapAt(idx, idx - 1)
        selectedIndex = idx
    }

    func sortByName() {
        items.sort { $0.name < $1.name }
    }

    func clear() {
        items.removeAll()
        selectedIndex = nil
    }

    var paths: [String] { items.map(\.path) }
    var selectedItem: FileItem? {
        guard let i = selectedIndex, items.indices.contains(i) else { return nil }
        return items[i]
    }

    var canMerge: Bool { items.count >= 2 && !isMerging }
    var canExtract: Bool { !items.isEmpty && !isMerging && !isExtracting }

    // MARK: Merge

    func merge() {
        guard items.count >= 2 else {
            lastMessage = "请至少添加 2 个 PDF 文件"
            return
        }
        let dir = outputDir.trimmingCharacters(in: .whitespaces)
        let name = outputName.trimmingCharacters(in: .whitespaces)
        guard !dir.isEmpty, !name.isEmpty else {
            lastMessage = "输出路径为空"
            return
        }
        let outputPath = (dir as NSString).appendingPathComponent(name)

        // Cancel any in-flight merge (mirrors Go's context cancel swap).
        mergeTask?.cancel()

        let inputs = paths
        isMerging = true
        progressValue = nil
        statusVisible = true
        statusText = "合并中..."

        mergeTask = Task {
            do {
                let result = try PDFMerger.merge(inputs, to: outputPath)
                await MainActor.run {
                    self.isMerging = false
                    self.progressValue = 1.0
                    var msg = "已合并 \(result.merged) 个文件 → \(name)"
                    if !result.skipped.isEmpty {
                        msg += "\n跳过 \(result.skipped.count) 个: " + result.skipped.joined(separator: ", ")
                    }
                    self.statusText = msg
                    self.lastMessage = "成功合并 \(result.merged) 页到:\n\(outputPath)"
                }
            } catch is CancellationError {
                await MainActor.run { self.finishCancelled() }
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                await MainActor.run {
                    self.isMerging = false
                    self.progressValue = nil
                    self.statusText = "已取消"
                    if Task.isCancelled {
                        self.statusVisible = true
                    } else {
                        self.statusText = "错误: \(msg)"
                    }
                    self.lastMessage = "合并失败: \(msg)"
                }
            }
        }
    }

    private func finishCancelled() {
        isMerging = false
        progressValue = nil
        statusText = "已取消"
    }

    // MARK: Invoice extraction

    func extractInvoices() {
        guard !items.isEmpty, !isExtracting else { return }
        let inputs = paths
        isExtracting = true
        extractStatus = "提取中 0/\(inputs.count)…"
        Task {
            // Extraction is a mix of fast text-layer parsing and slow OCR
            // (for broken PDFs). Run off the main actor, posting progress.
            let results = InvoiceExtractor.extractAll(paths: inputs) { done, total, name in
                Task { @MainActor in
                    self.extractStatus = "提取中 \(done)/\(total): \(name)"
                }
            }
            let debug = inputs.map { InvoiceExtractor.debugText(at: $0) }
            await MainActor.run {
                self.invoiceResults = results
                self.invoiceDebugTexts = debug
                self.isExtracting = false
                self.extractStatus = ""
                self.showInvoiceDialog = true
            }
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
