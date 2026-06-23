import SwiftUI
import UniformTypeIdentifiers

/// Bottom bar: output settings + merge/extract buttons + progress.
/// Mirrors Go `ui/settings.go`.
///
/// Spans all three stores: merge settings + status come from `merge`,
/// extraction status from `invoice`, and the file count that gates the
/// buttons from `fileQueue`.
struct SettingsBar: View {
    @ObservedObject var state: AppState
    @State private var isShowingDirPicker = false

    private var fileQueue: FileQueueStore { state.fileQueue }
    @ObservedObject private var merge: MergeStore
    @ObservedObject private var invoice: InvoiceStore

    init(state: AppState) {
        self.state = state
        self._merge = ObservedObject(wrappedValue: state.merge)
        self._invoice = ObservedObject(wrappedValue: state.invoice)
    }

    var body: some View {
        VStack(spacing: 8) {
            Divider()
            HStack(alignment: .top, spacing: 16) {
                Text("输出设置").font(.headline)

                // Directory row
                HStack(spacing: 6) {
                    Text("目录:").foregroundStyle(.secondary)
                    TextField("目录", text: $merge.outputDir)
                        .textFieldStyle(.roundedBorder)
                        .disabled(true)
                    Button { isShowingDirPicker = true } label: {
                        Label("浏览", systemImage: "folder")
                    }
                }

                // Filename row
                HStack(spacing: 6) {
                    Text("文件名:").foregroundStyle(.secondary)
                    TextField("文件名", text: $merge.outputName)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 180)
                }

                Spacer(minLength: 0)

                // Actions
                HStack(spacing: 8) {
                    Button {
                        invoice.extractInvoices()
                    } label: {
                        Label("提取价税", systemImage: "magnifyingglass")
                    }
                    .disabled(!invoice.canExtract)

                    Button {
                        merge.merge()
                    } label: {
                        Label("合并 PDF", systemImage: "square.and.arrow.down.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!merge.canMerge)
                }
            }

            // Status + progress (mirrors StatusLabel + ProgressBar/ProgressInfinite)
            if invoice.isExtracting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(invoice.extractStatus)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("取消提取") { invoice.cancelExtraction() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            } else if merge.isMerging {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(merge.statusText)
                        .font(.caption)
                        .foregroundStyle(merge.statusText.hasPrefix("错误") ? .red : .secondary)
                        .lineLimit(2)
                    Spacer()
                    Button("取消合并") { merge.cancelMerge() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            } else if merge.statusVisible {
                HStack(spacing: 8) {
                    if let v = merge.progressValue {
                        ProgressView(value: v).frame(maxWidth: 220)
                    }
                    Text(merge.statusText)
                        .font(.caption)
                        .foregroundStyle(merge.statusText.hasPrefix("错误") ? .red : .secondary)
                        .lineLimit(2)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.regularMaterial)
        .fileImporter(isPresented: $isShowingDirPicker,
                      allowedContentTypes: [UTType.folder],
                      allowsMultipleSelection: false) { result in
            if case let .success(urls) = result, let url = urls.first {
                merge.outputDir = url.path
            }
        }
    }
}
