import SwiftUI
import UniformTypeIdentifiers

/// Left panel: file queue + toolbar + empty state.
/// Mirrors Go `ui/filelist.go`.
struct FileQueueView: View {
    @ObservedObject var state: AppState

    private var hasSelection: Bool {
        if let i = state.selectedIndex, state.items.indices.contains(i) { return true }
        return false
    }
    private var canMoveUp: Bool {
        if let i = state.selectedIndex { return i > 0 }
        return false
    }
    private var canMoveDown: Bool {
        if let i = state.selectedIndex { return i < state.items.count - 1 }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header: title + hint
            HStack {
                Text("文件队列").font(.headline)
                Spacer()
                Text("按列表顺序合并").foregroundStyle(.secondary).font(.caption)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()

            // Toolbar (mirrors CreateToolbar)
            toolbar
            Divider()

            // List + empty state overlay (mirrors NewStack(List, EmptyState))
            ZStack {
                if state.items.isEmpty {
                    emptyState
                } else {
                    queueList
                }
            }

            // Duplicate-content warning banner (shown only when present).
            if state.hasDuplicates {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("检测到 \(state.duplicateIndices.count) 个重复文件(内容相同)")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.orange.opacity(0.1))
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        // fileImporter must hang on a stable root view (not a rebuilt child
        // like `toolbar`); otherwise the open-folder state change may not
        // surface a dialog on macOS.
        .fileImporter(isPresented: $isShowingOpenDialog,
                      allowedContentTypes: [UTType.pdf],
                      allowsMultipleSelection: true) { result in
            if case let .success(urls) = result {
                state.addFiles(urls.map(\.path))
            }
        }
        .fileImporter(isPresented: $isShowingFolderDialog,
                      allowedContentTypes: [UTType.folder],
                      allowsMultipleSelection: false) { result in
            if case let .success(urls) = result, let url = urls.first {
                addPDFsFromFolder(url.path)
            }
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        VStack(spacing: 6) {
            // Row 1: import (left) + delete (right) — both touch the queue
            // membership, grouped at the edges. Remove lives with Clear
            // because both are destructive.
            HStack(spacing: 6) {
                Button {
                    isShowingOpenDialog = true
                } label: {
                    Label("添加", systemImage: "plus.circle.fill")
                }
                Button {
                    isShowingFolderDialog = true
                } label: {
                    Label("文件夹", systemImage: "folder")
                }
                Spacer()
                Button { state.removeSelected() } label: { Label("移除", systemImage: "minus.circle") }
                    .disabled(!hasSelection)
                Button { state.clear() } label: { Label("清空", systemImage: "trash") }
                    .disabled(state.items.isEmpty)
            }
            // Row 2: reorder (sorting only — moves items around, not membership)
            HStack(spacing: 6) {
                Button { state.moveUp() } label: { Label("上移", systemImage: "chevron.up") }
                    .disabled(!canMoveUp)
                Button { state.moveDown() } label: { Label("下移", systemImage: "chevron.down") }
                    .disabled(!canMoveDown)
                Button { state.sortByName() } label: { Label("排序", systemImage: "arrow.up.arrow.down") }
                    .disabled(state.items.count < 2)
                Spacer()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .buttonStyle(.bordered)
    }

    @State private var isShowingOpenDialog = false
    @State private var isShowingFolderDialog = false

    /// Recursively (one level, matching Go findPDFs) collect PDFs from a folder.
    private func addPDFsFromFolder(_ dir: String) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return }
        let paths = entries
            .filter { Format.isPDF($0) }
            .map { (dir as NSString).appendingPathComponent($0) }
        state.addFiles(paths)
    }

    // MARK: List

    private var queueList: some View {
        List(selection: selectionBinding) {
            ForEach(Array(state.items.enumerated()), id: \.element.id) { idx, item in
                queueRow(item, isDuplicate: state.duplicateIndices.contains(idx))
                    .tag(idx)
            }
        }
        .listStyle(.inset)
    }

    /// Drive the List's selection from AppState.selectedIndex (single selection).
    private var selectionBinding: Binding<Int?> {
        Binding(
            get: { state.selectedIndex },
            set: { state.selectedIndex = $0 }
        )
    }

    @ViewBuilder
    private func queueRow(_ item: FileItem, isDuplicate: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isDuplicate ? "doc.on.doc.fill" : "doc.text.fill")
                .foregroundColor(isDuplicate ? .red : .accentColor)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(item.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                    if isDuplicate {
                        Text("重复")
                            .font(.caption2).fontWeight(.medium)
                            .foregroundColor(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.red, in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                Text("\(Format.size(item.size))  ·  \(item.pageCount) 页")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(minHeight: 44)
        .padding(.vertical, 2)
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.doc.fill")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("拖入 PDF，开始合并").font(.headline)
            Text("也可以点击上方按钮添加文件或文件夹")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
