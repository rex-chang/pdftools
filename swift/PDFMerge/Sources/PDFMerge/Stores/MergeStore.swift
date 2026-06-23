import Foundation
import SwiftUI

/// Owns merge orchestration: output settings, run state (isMerging/progress),
/// and the merge task lifecycle. Depends on a `FileQueueStore` for the list
/// of files to merge.
@MainActor
final class MergeStore: ObservableObject {

    // MARK: Output settings

    @Published var outputName: String
    @Published var outputDir: String

    // MARK: Run state

    @Published private(set) var statusText: String = ""
    @Published private(set) var statusVisible: Bool = false
    @Published private(set) var isMerging: Bool = false
    /// nil = indeterminate; 0..1 = bar.
    @Published private(set) var progressValue: Double? = nil
    /// Completion / error alert content. Non-nil triggers the alert.
    @Published var lastMessage: String? = nil
    /// Output URL of the most recent successful merge, so the success alert
    /// can offer "在 Finder 中显示". Nil until a merge succeeds.
    @Published private(set) var lastMergeOutput: URL? = nil

    // MARK: Task lifecycle

    private var mergeTask: Task<Void, Never>? = nil
    /// Monotonic generation tag. Each new merge() bumps it; finish callbacks
    /// carry the generation they were started with and bail out if it no
    /// longer matches. This prevents a cancelled task from stomping on the
    /// freshly-started merge's state when it eventually throws.
    private var generation: Int = 0

    /// Weak ref to the queue so merge can read its paths. Weak to avoid a
    /// retain cycle if the queue ever outlives the merge store.
    private weak var fileQueue: FileQueueStore?

    init(fileQueue: FileQueueStore) {
        self.fileQueue = fileQueue
        self.outputName = "合并_" + Self.timestamp() + ".pdf"
        self.outputDir = FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// Whether merging is currently allowed (≥2 files and not already running).
    var canMerge: Bool {
        guard let q = fileQueue else { return false }
        return q.count >= 2 && !isMerging
    }

    // MARK: Merge

    func merge() {
        guard let q = fileQueue, q.count >= 2 else {
            lastMessage = "请至少添加 2 个 PDF 文件"
            return
        }
        let dir = outputDir.trimmingCharacters(in: .whitespaces)
        var name = outputName.trimmingCharacters(in: .whitespaces)
        guard !dir.isEmpty, !name.isEmpty else {
            lastMessage = "输出路径为空"
            return
        }
        // Strip path separators and other characters macOS/Windows disallow
        // in filenames — otherwise "a/b.pdf" would be treated as a subpath
        // and write outside the chosen directory.
        let illegal = CharacterSet(charactersIn: "/\\:*?<>|")
        name = name.components(separatedBy: illegal).joined(separator: "-")
        // Ensure a .pdf extension so macOS treats the file as a PDF.
        if (name as NSString).pathExtension.lowercased() != "pdf" {
            name += ".pdf"
        }
        let outputPath = (dir as NSString).appendingPathComponent(name)

        // Cancel any in-flight merge (mirrors Go's context cancel swap).
        mergeTask?.cancel()
        // Bump generation so any in-flight finish callback from the previous
        // merge knows it's stale and won't overwrite our state.
        generation += 1
        let gen = generation

        let inputs = q.paths
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
                await self?.finishSuccess(result: result, name: name, outputPath: outputPath, gen: gen)
            } catch is CancellationError {
                await self?.finishCancelled(gen: gen)
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                await self?.finishError(message: msg, gen: gen)
            }
        }
    }

    /// Cancel an in-flight merge (cooperative — stops after the current
    /// file). No-op if nothing is running.
    func cancelMerge() {
        mergeTask?.cancel()
    }

    // MARK: Finish callbacks (generation-guarded)

    private func finishSuccess(result: (merged: Int, skipped: [String]), name: String, outputPath: String, gen: Int) {
        // Stale callback from a cancelled merge — ignore so we don't clobber
        // the newer merge's state.
        guard gen == generation else { return }
        isMerging = false
        progressValue = 1.0
        statusVisible = true
        lastMergeOutput = URL(fileURLWithPath: outputPath)
        var statusMsg = "已合并 \(result.merged) 页 → \(name)"
        if !result.skipped.isEmpty {
            statusMsg += "\n跳过 \(result.skipped.count) 个: " + result.skipped.joined(separator: ", ")
        }
        statusText = statusMsg
        lastMessage = "成功合并 \(result.merged) 页到:\n\(outputPath)"
    }

    private func finishCancelled(gen: Int) {
        guard gen == generation else { return }
        isMerging = false
        progressValue = nil
        statusVisible = false
        statusText = "已取消"
    }

    private func finishError(message: String, gen: Int) {
        guard gen == generation else { return }
        isMerging = false
        progressValue = nil
        statusVisible = true
        statusText = "错误: \(message)"
        lastMessage = "合并失败: \(message)"
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
