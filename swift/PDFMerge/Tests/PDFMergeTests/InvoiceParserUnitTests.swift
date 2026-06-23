import XCTest
@testable import PDFMerge

/// Unit tests for the pure parsing helpers in InvoiceExtractor.
///
/// These exercise the building blocks (amount extraction, type detection,
/// pair selection) in isolation — no PDFKit, no I/O — so they run fast and
/// pin down each heuristic independently of the end-to-end flow.
final class InvoiceParserUnitTests: XCTestCase {

    // MARK: leadingAmount

    func testLeadingAmount_plain() {
        XCTAssertEqual(InvoiceExtractor.leadingAmount(in: "2000.00"), "2000.00")
    }

    func testLeadingAmount_withCommas() {
        XCTAssertEqual(InvoiceExtractor.leadingAmount(in: "1,234,567.89"), "1234567.89")
    }

    func testLeadingAmount_leadingNoise() {
        // "abc123" has no leading amount → nil.
        XCTAssertNil(InvoiceExtractor.leadingAmount(in: "abc123"))
    }

    func testLeadingAmount_negative() {
        XCTAssertEqual(InvoiceExtractor.leadingAmount(in: "-2.94"), "-2.94")
    }

    func testLeadingAmount_integer() {
        XCTAssertEqual(InvoiceExtractor.leadingAmount(in: "1899"), "1899")
    }

    func testLeadingAmount_trailingNoise() {
        // Only the leading amount is captured; "元" is left out.
        XCTAssertEqual(InvoiceExtractor.leadingAmount(in: "218.60元"), "218.60")
    }

    // MARK: extractType

    func testExtractType_singleSegment() {
        XCTAssertEqual(InvoiceExtractor.extractType(in: "*餐饮服务*"), "餐饮服务")
    }

    func testExtractType_doubleSegment() {
        // "*生产生活服务*餐费*" — the regex `(?:\*[^*]+\*)+` matches the
        // first fully-closed "*生产生活服务*" only: after consuming it, the
        // remainder "餐费*" has no following closing star to form another
        // segment, so the + quantifier stops. Documents actual behaviour.
        XCTAssertEqual(InvoiceExtractor.extractType(in: "*生产生活服务*餐费*"), "生产生活服务")
    }

    func testExtractType_jdPrepaidCard() {
        XCTAssertEqual(InvoiceExtractor.extractType(in: "*预付卡销售*京东E卡"), "预付卡销售")
    }

    func testExtractType_none() {
        XCTAssertNil(InvoiceExtractor.extractType(in: "没有星号包裹的类型"))
    }

    // MARK: pickAmountPair

    /// Two ¥-tagged amounts on the 合计 row: 金额 then 税额.
    func testPickAmountPair_twoYenAmounts() {
        let cands = [
            InvoiceExtractor.AmountCandidate(x: 100, amount: "197.17", hasYen: true),
            InvoiceExtractor.AmountCandidate(x: 200, amount: "11.83", hasYen: true),
        ]
        let (before, tax) = InvoiceExtractor.pickAmountPair(cands, totalWithTax: "209.00")
        XCTAssertEqual(before, "197.17")
        XCTAssertEqual(tax, "11.83")
    }

    /// A stray bare unit price contaminates the 合计 row. The pair that sums
    /// to 价税合计 and uses MORE ¥-tagged members must win over the bare one.
    func testPickAmountPair_prefersYenOverBareContaminant() {
        // Layout: 11.83 (leftover unit-price, bare) | ¥197.17 | ¥11.83
        // 11.83 + 197.17 = 209 ✓ but only 1 ¥-tagged member.
        // 197.17 + 11.83   = 209 ✓ and BOTH ¥-tagged → preferred.
        let cands = [
            InvoiceExtractor.AmountCandidate(x: 57, amount: "11.83", hasYen: false),
            InvoiceExtractor.AmountCandidate(x: 196, amount: "197.17", hasYen: true),
            InvoiceExtractor.AmountCandidate(x: 412, amount: "11.83", hasYen: true),
        ]
        let (before, tax) = InvoiceExtractor.pickAmountPair(cands, totalWithTax: "209.00")
        XCTAssertEqual(before, "197.17")
        XCTAssertEqual(tax, "11.83")
    }

    /// When no pair sums to 价税合计, fall back to the rightmost two by x.
    func testPickAmountPair_fallbackRightmost() {
        let cands = [
            InvoiceExtractor.AmountCandidate(x: 10, amount: "1.00", hasYen: true),
            InvoiceExtractor.AmountCandidate(x: 20, amount: "2.00", hasYen: true),
            InvoiceExtractor.AmountCandidate(x: 30, amount: "3.00", hasYen: true),
        ]
        let (before, tax) = InvoiceExtractor.pickAmountPair(cands, totalWithTax: "999.00")
        XCTAssertEqual(before, "2.00")
        XCTAssertEqual(tax, "3.00")
    }

    /// Prepaid-card "不征税" invoice: 金额 = total, 税额 = 0.
    func testPickAmountPair_zeroTax() {
        let cands = [
            InvoiceExtractor.AmountCandidate(x: 100, amount: "2000.00", hasYen: true),
            InvoiceExtractor.AmountCandidate(x: 200, amount: "0.00", hasYen: true),
        ]
        let (before, tax) = InvoiceExtractor.pickAmountPair(cands, totalWithTax: "2000.00")
        XCTAssertEqual(before, "2000.00")
        XCTAssertEqual(tax, "0.00")
    }

    // MARK: yenAmounts / amountCandidates

    func testYenAmounts_twoAmounts() {
        let line = InvoiceExtractor.Line(y: 0, tokens: [
            InvoiceExtractor.Token(x: 10, y: 0, s: "¥2000.00"),
            InvoiceExtractor.Token(x: 20, y: 0, s: "¥0.00"),
        ])
        XCTAssertEqual(InvoiceExtractor.yenAmounts(in: line), ["2000.00", "0.00"])
    }

    func testYenAmounts_empty() {
        let line = InvoiceExtractor.Line(y: 0, tokens: [
            InvoiceExtractor.Token(x: 10, y: 0, s: "464.15"),  // bare, no ¥
        ])
        XCTAssertTrue(InvoiceExtractor.yenAmounts(in: line).isEmpty)
    }

    func testAmountCandidates_mixedYenAndBare() {
        let line = InvoiceExtractor.Line(y: 0, tokens: [
            InvoiceExtractor.Token(x: 56, y: 0, s: "2000.00"),    // bare
            InvoiceExtractor.Token(x: 180, y: 0, s: "¥2000.00"),  // yen
            InvoiceExtractor.Token(x: 469, y: 0, s: "¥0.00"),     // yen
        ])
        let cands = InvoiceExtractor.amountCandidates(in: line)
        XCTAssertEqual(cands.count, 3)
        XCTAssertEqual(cands[0].amount, "2000.00")
        XCTAssertFalse(cands[0].hasYen)
        XCTAssertEqual(cands[2].amount, "0.00")
        XCTAssertTrue(cands[2].hasYen)
    }

    /// Tax-rate tokens like "6%" must be excluded from bare candidates.
    func testAmountCandidates_excludesTaxRates() {
        let line = InvoiceExtractor.Line(y: 0, tokens: [
            InvoiceExtractor.Token(x: 10, y: 0, s: "6%"),
            InvoiceExtractor.Token(x: 20, y: 0, s: "197.17"),
        ])
        let cands = InvoiceExtractor.amountCandidates(in: line)
        XCTAssertEqual(cands.count, 1)
        XCTAssertEqual(cands[0].amount, "197.17")
    }

    // MARK: groupIntoLines

    func testGroupIntoLines_byY() {
        // Three tokens on two distinct Y rows.
        let tokens = [
            InvoiceExtractor.Token(x: 10, y: 100, s: "A"),
            InvoiceExtractor.Token(x: 20, y: 100, s: "B"),
            InvoiceExtractor.Token(x: 10, y: 50, s: "C"),
        ]
        let lines = InvoiceExtractor.groupIntoLines(tokens, tolerance: 3)
        XCTAssertEqual(lines.count, 2)
        // Reading order: y descending → y=100 line first.
        XCTAssertEqual(lines[0].tokens.map(\.s), ["A", "B"])
        XCTAssertEqual(lines[1].tokens.map(\.s), ["C"])
    }

    func testGroupIntoLines_withinTolerance() {
        // Two tokens 2pt apart in Y → same line (tolerance 3).
        let tokens = [
            InvoiceExtractor.Token(x: 10, y: 100, s: "A"),
            InvoiceExtractor.Token(x: 20, y: 102, s: "B"),
        ]
        let lines = InvoiceExtractor.groupIntoLines(tokens, tolerance: 3)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].tokens.count, 2)
    }

    // MARK: parse — end-to-end on synthetic lines

    /// A textbook 合计 row: 合 计 ¥a ¥b + 价税合计 (大写) 贰佰... ¥total.
    /// Both 合计 and 价税合计 merged into one line by Y-grouping (the case
    /// that broke the old `!contains("价税合计")` guard).
    func testParse_mixedTotalAndGrandTotalLine() {
        let lines = [
            InvoiceExtractor.Line(y: 100, tokens: [
                .init(x: 10, y: 0, s: "不征税"),
                .init(x: 50, y: 0, s: "合"),
                .init(x: 70, y: 0, s: "计"),
                .init(x: 100, y: 0, s: "¥569.81"),
                .init(x: 200, y: 0, s: "¥0.00"),
                .init(x: 400, y: 0, s: "价税合计"),
                .init(x: 450, y: 0, s: "（大写）"),
            ]),
            InvoiceExtractor.Line(y: 90, tokens: [
                .init(x: 10, y: 0, s: "伍佰陆拾玖圆捌角壹分"),
                .init(x: 200, y: 0, s: "¥569.81"),
            ]),
        ]
        var inv = InvoiceData(fileName: "test.pdf")
        InvoiceExtractor.parse(lines: lines, into: &inv)
        XCTAssertEqual(inv.totalWithTax, "569.81")
        XCTAssertEqual(inv.totalBefore, "569.81")
        XCTAssertEqual(inv.taxAmount, "0.00")
    }
}
