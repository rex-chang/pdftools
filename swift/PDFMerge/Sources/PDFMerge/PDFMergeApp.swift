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
                .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
                    handleDrop(providers)
                    return true
                }
                .alert("提示", isPresented: Binding(
                    get: { state.lastMessage != nil },
                    set: { if !$0 { state.lastMessage = nil } }
                )) {
                    Button("好") { state.lastMessage = nil }
                } message: {
                    Text(state.lastMessage ?? "")
                }
                .sheet(isPresented: $state.showInvoiceDialog) {
                    InvoiceDialog(results: state.invoiceResults,
                                  debugTexts: state.invoiceDebugTexts,
                                  isPresented: $state.showInvoiceDialog)
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1080, height: 680)
    }

    /// Drag-and-drop PDF files. Mirrors Go `Window.SetOnDropped`.
    private func handleDrop(_ providers: [NSItemProvider]) {
        var paths: [String] = []
        let group = DispatchGroup()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                defer { group.leave() }
                if let url = url, Format.isPDF(url.path) {
                    paths.append(url.path)
                }
            }
        }
        group.notify(queue: .main) {
            if !paths.isEmpty {
                state.addFiles(paths)
            }
        }
    }
}

/// Main layout: HSplit(left queue 42% / right preview) with bottom settings bar.
/// Mirrors Go's HSplit(0.42) + Border(settings at bottom).
struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                FileQueueView(state: state)
                PreviewPanel(state: state)
            }
            SettingsBar(state: state)
        }
    }
}
