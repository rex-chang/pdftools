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

    // MARK: Header (filename + size + pages + path)

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
            // Real PDF rendering. Key handling lives in PdfKitView; selection
            // changes recreate it via .id(item.path) so PDFDocument is reloaded.
            PdfKitView(path: item.path)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            // Path row at the bottom so the page view gets maximum vertical space.
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

/// Bridges AppKit's `PDFView` into SwiftUI. Displays the document for `path`
/// with continuous scrolling, fit-to-width scaling, and the standard macOS
/// PDF view interactions (scroll, zoom via ⌘+/⌘-, page nav).
///
/// `PDFView` is the canonical preview surface on macOS (it's what Quick Look
/// uses), so wrapping it gives us zoom/scroll/selection for free.
struct PdfKitView: NSViewRepresentable {
    let path: String

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .windowBackgroundColor
        // A sensible minimum so pages never render unreadably small even
        // before autoScales kicks in.
        view.minScaleFactor = 0.5
        view.scaleFactor = 1.0
        // Load document.
        if let doc = PDFDocument(url: URL(fileURLWithPath: path)) {
            view.document = doc
            // autoScales needs the view to have a real size to compute
            // fit-to-width, which isn't available yet in makeNSView. Defer
            // the fit-to-width to the next layout pass.
            DispatchQueue.main.async { [weak view] in
                guard let view = view, view.document != nil else { return }
                view.scaleFactor = view.scaleFactorForSizeToFit
                // Re-evaluate once more after the scrollview settles — a
                // single async pass sometimes runs before the PDF's own
                // scroll view has its final frame.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak view] in
                    view?.scaleFactor = view?.scaleFactorForSizeToFit ?? 1.0
                }
            }
        }
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        // Only swap the document when the path actually changes — SwiftUI
        // calls updateNSView on re-renders, and reloading would reset the
        // user's scroll/zoom position needlessly.
        let currentPath = (nsView.document?.documentURL?.path) ?? ""
        if currentPath != path {
            nsView.document = PDFDocument(url: URL(fileURLWithPath: path))
            // Re-fit on document change, again deferred so the view has size.
            DispatchQueue.main.async { [weak nsView] in
                guard let nsView = nsView, nsView.document != nil else { return }
                nsView.scaleFactor = nsView.scaleFactorForSizeToFit
            }
        }
    }
}
