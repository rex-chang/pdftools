import Foundation
import PDFKit

/// Low-level text tokenisation for invoice parsing.
///
/// Converts a PDFDocument into positioned text tokens and groups them into
/// lines by Y-coordinate — the foundation the parser builds on. Extracted
/// from InvoiceExtractor so the tokeniser (pure PDFKit→tokens work) is
/// separate from the parser (heuristic field extraction).
enum InvoiceTokenizer {

    /// Y tolerance for grouping text-layer tokens into a line, in PDF points.
    static let textLineTolerance: CGFloat = 3
    /// Y tolerance for grouping OCR tokens into a line, in normalised (0..1)
    /// space. 0.015 ≈ 3pt on a typical invoice height (~792pt).
    static let ocrLineTolerance: CGFloat = 0.015

    /// A positioned text fragment, matching Go's `pdf.Text{X, Y, S}`.
    struct Token {
        let x: CGFloat
        let y: CGFloat
        var s: String
    }

    /// A line of tokens grouped by Y coordinate.
    struct Line {
        var y: CGFloat
        var tokens: [Token]
        /// Concatenated text (no spaces between tokens).
        var text: String { tokens.map(\.s).joined() }
        /// Text with spaces collapsed.
        var compact: String { text.replacingOccurrences(of: " ", with: "") }
    }

    /// Build lines from a PDFDocument via per-character bounds, then merge
    /// stray ¥ tokens and group by Y. This is the text-layer path (fast).
    static func buildLines(_ doc: PDFDocument) -> [Line] {
        var tokens: [Token] = []
        for pi in 0..<doc.pageCount {
            guard let page = doc.page(at: pi) else { continue }
            let n = page.numberOfCharacters
            guard n > 0, let str = page.string else { continue }
            let chars = Array(str)

            var word = ""
            var minX: CGFloat = .greatestFiniteMagnitude
            var minY: CGFloat = .greatestFiniteMagnitude
            func flush() {
                let t = word.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty {
                    tokens.append(Token(x: minX, y: minY, s: word))
                }
                word = ""
                minX = .greatestFiniteMagnitude
                minY = .greatestFiniteMagnitude
            }
            for i in 0..<n {
                let c = chars[i]
                if c.isWhitespace {
                    flush()
                } else {
                    let b = page.characterBounds(at: i)
                    if b.minX < minX { minX = b.minX }
                    if b.minY < minY { minY = b.minY }
                    word.append(c)
                }
            }
            flush()
        }

        // Merge stray ¥ with following digits on the same line.
        tokens = mergeYenTokens(tokens)

        return groupIntoLines(tokens, tolerance: textLineTolerance)
    }

    /// Group pre-sorted tokens into lines by Y (tolerance `tolerance`),
    /// with tokens sorted by X within each line. Tokens are first sorted by
    /// Y descending (top of page first, matching PDFKit's flipped coords),
    /// then X ascending. Shared by the text-layer and OCR paths.
    static func groupIntoLines(_ tokens: [Token], tolerance: CGFloat) -> [Line] {
        let sorted = tokens.sorted { (a: Token, b: Token) -> Bool in
            if abs(a.y - b.y) > tolerance { return a.y > b.y }
            return a.x < b.x
        }
        var lines: [Line] = []
        var cur = Line(y: 0, tokens: [])
        for t in sorted {
            if cur.tokens.isEmpty || abs(t.y - cur.y) <= tolerance {
                if cur.tokens.isEmpty { cur.y = t.y }
                cur.tokens.append(t)
            } else {
                cur.tokens.sort { $0.x < $1.x }
                lines.append(cur)
                cur = Line(y: t.y, tokens: [t])
            }
        }
        if !cur.tokens.isEmpty {
            cur.tokens.sort { $0.x < $1.x }
            lines.append(cur)
        }
        return lines
    }

    /// Merge "¥" tokens with the digit token immediately to their right on
    /// the same line → "¥2000.00". Also handles "¥" + "2000.00" sitting at
    /// the same x (overlapping). Returns tokens re-sorted by (y, x).
    static func mergeYenTokens(_ tokens: [Token]) -> [Token] {
        // Group by line first (same y within tolerance).
        var byLine: [[Token]] = []
        var cur: [Token] = []
        var curY: CGFloat = 0
        let sorted = tokens.sorted { abs($0.y - $1.y) > 3 ? $0.y > $1.y : $0.x < $1.x }
        for t in sorted {
            if cur.isEmpty || abs(t.y - curY) <= 3 {
                if cur.isEmpty { curY = t.y }
                cur.append(t)
            } else {
                byLine.append(cur); cur = [t]; curY = t.y
            }
        }
        if !cur.isEmpty { byLine.append(cur) }

        var result: [Token] = []
        for var line in byLine {
            line.sort { $0.x < $1.x }
            var merged: [Token] = []
            var i = 0
            while i < line.count {
                let t = line[i]
                if t.s == "¥" {
                    // Find the next non-¥ token within a reasonable x gap.
                    if i + 1 < line.count,
                       let amt = InvoiceParser.leadingAmount(in: line[i + 1].s) {
                        merged.append(Token(x: t.x, y: t.y, s: "¥" + amt))
                        i += 2
                        continue
                    }
                }
                merged.append(t)
                i += 1
            }
            result.append(contentsOf: merged)
        }
        return result
    }
}
