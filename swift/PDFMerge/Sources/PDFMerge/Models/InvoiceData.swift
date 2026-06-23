import Foundation

/// Invoice price/tax data. Mirrors Go `pdf.InvoiceData`.
///
/// Lives in its own file so the model can be unit-tested without pulling in
/// PDFKit or the extraction logic.
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

extension InvoiceData: Equatable {
    /// Equality ignores the UUID `id` (which is regenerated each init) so
    /// two InvoiceData with the same fields compare equal in tests.
    static func == (lhs: InvoiceData, rhs: InvoiceData) -> Bool {
        lhs.fileName == rhs.fileName &&
        lhs.type == rhs.type &&
        lhs.totalWithTax == rhs.totalWithTax &&
        lhs.totalBefore == rhs.totalBefore &&
        lhs.taxAmount == rhs.taxAmount &&
        lhs.errorMessage == rhs.errorMessage
    }
}
