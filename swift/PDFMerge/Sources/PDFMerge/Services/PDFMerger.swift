import Foundation
import PDFKit

/// PDF operations. Mirrors Go `pdf/merge.go` and `pdf/preview.go`.
enum PDFMerger {
    /// Page count for a PDF file. Returns 0 on failure (matches Go behaviour
    /// where callers fall back to 0 on error).
    static func pageCount(at path: String) -> Int {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else { return 0 }
        return doc.pageCount
    }

    /// Merge `inputPaths` (in order) into `outputPath`.
    ///
    /// Uses PDFKit `PDFDocument` insertion. Files that fail to open
    /// (corrupt / encrypted) are skipped and reported in the returned list;
    /// at least one readable file is required.
    ///
    /// - Returns: `(mergedCount, skippedFiles)`. Throws only on total failure
    ///   (no readable inputs or final write error).
    struct MergeFailure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func merge(_ inputPaths: [String], to outputPath: String) throws -> (merged: Int, skipped: [String]) {
        let out = PDFDocument()
        var insertIndex = 0
        var skipped: [String] = []

        for path in inputPaths {
            // Cooperative cancellation: a cancelled Task aborts here instead
            // of grinding through the whole queue.
            try Task.checkCancellation()
            guard let doc = PDFDocument(url: URL(fileURLWithPath: path)),
                  doc.pageCount > 0 else {
                skipped.append((path as NSString).lastPathComponent)
                continue
            }
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i) {
                    out.insert(page, at: insertIndex)
                    insertIndex += 1
                }
            }
        }

        guard insertIndex > 0 else {
            throw MergeFailure(message: "没有可合并的 PDF 页面(全部文件读取失败)")
        }

        let outURL = URL(fileURLWithPath: outputPath)
        // Write to a temp file first, then move — atomic and avoids clobbering
        // an existing file with a half-written one.
        let tmpURL = outURL.deletingLastPathComponent()
            .appendingPathComponent(".~pdfmerge-tmp-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        guard out.write(to: tmpURL) else {
            throw MergeFailure(message: "写入 PDF 失败: \(outputPath)")
        }
        // Remove any pre-existing output file first. `try?` because on a
        // first-time merge the output won't exist yet — a plain `try`
        // would throw NSFileNoSuchFileError and abort the whole merge.
        try? FileManager.default.removeItem(at: outURL)
        try FileManager.default.moveItem(at: tmpURL, to: outURL)

        return (insertIndex, skipped)
    }
}
