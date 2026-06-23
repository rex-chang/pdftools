import Foundation
import SwiftUI
import Combine

/// Composition root: creates the three specialised stores and wires their
/// dependencies. Views observe the specific store(s) they need directly
/// (`@ObservedObject var fileQueue: FileQueueStore`), rather than a single
/// god object — this keeps each view's re-render scope narrow and the code
/// organised by responsibility.
///
/// Previously this was a 290-line object managing every piece of state.
/// Now it's a thin coordinator:
///   - `fileQueue`  — items, selection, content-duplicate detection
///   - `merge`      — output settings + merge orchestration
///   - `invoice`    — invoice extraction + results
///
/// The merge and invoice stores hold a weak reference to the file queue
/// (they need its paths to operate on). To let views that still observe the
/// whole `AppState` (e.g. the root app's alert/sheet wiring) refresh on any
/// child change, child `objectWillChange` signals are republished here.
@MainActor
final class AppState: ObservableObject {

    let fileQueue: FileQueueStore
    let merge: MergeStore
    let invoice: InvoiceStore

    private var cancellables: Set<AnyCancellable> = []

    init() {
        let fq = FileQueueStore()
        self.fileQueue = fq
        // Merge & invoice stores observe the queue weakly for its paths.
        let ms = MergeStore(fileQueue: fq)
        let invStore = InvoiceStore(fileQueue: fq)
        self.merge = ms
        self.invoice = invStore

        // Republish each child's change notifications as our own, so views
        // observing AppState (e.g. the root alert/sheet bindings) refresh
        // when any child store mutates.
        fileQueue.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        ms.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        invStore.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }
}
