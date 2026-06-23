import Foundation
import PDFKit

/// Entry point for invoice extraction. Coordinates the tokeniser
/// (`InvoiceTokenizer`) and parser (`InvoiceParser`), plus the OCR fallback
/// (`InvoiceOCR`). Keeps only the high-level flow + I/O here; all parsing
/// heuristics live in `InvoiceParser`.
///
/// (InvoiceData itself lives in Models/InvoiceData.swift.)
enum InvoiceExtractor {

    /// Extract from a single PDF. Always returns an `InvoiceData`; on failure
    /// the result's `errorMessage` explains what went wrong.
    static func extract(at path: String) -> InvoiceData {
        let name = (path as NSString).lastPathComponent
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else {
            return InvoiceData(fileName: name, errorMessage: "无法打开(文件损坏或不存在)")
        }
        if doc.isEncrypted && !doc.unlock(withPassword: "") {
            return InvoiceData(fileName: name, errorMessage: "PDF 已加密(需要密码)")
        }
        if doc.pageCount == 0 {
            return InvoiceData(fileName: name, errorMessage: "PDF 无页面")
        }

        // 1) Text-layer path.
        let lines = InvoiceTokenizer.buildLines(doc)
        if !lines.isEmpty {
            var oriented = lines
            if InvoiceParser.needsFlip(oriented) { oriented.reverse() }
            var inv = InvoiceData(fileName: name)
            InvoiceParser.parse(lines: oriented, into: &inv)
            // Only accept the text-layer result if it found the key amount;
            // otherwise fall through to OCR.
            if !inv.totalWithTax.isEmpty {
                return inv
            }
        }

        // 2) OCR fallback (slow, but rescues broken/inverted text PDFs).
        if let ocrResult = extractFromOCR(doc: doc, fileName: name), !ocrResult.totalWithTax.isEmpty {
            return ocrResult
        }

        return InvoiceData(fileName: name, errorMessage: "无法识别(文本层为空且 OCR 无结果)")
    }

    /// Build lines from OCR tokens and parse them. OCR tokens use normalised
    /// (0..1) bottom-left coords; convert to the y-descending reading order
    /// the parser expects, then reuse `InvoiceParser.parse`.
    private static func extractFromOCR(doc: PDFDocument, fileName: String) -> InvoiceData? {
        guard let ocrTokens = InvoiceOCR.recognise(doc: doc) else { return nil }

        // Vision's boundingBox uses bottom-left origin, so reading order
        // (top first) = DESCENDING normY; use (1 - normY) so larger y =
        // lower on page. No ¥-merge needed: Vision emits "¥2000.00" as one
        // token.
        let tokens: [InvoiceTokenizer.Token] = ocrTokens.map {
            InvoiceTokenizer.Token(x: $0.normX, y: 1.0 - $0.normY, s: $0.s)
        }
        let lines = InvoiceTokenizer.groupIntoLines(tokens, tolerance: InvoiceTokenizer.ocrLineTolerance)
        guard !lines.isEmpty else { return nil }

        var inv = InvoiceData(fileName: fileName)
        InvoiceParser.parse(lines: lines, into: &inv)
        return inv
    }

    // MARK: Batch + debug

    static func extractAll(paths: [String]) -> [InvoiceData] {
        extractAll(paths: paths, progress: nil)
    }

    /// Extract from all paths, calling `progress` (on an arbitrary queue)
    /// after each file completes. Checks `Task.isCancelled` between files so
    /// a cancelled extraction returns partial results.
    static func extractAll(paths: [String],
                           progress: ((Int, Int, String) -> Void)?) -> [InvoiceData] {
        var results: [InvoiceData] = []
        let total = paths.count
        for (i, p) in paths.enumerated() {
            if Task.isCancelled { break }
            let name = (p as NSString).lastPathComponent
            results.append(extract(at: p))
            progress?(i + 1, total, name)
        }
        return results
    }

    /// Raw plain text of a PDF (for the "原始文本" debug view).
    static func debugText(at path: String) -> String {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else { return "" }
        return (0..<doc.pageCount).compactMap { doc.page(at: $0)?.string }.joined(separator: "\n")
    }
}
