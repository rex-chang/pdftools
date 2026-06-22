import Foundation
import PDFKit

/// Invoice price/tax data. Mirrors Go `pdf.InvoiceData`.
struct InvoiceData: Identifiable {
    let id = UUID()
    let fileName: String
    var type: String = ""   // 类型
    var totalWithTax: String = ""   // 价税合计
    var totalBefore: String = ""    // 金额(不含税)
    var taxAmount: String = ""      // 税额
    /// Populated only when extraction failed. Surfaced in the UI so the
    /// user knows *why* a row is empty (encrypted? OCR found nothing?).
    var errorMessage: String = ""

    /// True when extraction produced no usable totals (either failed or
    /// genuinely empty). Used to drive summary-bar accounting.
    var failed: Bool { !errorMessage.isEmpty }

    static let csvHeader = ["文件名", "类型", "价税合计", "金额(不含税)", "税额", "备注"]

    var csvRow: [String] {
        [fileName, type, totalWithTax, totalBefore, taxAmount, errorMessage]
    }
}

/// Extract invoice price/tax info from Chinese electronic invoices (电子发票).
///
/// Strategy: these invoices share a stable layout — a table with columns
/// 金额 / 税额, a 合计 row summing them, and a 价税合计 line giving the
/// grand total. The exact placement varies by template (keyword and amount
/// may share a line, or the amount may sit on an adjacent line; ¥ and the
/// digits may be separate fragments). So we:
///
/// 1. Tokenise every character via `PDFPage.characterBounds(at:)` and group
///    into words, carrying (x, y) for each.
/// 2. Merge stray "¥" tokens with the digits that follow them on the same
///    line, so "¥" + "2000.00" becomes a single "¥2000.00" token.
/// 3. Group tokens into lines by Y (tolerance 3pt).
/// 4. Anchor on keywords:
///    - 合计 (but NOT 价税合计): the line's ¥-amounts → [金额, 税额].
///      If the keyword line has no amounts, scan the immediately adjacent
///      line (the one below it in reading order).
///    - 价税合计: take the ¥-amount from the keyword line, or the adjacent
///      line in reading order.
/// 5. Type: the *star-wrapped* goods name(s) on the line above 合计.
///
/// Coordinate convention: PDFKit's characterBounds origin is the BOTTOM-LEFT
/// of the page, so "reading order" (top-to-bottom) corresponds to DECREASING
/// `minY`... but in practice the bounds returned here are in the flipped
/// (top-left origin) space, so we sort lines by DESCENDING y for reading
/// order. We empirically verify orientation by checking that the title
/// ("电子发票") lands on the last line.
enum InvoiceExtractor {

    // Tunables (extracted from inline magic numbers).
    /// Y tolerance for grouping text-layer tokens into a line, in PDF points.
    private static let textLineTolerance: CGFloat = 3
    /// Y tolerance for grouping OCR tokens into a line, in normalised (0..1)
    /// space. 0.015 ≈ 3pt on a typical invoice height (~792pt).
    private static let ocrLineTolerance: CGFloat = 0.015
    /// When matching 金额+税额 pairs against 价税合计, accept a pair whose sum
    /// is within this many units (rounding tolerance, in 元).
    private static let sumMatchTolerance: Double = 0.02

    /// Extract from a single PDF. Always returns an `InvoiceData`; on failure
    /// the result's `errorMessage` explains what went wrong (so the UI can
    /// distinguish "encrypted" from "OCR found nothing" etc.).
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
        let lines = buildLines(doc)
        if !lines.isEmpty {
            var oriented = lines
            if needsFlip(oriented) { oriented.reverse() }
            var inv = InvoiceData(fileName: name)
            parse(lines: oriented, into: &inv)
            // Only accept the text-layer result if it actually found the key
            // amount. If 价税合计 is empty the text layer is unusable
            // (corrupted/unreadable) — fall through to OCR.
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

    /// Build lines from OCR tokens and parse them. Coordinate handling: OCR
    /// gives normalised (0..1) bottom-left origin; we convert to the same
    /// "y descends top-to-bottom" reading order the text-layer path uses,
    /// then reuse `parse`.
    private static func extractFromOCR(doc: PDFDocument, fileName: String) -> InvoiceData? {
        guard let ocrTokens = InvoiceOCR.recognise(doc: doc) else { return nil }

        // Convert to internal Token. Vision's boundingBox uses bottom-left
        // origin, so reading order (top first) = DESCENDING normY; keep that
        // as our y by using (1 - normY) so larger y = lower on page.
        //
        // No ¥-token merging needed here: Vision already emits "¥2000.00"
        // as a single token (unlike the text-layer path, where ¥ and the
        // digits can be separate fragments).
        let tokens: [Token] = ocrTokens.map {
            Token(x: $0.normX, y: 1.0 - $0.normY, s: $0.s)
        }
        let lines = groupIntoLines(tokens, tolerance: ocrLineTolerance)
        guard !lines.isEmpty else { return nil }

        var inv = InvoiceData(fileName: fileName)
        parse(lines: lines, into: &inv)
        return inv
    }

    static func extractAll(paths: [String]) -> [InvoiceData] {
        extractAll(paths: paths, progress: nil)
    }

    /// Extract from all paths, calling `progress` (on an arbitrary queue)
    /// after each file completes with (doneCount, totalCount, currentFileName).
    /// The progress callback lets the UI show "提取中 3/12" while OCR grinds
    /// through a stack of broken PDFs.
    ///
    /// Checks `Task.isCancelled` between files so a cancelled extraction
    /// returns whatever was completed so far rather than continuing.
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


    static func debugText(at path: String) -> String {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else { return "" }
        return (0..<doc.pageCount).compactMap { doc.page(at: $0)?.string }.joined(separator: "\n")
    }

    // MARK: - Tokenising

    private struct Token {
        let x: CGFloat
        let y: CGFloat
        var s: String
    }
    private struct Line {
        var y: CGFloat
        var tokens: [Token]
        /// Concatenated text (no spaces between tokens).
        var text: String { tokens.map(\.s).joined() }
        /// Text with spaces collapsed.
        var compact: String { text.replacingOccurrences(of: " ", with: "") }
    }

    private static func buildLines(_ doc: PDFDocument) -> [Line] {
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
    private static func groupIntoLines(_ tokens: [Token], tolerance: CGFloat) -> [Line] {
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
    private static func mergeYenTokens(_ tokens: [Token]) -> [Token] {
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
                       let amt = leadingAmount(in: line[i + 1].s) {
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

    /// If `s` starts with a decimal number, return it; else nil.
    private static let leadingAmountRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: "^-?[\\d,]+(?:\\.\\d+)?")
    }()

    private static func leadingAmount(in s: String) -> String? {
        let ns = s as NSString
        guard let m = leadingAmountRegex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              m.range.length > 0 else { return nil }
        return ns.substring(with: m.range).replacingOccurrences(of: ",", with: "")
    }

    // MARK: - Orientation

    /// Detect whether lines are currently in reading order (title last, since
    /// we sort y descending and PDFKit uses flipped coords → title at bottom).
    /// If the FIRST line looks like the title region, no flip needed.
    /// If the LAST line looks like the title, flip.
    private static func needsFlip(_ lines: [Line]) -> Bool {
        guard let first = lines.first, let last = lines.last else { return false }
        // The title "电子发票" should be near the BOTTOM in our y-descending
        // sort (flipped coords). If it's on the first line instead, the page
        // used unflipped coords and we must flip.
        let titleAppearsFirst = first.compact.contains("电子发票") || first.compact.contains("发票号码")
        let titleAppearsLast = last.compact.contains("电子发票") || last.compact.contains("发票号码")
        // We want title LAST (end of array). Flip if it's first.
        return titleAppearsFirst && !titleAppearsLast
    }

    // MARK: - Parsing

    private static func parse(lines: [Line], into inv: inout InvoiceData) {
        // 1) Type: scan for *star-wrapped* goods name(s). Take the LAST one
        //    before the 合计 line (closest to the actual totals). Go only
        //    took the first match, which dropped the second half of names
        //    like "*生产生活服务*餐费".
        var typeCandidate = ""
        var totalLineIdx: Int? = nil
        for (i, line) in lines.enumerated() {
            if let t = extractType(in: line.text), !t.isEmpty {
                typeCandidate = t
            }
            // Identify the 合计 line. Cases this must handle:
            //  - "合 计 ¥a ¥b"  (合/计 separated by a space)
            //  - "合 ¥a 计 ¥b"  (合/计 split across columns by amounts)
            //  - "...合计¥a¥b价税合计（大写）..."  (合计 AND 价税合计 merged
            //    into one line by Y-grouping — common when the two rows are
            //    vertically close). The old `!contains("价税合计")` guard
            //    wrongly rejected this whole line, losing the 合计 amounts.
            //
            // New rule: a line is the 合计 line if it contains 合 and 计
            // (in either order, possibly far apart) AND has at least one
            // ¥-amount candidate. The 价税合计-only line has no ¥ on itself
            // (its amount is on a neighbour), so this naturally excludes it.
            if line.compact.contains("合") && line.compact.contains("计")
                && !amountCandidates(in: line).isEmpty {
                if totalLineIdx == nil { totalLineIdx = i }
            }
        }
        inv.type = typeCandidate

        // 2) 价税合计 from the 价税合计 line (or its neighbour).
        //
        // The grand-total amount can sit on the keyword line, the line ABOVE
        // it, or the line BELOW it — templates differ (the Chinese-capital
        // line "贰佰…" + ¥xxx is usually adjacent to the 价税合计 label).
        // Scan outward in reading order and take the first ¥-amount found.
        // Resolved BEFORE 金额/税额 so the latter can use it as a constraint.
        for (i, line) in lines.enumerated() where line.text.contains("价税合计") {
            var amt = yenAmounts(in: line)
            // If the keyword line has a stray "¥" token but no ¥-prefixed
            // amount, the number is likely sitting on a nearby line whose
            // Y differed slightly (PDF baseline jitter splits ¥ and digits
            // into separate lines). Scan a wider neighbourhood for the
            // closest bare decimal to the ¥'s x position.
            if amt.isEmpty && hasStrayYen(in: line) {
                if let picked = nearestBareAmountToYen(in: lines, around: i) {
                    amt = [picked]
                }
            }
            if amt.isEmpty {
                let neighbours = [i - 1, i + 1, i - 2, i + 2].filter { $0 >= 0 && $0 < lines.count }
                for j in neighbours {
                    let a = yenAmounts(in: lines[j])
                    if !a.isEmpty { amt = a; break }
                }
            }
            if let total = amt.first {
                inv.totalWithTax = total
                break
            }
        }

        // Fallback if 价税合计 still empty: take the largest ¥-amount on the
        // page (the grand total is the biggest single ¥ value).
        if inv.totalWithTax.isEmpty {
            var best: Double = -1
            var bestStr = ""
            for line in lines {
                for a in yenAmounts(in: line) {
                    if let v = Double(a), v > best { best = v; bestStr = a }
                }
            }
            inv.totalWithTax = bestStr
        }

        // 3) 金额 / 税额 from the 合计 line.
        //
        // The 合计 row sums the 金额 (ex-tax) and 税额 (tax) columns. Cells
        // may or may not carry ¥. We collect ALL amount candidates on the
        // 合计 line (and its neighbour if empty), then pick the pair whose
        // sum best matches the 价税合计 — this disambiguates stray unit
        // prices (e.g. a leftover "27.85" from the goods row above) from
        // the real column totals.
        if let idx = totalLineIdx {
            var candidates = amountCandidates(in: lines[idx])
            if candidates.count < 2, idx + 1 < lines.count {
                let below = amountCandidates(in: lines[idx + 1])
                if below.count > candidates.count {
                    candidates = below
                }
            }
            if candidates.count >= 2 {
                let (before, tax) = pickAmountPair(candidates, totalWithTax: inv.totalWithTax)
                inv.totalBefore = before
                inv.taxAmount = tax
            } else if candidates.count == 1 {
                inv.totalBefore = candidates[0].amount
            }
        }

        // 4) Sanity check: 价税合计 must be ≥ both 金额 and 税额 (it's their
        //    sum, so it can't be smaller than either). When the 价税合计 line
        //    had a stray ¥ next to a leftover tax-amount from the 合计 row
        //    (a common Y-jitter artifact), we'll have picked that small tax
        //    value as the grand total. Detect and replace with the largest
        //    ¥-amount on the page, which for a sane invoice IS the grand total.
        reconcileTotalWithTax(lines: lines, into: &inv)
    }

    /// If `totalWithTax` is missing or implausibly small (< 金额 or < 税额),
    /// replace it with the largest ¥-amount on the page. The grand total is
    /// always the biggest single ¥ value on an invoice, so this is a safe
    /// fallback when the keyword-line extraction grabbed the wrong number.
    private static func reconcileTotalWithTax(lines: [Line], into inv: inout InvoiceData) {
        let before = Double(inv.totalBefore) ?? 0
        let tax = Double(inv.taxAmount) ?? 0
        let current = Double(inv.totalWithTax) ?? 0
        let plausible = current >= before && current >= tax && current > 0
        if plausible { return }

        // Expected grand total = 金额 + 税额 (within rounding). Use it to
        // guide the search: the right candidate should match this sum.
        let expected = before + tax

        // Pass 1: largest ¥-tagged amount anywhere on the page.
        var bestYen: Double = -1
        var bestYenStr = ""
        for line in lines {
            for t in line.tokens where t.s.hasPrefix("¥") {
                let rest = String(t.s.dropFirst()).replacingOccurrences(of: ",", with: "")
                if let amt = leadingAmount(in: rest), let v = Double(amt), v > bestYen {
                    bestYen = v
                    bestYenStr = amt
                }
            }
        }

        // Pass 2: a bare decimal matching the expected sum (handles the
        // "¥ 218.60" case where ¥ and digits were split by Y-jitter, so the
        // grand total exists only as a bare number on the page).
        var bestBareMatch: Double = -1
        var bestBareMatchStr = ""
        if expected > 0 {
            for line in lines {
                for t in line.tokens where !t.s.hasPrefix("¥") {
                    guard let amt = leadingAmount(in: t.s), let v = Double(amt) else { continue }
                    if abs(v - expected) < 0.5 && v > bestBareMatch {
                        bestBareMatch = v
                        bestBareMatchStr = amt
                    }
                }
            }
        }

        // Prefer the bare amount that matches 金额+税额 (most reliable signal);
        // otherwise fall back to the largest ¥-tagged amount.
        if !bestBareMatchStr.isEmpty {
            inv.totalWithTax = bestBareMatchStr
        } else if !bestYenStr.isEmpty {
            inv.totalWithTax = bestYenStr
        }
    }

    /// All ¥-prefixed amounts on a line, in x order. Returns ["2000.00", "0.00"]
    /// for "¥2000.00 ¥0.00".
    private static func yenAmounts(in line: Line) -> [String] {
        var out: [String] = []
        for t in line.tokens {
            if t.s.hasPrefix("¥") {
                let rest = String(t.s.dropFirst()).replacingOccurrences(of: ",", with: "")
                if let amt = leadingAmount(in: rest) { out.append(amt) }
            }
        }
        return out
    }

    /// True if the line has a lone "¥" token not followed by digits on the
    /// same line — i.e. the amount symbol is present but its number was
    /// split onto another line by Y-jitter.
    private static func hasStrayYen(in line: Line) -> Bool {
        line.tokens.contains { $0.s == "¥" }
    }

    /// When a stray "¥" sits on the 价税合计 line but its digits landed on a
    /// different line (Y-jitter), search nearby lines for the bare decimal
    /// closest in x to the ¥ symbol and return it. Considers lines within
    /// ±3 indices and picks the candidate with the smallest x-distance to
    /// any "¥" on the anchor line.
    private static func nearestBareAmountToYen(in lines: [Line], around anchorIdx: Int) -> String? {
        let anchor = lines[anchorIdx]
        let yenXs = anchor.tokens.filter { $0.s == "¥" }.map(\.x)
        guard !yenXs.isEmpty else { return nil }

        var best: (dist: CGFloat, value: String)? = nil
        for offset in [-1, 1, -2, 2, -3, 3] {
            let j = anchorIdx + offset
            guard j >= 0, j < lines.count else { continue }
            for t in lines[j].tokens {
                // Skip ¥-tagged amounts (handled elsewhere) and non-amounts.
                if t.s.hasPrefix("¥") { continue }
                guard let amt = leadingAmount(in: t.s), amt != "0", amt != "0.0", amt != "0.00" else { continue }
                // Distance to the nearest ¥ on the anchor line.
                let dist = yenXs.map { abs($0 - t.x) }.min() ?? .greatestFiniteMagnitude
                if best == nil || dist < best!.dist {
                    best = (dist, amt)
                }
            }
        }
        // Only accept if reasonably close in x (within 120pt). A ¥ symbol
        // and its number can be on opposite sides of a "（小写）" label in
        // some templates, hence the generous threshold; tighter would miss
        // real pairs.
        if let b = best, b.dist <= 120 {
            return b.value
        }
        return nil
    }

    /// An amount found on a line, with its x position and whether it carried ¥.
    private struct AmountCandidate {
        let x: CGFloat
        let amount: String
        let hasYen: Bool
        var value: Double? { Double(amount) }
    }

    /// Every decimal amount on a line in x order — both ¥-prefixed and bare.
    /// Bare candidates skip tax-rate tokens like "6%", "3%", "0.06" and the
    /// literal "0". ¥-tagged candidates are always kept.
    private static func amountCandidates(in line: Line) -> [AmountCandidate] {
        var out: [AmountCandidate] = []
        for t in line.tokens {
            if t.s.hasPrefix("¥") {
                let rest = String(t.s.dropFirst()).replacingOccurrences(of: ",", with: "")
                if let amt = leadingAmount(in: rest) {
                    out.append(AmountCandidate(x: t.x, amount: amt, hasYen: true))
                }
                continue
            }
            if t.s.contains("%") { continue }
            if let amt = leadingAmount(in: t.s), amt != "0" {
                out.append(AmountCandidate(x: t.x, amount: amt, hasYen: false))
            }
        }
        return out.sorted { $0.x < $1.x }
    }

    /// Pick the (金额, 税额) pair from candidates.
    ///
    /// Heuristics, in priority order:
    /// 1. If we know 价税合计, only consider pairs (i<j by x) whose sum
    ///    rounds to it. Among those, prefer the pair with MORE ¥-tagged
    ///    members (a stray bare unit price from the goods row above is the
    ///    usual contaminant; the real column totals are ¥-prefixed).
    /// 2. Tie-break by smaller numerical error, then by the pair whose 税额
    ///    (right member) is the smaller of the two (税额 < 金额 in practice).
    /// 3. If 价税合计 is unknown, take the rightmost two by x.
    private static func pickAmountPair(_ candidates: [AmountCandidate],
                                       totalWithTax: String) -> (String, String) {
        let target = Double(totalWithTax)
        let n = candidates.count
        guard n >= 2 else {
            return (candidates.first?.amount ?? "", "")
        }

        let fallback = (candidates[n - 2].amount, candidates[n - 1].amount)
        guard let target = target else { return fallback }

        var best: (String, String)? = nil
        var bestYenCount = -1
        var bestErr = Double.infinity
        var bestTaxSmaller = false

        for i in 0..<(n - 1) {
            for j in (i + 1)..<n {
                guard let vi = candidates[i].value, let vj = candidates[j].value else { continue }
                let err = abs((vi + vj) - target)
                if err >= sumMatchTolerance { continue }   // must round to 价税合计

                let yenCount = (candidates[i].hasYen ? 1 : 0) + (candidates[j].hasYen ? 1 : 0)
                let taxSmaller = vj <= vi     // 税额 (right col) ≤ 金额 (left col)

                // Priority: more ¥ tags, then tax ≤ amount, then smaller error.
                let better: Bool
                if best == nil { better = true }
                else if yenCount != bestYenCount { better = yenCount > bestYenCount }
                else if taxSmaller != bestTaxSmaller { better = taxSmaller && !bestTaxSmaller }
                else { better = err < bestErr }

                if better {
                    best = (candidates[i].amount, candidates[j].amount)
                    bestYenCount = yenCount
                    bestErr = err
                    bestTaxSmaller = taxSmaller
                }
            }
        }
        return best ?? fallback
    }

    /// Extract the goods type wrapped in *stars*. Returns the FULL matched
    /// span (e.g. "*生产生活服务*餐费"), with stars trimmed.
    private static let typeRegex: NSRegularExpression = {
        // One or more *delimited* segments glued together:
        //   *餐饮服务*餐饮服务  /  *生产生活服务*餐费  /  *预付卡销售*预付卡
        try! NSRegularExpression(pattern: "(?:\\*[^*]+\\*)+")
    }()

    private static func extractType(in text: String) -> String? {
        let ns = text as NSString
        guard let m = typeRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        let matched = ns.substring(with: m.range)
        return matched.trimmingCharacters(in: CharacterSet(charactersIn: "*"))
    }
}
