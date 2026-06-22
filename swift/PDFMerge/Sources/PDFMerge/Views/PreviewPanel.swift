import SwiftUI
import PDFKit

/// Right panel: renders the selected PDF's actual pages via PDFKit.
/// Replaces the Go version's text-only preview with a real document view.
struct PreviewPanel: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let item = state.selectedItem {
                previewContent(for: item)
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: Header (filename + size + pages)

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("预览").font(.headline)
            if let item = state.selectedItem {
                Text(item.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Text("·").foregroundStyle(.secondary)
                Text("\(item.pageCount) 页").foregroundStyle(.secondary).font(.caption)
                Text("·").foregroundStyle(.secondary)
                Text(Format.size(item.size)).foregroundStyle(.secondary).font(.caption)
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: Content

    private func previewContent(for item: FileItem) -> some View {
        VStack(spacing: 0) {
            // The loader drives loading/error/PDFView states. Keying on path
            // gives us a fresh loader per file (cancels any in-flight load).
            PdfPreviewContainer(path: item.path)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(item.path)
            Divider()
            pathRow(item.path)
        }
    }

    private func pathRow(_ path: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary).font(.caption)
            Text(path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    // MARK: Empty state

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "eye")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("选择 PDF 文件以查看预览").font(.headline)
            Text("左侧队列顺序就是最终合并顺序")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Owns the loading state for a single PDF. Loading runs on a background
/// Task so large PDFs don't block the UI; a `@Published` state drives the
/// view (loading / loaded / error).
@MainActor
final class PdfLoader: ObservableObject {
    enum State: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var state: State = .loading
    /// The loaded document. Handed off to the PDFView on the main thread.
    private(set) var document: PDFDocument?
    private var loadTask: Task<Void, Never>? = nil

    func load(path: String) {
        loadTask?.cancel()
        state = .loading
        document = nil
        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            // `PDFDocument(url:)` is documented as safe off-main (it's the
            // explicit initializer, not one of the view-bound conveniences).
            var doc: PDFDocument?
            var error: String?
            if let opened = PDFDocument(url: URL(fileURLWithPath: path)) {
                // Encrypted: try empty password (many e-invoices do this).
                // If it stays locked, surface as an error so the user isn't
                // left looking at a blank view.
                if opened.isEncrypted && !opened.unlock(withPassword: "") {
                    error = "PDF 已加密,无法预览(需密码)"
                } else {
                    doc = opened
                }
            } else {
                error = "无法打开(文件损坏或不存在)"
            }
            await self?.finish(doc: doc, error: error)
        }
    }

    private func finish(doc: PDFDocument?, error: String?) {
        if let doc = doc {
            document = doc
            state = .loaded
        } else if let error = error {
            state = .failed(error)
        } else {
            state = .failed("未知错误")
        }
    }
}

/// Wraps the async loading + PDFView rendering. Shows a spinner while
/// loading, an error placeholder on failure, and the live PDFView on success.
struct PdfPreviewContainer: View {
    let path: String
    @StateObject private var loader = PdfLoader()

    var body: some View {
        Group {
            switch loader.state {
            case .loading:
                VStack(spacing: 10) {
                    ProgressView().controlSize(.large)
                    Text("加载中…").foregroundStyle(.secondary).font(.caption)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36))
                        .foregroundStyle(.orange)
                    Text(message).font(.headline)
                    Text("该文件仍可参与合并,但预览不可用")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded:
                if let doc = loader.document {
                    PdfKitView(document: doc)
                }
            }
        }
        .onAppear { loader.load(path: path) }
    }
}

/// Bridges AppKit's `PDFView` into SwiftUI. Takes a pre-loaded PDFDocument
/// (loaded off-main by PdfLoader) so this view never blocks on I/O.
///
/// Scaling strategy: rely on `autoScales = true`, which makes PDFView
/// fit-to-width on load and on window resize. We do NOT manually set
/// `scaleFactor` — the previous manual-fit-on-async conflicted with
/// autoScales and reset the user's zoom on every resize. autoScales alone
/// gives the correct, stable behaviour.
struct PdfKitView: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true              // fit-to-width, updates on resize
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .windowBackgroundColor
        view.minScaleFactor = 0.25
        view.document = document
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        // Only swap when the document object identity differs. Since
        // PdfPreviewContainer is keyed by path, we get a fresh PdfKitView per
        // file anyway; this guard is defensive.
        if nsView.document !== document {
            nsView.document = document
        }
    }
}
