import SwiftUI

/// Right panel: selected-file details or a placeholder.
/// Mirrors Go `ui/preview.go`.
struct PreviewPanel: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("预览").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()

            if let item = state.selectedItem {
                detailView(item)
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func detailView(_ item: FileItem) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text.fill")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            Text(item.name)
                .font(.system(size: 15, weight: .semibold))
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Text("\(Format.size(item.size))  ·  \(item.pageCount) 页")
                .foregroundStyle(.secondary)

            Divider().frame(maxWidth: 320)

            VStack(alignment: .leading, spacing: 4) {
                Text("文件路径").font(.caption).foregroundStyle(.secondary)
                Text(item.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 24)
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "eye")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("选择 PDF 文件以查看详情").font(.headline)
            Text("左侧队列顺序就是最终合并顺序")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
