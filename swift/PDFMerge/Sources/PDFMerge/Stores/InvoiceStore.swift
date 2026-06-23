import Foundation
import SwiftUI

/// Owns invoice extraction orchestration: results, dialog visibility, run
/// state (isExtracting/progress), and the extraction task lifecycle.
/// Depends on a `FileQueueStore` for the list of files to extract from.
@MainActor
final class InvoiceStore: ObservableObject {

    // MARK: Results + dialog

    @Published private(set) var invoiceResults: [InvoiceData] = []
    @Published var showInvoiceDialog: Bool = false
    /// Paths for the last extraction, kept so debug text can be computed
    /// lazily when the user opens the raw-text view (instead of opening
    /// every PDF twice during extraction).
    @Published private(set) var invoiceInputPaths: [String] = []

    // MARK: Run state

    @Published private(set) var isExtracting: Bool = false
    @Published private(set) var extractStatus: String = ""

    // MARK: Task lifecycle

    private var extractTask: Task<Void, Never>? = nil
    /// Generation tag: prevents a cancelled run's finish callback from
    /// overwriting a newer one (same pattern as MergeStore).
    private var generation: Int = 0

    private weak var fileQueue: FileQueueStore?

    init(fileQueue: FileQueueStore) {
        self.fileQueue = fileQueue
    }

    /// Whether extraction is currently allowed.
    var canExtract: Bool {
        guard let q = fileQueue else { return false }
        return !q.isEmpty && !isExtracting
    }

    // MARK: Extraction

    func extractInvoices() {
        guard let q = fileQueue, !q.isEmpty else { return }
        // Cancel any in-flight extraction and bump generation so its stale
        // finish callback won't overwrite this run's results.
        extractTask?.cancel()
        generation += 1
        let gen = generation
        let inputs = q.paths
        isExtracting = true
        extractStatus = "提取中 0/\(inputs.count)…"
        // `Task.detached` so OCR (1-3s per broken PDF) runs off the main
        // actor and progress updates actually reach the screen. Cancellation
        // is cooperative: extractAll checks Task.isCancelled between files.
        extractTask = Task.detached(priority: .userInitiated) { [weak self] in
            let results = InvoiceExtractor.extractAll(paths: inputs) { done, total, name in
                // Hop to the main actor for the UI update. (We do spawn one
                // short Task per progress callback — N small Tasks, not
                // ideal, but progress callbacks are infrequent: one per file.)
                Task { @MainActor in
                    self?.extractStatus = "提取中 \(done)/\(total): \(name)"
                }
            }
            await self?.finish(results: results, inputs: inputs, gen: gen)
        }
    }

    /// Cancel an in-flight extraction (cooperative — stops after the
    /// current file). No-op if nothing is running.
    func cancelExtraction() {
        extractTask?.cancel()
    }

    /// Compute debug text for a given file on demand (called when the user
    /// opens the "原始文本" view). Avoids the previous eager double-open of
    /// every PDF during extraction.
    func debugText(for path: String) -> String {
        InvoiceExtractor.debugText(at: path)
    }

    private func finish(results: [InvoiceData], inputs: [String], gen: Int) {
        // Stale callback from a cancelled extraction — ignore so we don't
        // overwrite a newer run's results.
        guard gen == generation else { return }
        invoiceResults = results
        // Keep the input paths around so debug text can be computed lazily
        // when the user opens the raw-text view.
        invoiceInputPaths = inputs
        isExtracting = false
        extractStatus = ""
        if !results.isEmpty {
            showInvoiceDialog = true
        }
    }
}
