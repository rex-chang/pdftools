import XCTest
@testable import PDFMerge

/// Smoke test: confirms the test target links and can reach the app module.
final class SmokeTests: XCTestCase {
    func testFormatSize() {
        XCTAssertEqual(Format.size(0), "0 B")
        XCTAssertEqual(Format.size(1024), "1.0 KB")
        XCTAssertEqual(Format.size(1024 * 1024), "1.0 MB")
    }

    func testIsPDF() {
        XCTAssertTrue(Format.isPDF("/tmp/a.pdf"))
        XCTAssertTrue(Format.isPDF("/tmp/A.PDF"))
        XCTAssertFalse(Format.isPDF("/tmp/a.txt"))
    }

    func testInvoiceDataEquality() {
        // Equality ignores the auto-generated UUID — useful for assertions.
        var a = InvoiceData(fileName: "x.pdf")
        a.totalWithTax = "100.00"
        var b = InvoiceData(fileName: "x.pdf")
        b.totalWithTax = "100.00"
        XCTAssertEqual(a, b)
    }
}
