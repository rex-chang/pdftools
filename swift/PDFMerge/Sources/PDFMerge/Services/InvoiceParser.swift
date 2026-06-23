import Foundation

/// Heuristic field extraction for Chinese electronic invoices.
///
/// Operates on the lines produced by `InvoiceTokenizer` and pulls out the
/// type / 价税合计 / 金额 / 税额. Extracted from InvoiceExtractor so the
/// parsing heuristics are isolated, testable, and independent of PDFKit I/O.
///
/// Depends on `InvoiceTokenizer` for its `Token`/`Line` types (one-way
/// dependency: parser → tokenizer, never the reverse).
enum InvoiceParser {

    // MARK: Tunables

    /// When matching 金额+税额 pairs against 价税合计, accept a pair whose sum
    /// is within this many units (rounding tolerance, in 元).
    static let sumMatchTolerance: Double = 0.02

    // MARK: Regexes

    static let leadingAmountRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: "^-?[\\d,]+(?:\\.\\d+)?")
    }()

    static let typeRegex: NSRegularExpression = {
        // One or more *delimited* segments glued together:
        //   *餐饮服务*餐饮服务  /  *生产生活服务*餐费  /  *预付卡销售*预付卡
        try! NSRegularExpression(pattern: "(?:\\*[^*]+\\*)+")
    }()

    // MARK: Amount primitives

    /// If `s` starts with a decimal number, return it; else nil.
    static func leadingAmount(in s: String) -> String? {
        let ns = s as NSString
        guard let m = leadingAmountRegex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              m.range.length > 0 else { return nil }
        return ns.substring(with: m.range).replacingOccurrences(of: ",", with: "")
    }

    /// Extract the goods type wrapped in *stars*. Returns the matched span
    /// with stars trimmed (e.g. "*餐饮服务*" → "餐饮服务").
    static func extractType(in text: String) -> String? {
        let ns = text as NSString
        guard let m = typeRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        let matched = ns.substring(with: m.range)
        return matched.trimmingCharacters(in: CharacterSet(charactersIn: "*"))
    }

    // MARK: Amount candidates

    /// All ¥-prefixed amounts on a line, in x order. Returns ["2000.00", "0.00"]
    /// for "¥2000.00 ¥0.00".
    static func yenAmounts(in line: InvoiceTokenizer.Line) -> [String] {
        var out: [String] = []
        for t in line.tokens {
            if t.s.hasPrefix("¥") {
                let rest = String(t.s.dropFirst()).replacingOccurrences(of: ",", with: "")
                if let amt = leadingAmount(in: rest) { out.append(amt) }
            }
        }
        return out
    }

    /// An amount found on a line, with its x position and whether it carried ¥.
    struct AmountCandidate {
        let x: CGFloat
        let amount: String
        let hasYen: Bool
        var value: Double? { Double(amount) }
    }

    /// Every decimal amount on a line in x order — both ¥-prefixed and bare.
    /// Bare candidates skip tax-rate tokens like "6%", "3%", "0.06" and the
    /// literal "0". ¥-tagged candidates are always kept.
    static func amountCandidates(in line: InvoiceTokenizer.Line) -> [AmountCandidate] {
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
    static func pickAmountPair(_ candidates: [AmountCandidate],
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

    // MARK: Orientation

    /// Detect whether lines are currently in reading order (title last, since
    /// we sort y descending and PDFKit uses flipped coords → title at bottom).
    /// If the FIRST line looks like the title region, no flip needed.
    /// If the LAST line looks like the title, flip.
    static func needsFlip(_ lines: [InvoiceTokenizer.Line]) -> Bool {
        guard let first = lines.first, let last = lines.last else { return false }
        let titleAppearsFirst = first.compact.contains("电子发票") || first.compact.contains("发票号码")
        let titleAppearsLast = last.compact.contains("电子发票") || last.compact.contains("发票号码")
        return titleAppearsFirst && !titleAppearsLast
    }

    // MARK: End-to-end parse

    /// Parse reconstructed lines into an InvoiceData. Orchestrates:
    /// type detection → 价税合计 (resolved first, as a constraint) →
    /// 金额/税额 pair selection → sanity reconciliation.
    static func parse(lines: [InvoiceTokenizer.Line], into inv: inout InvoiceData) {
        // 1) Type + locate the 合计 line.
        var typeCandidate = ""
        var totalLineIdx: Int? = nil
        for (i, line) in lines.enumerated() {
            if let t = extractType(in: line.text), !t.isEmpty {
                typeCandidate = t
            }
            // A line is the 合计 line if it contains 合 and 计 (possibly far
            // apart, even with 合计 and 价税合计 merged into one Y-grouped
            // line) AND has at least one amount candidate. The 价税合计-only
            // line has no amount on itself, so this naturally excludes it.
            if line.compact.contains("合") && line.compact.contains("计")
                && !amountCandidates(in: line).isEmpty {
                if totalLineIdx == nil { totalLineIdx = i }
            }
        }
        inv.type = typeCandidate

        // 2) 价税合计 — resolved first so 金额/税额 can use it as a constraint.
        resolveTotalWithTax(lines: lines, into: &inv)

        // 3) 金额 / 税额 from the 合计 line.
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

        // 4) Sanity: 价税合计 must be ≥ both 金额 and 税额.
        reconcileTotalWithTax(lines: lines, into: &inv)
    }

    /// Resolve 价税合计 from the 价税合计 keyword line, scanning the line
    /// itself then neighbours (Y-jitter can split ¥ and digits across lines).
    private static func resolveTotalWithTax(lines: [InvoiceTokenizer.Line], into inv: inout InvoiceData) {
        for (i, line) in lines.enumerated() where line.text.contains("价税合计") {
            var amt = yenAmounts(in: line)
            // Stray "¥" with digits split onto a nearby line by baseline jitter.
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
    }

    /// If `totalWithTax` is missing or implausibly small (< 金额 or < 税额),
    /// replace it with the largest ¥-amount on the page, or a bare decimal
    /// matching 金额+税额 when the ¥ was split from its digits.
    private static func reconcileTotalWithTax(lines: [InvoiceTokenizer.Line], into inv: inout InvoiceData) {
        let before = Double(inv.totalBefore) ?? 0
        let tax = Double(inv.taxAmount) ?? 0
        let current = Double(inv.totalWithTax) ?? 0
        let plausible = current >= before && current >= tax && current > 0
        if plausible { return }

        let expected = before + tax

        // Pass 1: largest ¥-tagged amount on the page.
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

        // Pass 2: a bare decimal matching 金额+税额 (split-¥ case).
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

        if !bestBareMatchStr.isEmpty {
            inv.totalWithTax = bestBareMatchStr
        } else if !bestYenStr.isEmpty {
            inv.totalWithTax = bestYenStr
        }
    }

    /// True if the line has a lone "¥" token not followed by digits on the
    /// same line.
    private static func hasStrayYen(in line: InvoiceTokenizer.Line) -> Bool {
        line.tokens.contains { $0.s == "¥" }
    }

    /// When a stray "¥" sits on the 价税合计 line but its digits landed on a
    /// different line (Y-jitter), search nearby lines for the bare decimal
    /// closest in x to the ¥ symbol and return it.
    private static func nearestBareAmountToYen(in lines: [InvoiceTokenizer.Line], around anchorIdx: Int) -> String? {
        let anchor = lines[anchorIdx]
        let yenXs = anchor.tokens.filter { $0.s == "¥" }.map(\.x)
        guard !yenXs.isEmpty else { return nil }

        var best: (dist: CGFloat, value: String)? = nil
        for offset in [-1, 1, -2, 2, -3, 3] {
            let j = anchorIdx + offset
            guard j >= 0, j < lines.count else { continue }
            for t in lines[j].tokens {
                if t.s.hasPrefix("¥") { continue }
                guard let amt = leadingAmount(in: t.s), amt != "0", amt != "0.0", amt != "0.00" else { continue }
                let dist = yenXs.map { abs($0 - t.x) }.min() ?? .greatestFiniteMagnitude
                if best == nil || dist < best!.dist {
                    best = (dist, amt)
                }
            }
        }
        if let b = best, b.dist <= 120 {
            return b.value
        }
        return nil
    }
}
