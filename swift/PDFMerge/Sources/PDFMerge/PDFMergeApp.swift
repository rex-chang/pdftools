import SwiftUI
import UniformTypeIdentifiers

/// App entry point. Mirrors Go `main.go` + `ui/app.go`.
@main
struct PDFMergeApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 880, minHeight: 560)
                .alert("提示", isPresented: Binding(
                    get: { state.lastMessage != nil },
                    set: { if !$0 { state.lastMessage = nil } }
                )) {
                    // Offer "在 Finder 中显示" only when the message reflects
                    // a successful merge (we have a last output URL).
                    if let url = state.lastMergeOutput {
                        Button("在 Finder 中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                            state.lastMessage = nil
                        }
                    }
                    Button("好") { state.lastMessage = nil }
                } message: {
                    Text(state.lastMessage ?? "")
                }
                .sheet(isPresented: $state.showInvoiceDialog) {
                    InvoiceDialog(results: state.invoiceResults,
                                  paths: state.invoiceInputPathsForDialog,
                                  fetchDebugText: { state.debugText(for: $0) },
                                  isPresented: $state.showInvoiceDialog)
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1080, height: 680)
    }
}

/// Main layout: HSplit(left queue 42% / right preview) with bottom settings bar.
/// Owns the drop target so the highlight overlay can react to it.
/// Mirrors Go's HSplit(0.42) + Border(settings at bottom).
struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                FileQueueView(state: state)
                PreviewPanel(state: state)
            }
            SettingsBar(state: state)
        }
        // Drop zone spans the whole content; highlight while dragging PDFs in.
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
            return true
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor.opacity(isDropTargeted ? 0.8 : 0), lineWidth: 3)
                .padding(2)
                .allowsHitTesting(false)
        )
    }

    /// Drag-and-drop PDF files. Mirrors Go `Window.SetOnDropped`.
    ///
    /// `NSItemProvider.loadObject` invokes its completion handler on an
    /// arbitrary background queue, and multiple providers run concurrently.
    /// Appending to a plain Swift Array from those handlers is a data race
    /// (it can lose entries or crash). We hop each result to the main thread
    /// — main thread is serial, so the collection is safe — and count
    /// pending providers to know when all have reported.
    private func handleDrop(_ providers: [NSItemProvider]) {
        let count = providers.count
        var collected: [String] = []
        var remaining = count
        for p in providers {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                let path = (url as URL?)?.path
                DispatchQueue.main.async {
                    if let path = path, Format.isPDF(path) {
                        collected.append(path)
                    }
                    remaining -= 1
                    if remaining == 0, !collected.isEmpty {
                        state.addFiles(collected)
                    }
                }
            }
        }
    }
}
