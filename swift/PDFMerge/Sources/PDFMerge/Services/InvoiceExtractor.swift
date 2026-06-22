import Foundation
import PDFKit

/// Invoice price/tax data. Mirrors Go `pdf.InvoiceData`.
struct InvoiceData: Identifiable {
    let id = UUID()
    let fileName: String
    var type: String = ""
    var totalWithTax: String = ""
    var totalBefore: String = ""
    var taxAmount: String = ""

    var isEmpty: Bool {
        totalWithTax.isEmpty && totalBefore.isEmpty && taxAmount.isEmpty
    }

    static let csvHeader = ["文件名", "类型", "价税合计", "金额(不含税)", "税额"]

    var csvRow: [String] {
        [fileName, type, totalWithTax, totalBefore, taxAmount]
    }
}

/// Extract invoice price/tax info from PDFs.
///
/// Port of Go `pdf/invoice.go`. The Go version used `ledongthuc/pdf`'s
/// `GetStyledTexts()` which returns text blocks with (X, Y) coordinates.
/// PDFKit exposes per-word selections with `bounds(for:)` instead, so we
/// enumerate words and group them into lines by `minY` (tolerance 2pt),
/// matching the Go algorithm. PDFKit's coordinate origin is the top-left
/// (flipped), the same convention ledongthuc uses, so line ordering is
/// consistent.
enum InvoiceExtractor {

    /// Extract from a single PDF.
    static func extract(at path: String) -> InvoiceData? {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else { return nil }
        var blocks = collectBlocks(doc)
        var inv = InvoiceData(fileName: (path as NSString).lastPathComponent)
        parse(blocks: &blocks, into: &inv)
        return inv
    }

    /// Extract from many PDFs, always returning one row per input
    /// (failures surface as a row whose totalWithTax carries the error).
    static func extractAll(paths: [String]) -> [InvoiceData] {
        paths.map { p in
            if let inv = extract(at: p) {
                return inv
            }
            var fail = InvoiceData(fileName: (p as NSString).lastPathComponent)
            fail.totalWithTax = "失败: 无法读取"
            return fail
        }
    }

    /// Raw plain text of a PDF (for the "原始文本" debug view).
    static func debugText(at path: String) -> String {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else { return "" }
        return (0..<doc.pageCount).compactMap { doc.page(at: $0)?.string }.joined(separator: "\n")
    }

    // MARK: - Internals

    /// A positioned text fragment, matching Go's `pdf.Text{X, Y, S}`.
    private struct Block {
        let x: CGFloat
        let y: CGFloat
        let s: String
    }

    /// Collect (x, y, string) for every word across all pages.
    ///
    /// Implementation note: `PDFSelection.enumerateWords(_:)` is documented
    /// but unreliable across SDKs, so we iterate per-character ranges via
    /// `PDFPage.characterBounds(at:)` / `selection(from:to:)` and group
    /// consecutive characters into "words" using the whitespace in the
    /// page's plain text. Y is normalised across pages by accumulating page
    /// heights, so a multi-page invoice groups lines the same way a single
    /// page does.
    private static func collectBlocks(_ doc: PDFDocument) -> [Block] {
        var blocks: [Block] = []
        var yOffset: CGFloat = 0
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let pageBounds = page.bounds(for: .mediaBox)
            let count = page.numberOfCharacters
            guard count > 0, let fullString = page.string else {
                yOffset += pageBounds.height + 20
                continue
            }
            let chars = Array(fullString)
            var currentWord = ""
            var wordBoundsMinX: CGFloat = .greatestFiniteMagnitude
            var wordBoundsMaxY: CGFloat = 0   // flipped coords: larger Y = higher on page

            func flush() {
                let trimmed = currentWord.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { currentWord = ""; return }
                let midX = wordBoundsMinX
                blocks.append(Block(x: midX,
                                    y: yOffset + wordBoundsMaxY,
                                    s: currentWord))
                currentWord = ""
                wordBoundsMinX = .greatestFiniteMagnitude
                wordBoundsMaxY = 0
            }

            for idx in 0..<count {
                let ch = chars[idx]
                let b = page.characterBounds(at: idx)
                if ch.isWhitespace {
                    flush()
                } else {
                    if b.minX < wordBoundsMinX { wordBoundsMinX = b.minX }
                    if b.maxY > wordBoundsMaxY { wordBoundsMaxY = b.maxY }
                    currentWord.append(ch)
                }
            }
            flush()
            yOffset += pageBounds.height + 20
        }
        return blocks
    }

    /// Group blocks into lines (Y desc, then X asc), then run keyword/amount
    /// extraction. Direct port of Go `parse()`.
    private static func parse(blocks: inout [Block], into inv: inout InvoiceData) {
        // Sort: Y descending, X ascending within the same line.
        blocks.sort { a, b in
            if abs(a.y - b.y) > 2.0 { return a.y > b.y }
            return a.x < b.x
        }

        // Group into lines by Y (tolerance 2pt).
        struct Line { let y: CGFloat; var blocks: [Block] }
        var lines: [Line] = []
        var current = Line(y: 0, blocks: [])
        for b in blocks {
            if current.blocks.isEmpty {
                current = Line(y: b.y, blocks: [b])
            } else if abs(b.y - current.y) <= 2.0 {
                current.blocks.append(b)
            } else {
                lines.append(current)
                current = Line(y: b.y, blocks: [b])
            }
        }
        if !current.blocks.isEmpty { lines.append(current) }

        // Full concatenated text for type extraction.
        let allText = lines.map { $0.blocks.map(\.s).joined() }.joined(separator: "\n")
        inv.type = findType(in: allText)

        let amountRe = try! NSRegularExpression(pattern: "\\d+\\.\\d+")

        for line in lines {
            let text = line.blocks.map(\.s).joined()
            let compact = text.replacingOccurrences(of: " ", with: "")

            // "合计" line but NOT "价税合计": 金额 and 税额 columns.
            if compact.contains("合计") && !compact.contains("价税合计") {
                let nums = extractLineAmounts(line.blocks, amountRe: amountRe)
                if nums.count >= 1 { inv.totalBefore = nums[0] }
                if nums.count >= 2 { inv.taxAmount = nums[1] }
            }

            // "价税合计" line: the grand total.
            if text.contains("价税合计") || compact.contains("价税合计") {
                let nums = extractLineAmounts(line.blocks, amountRe: amountRe)
                if let first = nums.first { inv.totalWithTax = first }
            }
        }

        // Fallback: if 价税合计 not found, take the last amount that isn't
        // already accounted for.
        if inv.totalWithTax.isEmpty {
            let allAmounts = amountRe.matches(in: allText, range: NSRange(allText.startIndex..., in: allText))
                .map { String(allText[Range($0.range, in: allText)!]) }
            for amt in allAmounts.reversed() where amt != inv.totalBefore && amt != inv.taxAmount {
                inv.totalWithTax = amt
                break
            }
        }
    }

    /// All ¥-prefixed decimal amounts on a line, in X order.
    /// Direct port of Go `extractLineAmounts`.
    private static func extractLineAmounts(_ blocks: [Block], amountRe: NSRegularExpression) -> [String] {
        let sorted = blocks.sorted { $0.x < $1.x }
        let fullText = sorted.map(\.s).joined()

        // First try: ¥amount patterns from the full line text.
        let yenRe = try! NSRegularExpression(pattern: "¥\\s*([\\d,]+(?:\\.\\d+)?)")
        let yenMatches = yenRe.matches(in: fullText, range: NSRange(fullText.startIndex..., in: fullText))
        if !yenMatches.isEmpty {
            return yenMatches.compactMap { m -> String? in
                guard let r = Range(m.range(at: 1), in: fullText) else { return nil }
                return String(fullText[r]).replacingOccurrences(of: ",", with: "")
            }
        }

        // Fallback: ¥ symbol and number in separate blocks.
        var results: [String] = []
        var seenYen = false
        for b in sorted {
            let s = b.s.trimmingCharacters(in: .whitespaces)
            if s == "¥" {
                seenYen = true
                continue
            }
            if seenYen {
                if let r = amountRe.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                   let range = Range(r.range, in: s) {
                    results.append(String(s[range]))
                }
                seenYen = false
            }
        }
        if results.isEmpty {
            for b in sorted {
                let s = b.s.trimmingCharacters(in: .whitespaces)
                if let r = amountRe.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                   let range = Range(r.range, in: s) {
                    results.append(String(s[range]))
                }
            }
        }
        return results
    }

    /// Invoice type: content wrapped in *asterisks*. Port of Go `findType`.
    private static func findType(in text: String) -> String {
        guard let r = text.range(of: "\\*[^*]+\\*", options: .regularExpression) else { return "" }
        let matched = String(text[r])
        return matched.trimmingCharacters(in: CharacterSet(charactersIn: "*"))
    }
}
