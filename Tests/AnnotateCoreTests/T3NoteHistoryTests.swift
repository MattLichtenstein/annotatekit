import Foundation
import Testing
@testable import AnnotateCore

/// Checks receipt-driven delivery history, duplicate discovery, and app-session retention boundaries.
struct T3NoteHistoryTests {
    private let first = Date(timeIntervalSince1970: 1_800_000_000)
    private let note = PinResult(index: 1, comment: "Please fix this", subject: "Button", intent: .fix, outcome: .open)

    private func receipt(_ id: String) -> T3DeliveryReceipt {
        T3DeliveryReceipt(sessionID: id, threadID: "thread", title: "Feedback", link: "local", contentStoredInT3: true)
    }

    @Test func deliveryRequiresAMatchingSupportedReceipt() {
        var history = T3NoteHistory()
        history.record(id: "first", sentAt: first, notes: [note])
        history.acknowledge(receipt("other"))
        var unsupported = receipt("first")
        unsupported.version = 2
        history.acknowledge(unsupported)
        #expect(history.batches.first?.filter == .sending)
        history.acknowledge(receipt("first"))
        #expect(history.batches.first?.filter == .sent)
        #expect(history.batches.first?.notes == [note])
        // A newly installed controller cannot resurrect completed notes from a routing receipt.
        var nextAppSession = T3NoteHistory()
        nextAppSession.acknowledge(receipt("first"))
        #expect(nextAppSession.batches.isEmpty)
    }

    @Test func supersededBatchesReceiveIndependentReceiptsWithoutDuplicateHistory() {
        var history = T3NoteHistory()
        history.record(id: "first", sentAt: first, notes: [note])
        history.record(id: "second", sentAt: first.addingTimeInterval(1), notes: [note])
        history.acknowledge(receipt("first"))
        history.record(id: "first", sentAt: first, notes: [])
        #expect(history.batches.map(\.id) == ["second", "first"])
        #expect(history.batches.map(\.filter) == [.sending, .sent])
        #expect(history.batches.last?.notes == [note])
        history.fail(id: "second")
        history.acknowledge(receipt("second"))
        history.fail(id: "first")
        #expect(history.batches.map(\.filter) == [.failed, .sent])
    }

    @Test func t3AndAgentIntegrationsKeepSeparateStatusVocabulary() {
        #expect(NoteFilter.filters(isT3Connected: true) == [.current, .sending, .sent, .failed])
        #expect(NoteFilter.filters(isT3Connected: false) == [.current, .inProgress, .resolved, .failed])
    }
}
