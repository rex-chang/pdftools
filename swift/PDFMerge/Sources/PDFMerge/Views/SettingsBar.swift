import SwiftUI
import UniformTypeIdentifiers

/// Bottom bar: output settings + merge/extract buttons + progress.
/// Mirrors Go `ui/settings.go`.
struct SettingsBar: View {
    @ObservedObject var state: AppState
    @State private var isShowingDirPicker = false

    var body: some View {
        VStack(spacing: 8) {
            Divider()
            HStack(alignment: .top, spacing: 16) {
                Text("输出设置").font(.headline)

                // Directory row
                HStack(spacing: 6) {
                    Text("目录:").foregroundStyle(.secondary)
                    TextField("目录", text: $state.outputDir)
                        .textFieldStyle(.roundedBorder)
                        .disabled(true)
                    Button { isShowingDirPicker = true } label: {
                        Label("浏览", systemImage: "folder")
                    }
                }

                // Filename row
                HStack(spacing: 6) {
                    Text("文件名:").foregroundStyle(.secondary)
                    TextField("文件名", text: $state.outputName)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 180)
                }

                Spacer(minLength: 0)

                // Actions
                HStack(spacing: 8) {
                    Button {
                        state.extractInvoices()
                    } label: {
                        Label("提取价税", systemImage: "magnifyingglass")
                    }
                    .disabled(!state.canExtract)

                    Button {
                        state.merge()
                    } label: {
                        Label("合并 PDF", systemImage: "square.and.arrow.down.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!state.canMerge)
                }
            }

            // Status + progress (mirrors StatusLabel + ProgressBar/ProgressInfinite)
            if state.statusVisible {
                HStack(spacing: 8) {
                    if state.isMerging {
                        ProgressView().controlSize(.small)
                    } else if let v = state.progressValue {
                        ProgressView(value: v).frame(maxWidth: 220)
                    }
                    Text(state.statusText)
                        .font(.caption)
                        .foregroundStyle(state.statusText.hasPrefix("错误") ? .red : .secondary)
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
                state.outputDir = url.path
            }
        }
    }
}
