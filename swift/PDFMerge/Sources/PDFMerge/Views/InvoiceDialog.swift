import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Invoice extraction result dialog with CSV export + raw-text debug view.
/// Mirrors Go `ui/invoice.go` (ShowInvoiceDialog).
struct InvoiceDialog: View {
    let results: [InvoiceData]
    let debugTexts: [String]
    @Binding var isPresented: Bool

    @State private var isShowingSaveDialog = false
    @State private var showDebugText = false
    @State private var exportError: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("发票价税信息").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 8)
            Divider()

            // Table
            Table(results) {
                TableColumn("文件名") { Text($0.fileName).lineLimit(1).truncationMode(.middle) }
                TableColumn("类型") { Text($0.type) }
                TableColumn("价税合计") { Text($0.totalWithTax) }
                TableColumn("金额(不含税)") { Text($0.totalBefore) }
                TableColumn("税额") { Text($0.taxAmount) }
                TableColumn("备注") {
                    Text($0.errorMessage)
                        .foregroundStyle($0.failed ? .red : .secondary)
                }
            }
            .tableStyle(.bordered)

            // Summary: sum of 价税合计 across all valid (parseable) rows.
            summaryBar
            Divider()

            // Buttons
            Divider()
            HStack {
                if !debugTexts.isEmpty {
                    Button("原始文本") { showDebugText = true }
                }
                Spacer()
                Button("导出 CSV") { isShowingSaveDialog = true }
                Button("关闭") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)

            if let err = exportError {
                Text(err).foregroundStyle(.red).font(.caption).padding(.bottom, 8)
            }
        }
        .frame(width: 760, height: 480)
        .fileExporter(isPresented: $isShowingSaveDialog,
                      document: CSVDocument(rows: csvRows),
                      contentType: .commaSeparatedText,
                      defaultFilename: "发票数据") { result in
            switch result {
            case .success(let url):
                // fileExporter writes via the document's fileWrapper
                _ = url
            case .failure(let err):
                exportError = "导出失败: \(err.localizedDescription)"
            }
        }
        .sheet(isPresented: $showDebugText) {
            DebugTextDialog(texts: debugTexts, isPresented: $showDebugText)
        }
    }

    private var csvRows: [[String]] {
        [InvoiceData.csvHeader] + results.map(\.csvRow)
    }

    // MARK: - Summary

    /// Sum 价税合计 across rows that aren't failures. Failed rows (those
    /// with an errorMessage) are skipped and the user is told how many were
    /// skipped so the total isn't misleading.
    private var summary: (total: Double, counted: Int, skipped: Int) {
        var total = 0.0
        var counted = 0
        var skipped = 0
        for r in results {
            if r.failed { skipped += 1; continue }
            if let v = Double(r.totalWithTax) {
                total += v
                counted += 1
            }
        }
        return (total, counted, skipped)
    }

    private var summaryBar: some View {
        let s = summary
        // Build the trailing count label as a single string so the "张"
        // sits flush against the number and the closing bracket — putting
        // them in separate HStack children would inject the stack's spacing
        // between every glyph.
        let countText = s.skipped > 0
            ? "（\(s.counted) 张 · \(s.skipped) 张失败）"
            : "（\(s.counted) 张）"
        return HStack(spacing: 8) {
            Text("价税合计汇总")
                .font(.caption).foregroundStyle(.secondary)
            Text(String(format: "¥%.2f", s.total))
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.accentColor)
            Text(countText)
                .font(.caption)
                .foregroundStyle(s.skipped > 0 ? .orange : .secondary)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

/// Raw plain-text debug viewer. Mirrors Go `showDebugText`.
struct DebugTextDialog: View {
    let texts: [String]
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(texts.enumerated()), id: \.offset) { idx, t in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("━━━ 文件 \(idx + 1) ━━━")
                                .font(.headline)
                            Text(t)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding()
            }
            Divider()
            HStack { Spacer(); Button("关闭") { isPresented = false } }
                .padding()
        }
        .frame(width: 720, height: 520)
    }
}

/// Lightweight CSV document wrapper for `fileExporter`.
///
/// Write-only by design — the app only ever exports CSVs, never imports
/// them. The read initialiser is required by FileDocument but throws if
/// ever invoked, so we can't silently corrupt data by pretending to parse.
struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    let rows: [[String]]

    init(rows: [[String]]) { self.rows = rows }

    init(configuration: ReadConfiguration) throws {
        // Write-only document — never parsed by this app. Throw rather than
        // pretend to parse and risk silently mangling data.
        throw NSError(domain: "PDFMerge.CSVDocument", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "CSV 导入不支持"])
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let text = rows.map { row in
            row.map { field in
                // Quote fields containing comma, quote, or newline.
                if field.contains(",") || field.contains("\"") || field.contains("\n") {
                    return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
                }
                return field
            }.joined(separator: ",")
        }.joined(separator: "\n")
        let data = (text as String).data(using: .utf8) ?? Data()
        // Prepend a UTF-8 BOM so Excel opens Chinese correctly.
        var bomData = Data([0xEF, 0xBB, 0xBF])
        bomData.append(data)
        return FileWrapper(regularFileWithContents: bomData)
    }
}
