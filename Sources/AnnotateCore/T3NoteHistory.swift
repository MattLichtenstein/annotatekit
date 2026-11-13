import Foundation

/// Keeps delivery-only note details in memory for one app session, without retaining screenshot files.
public struct T3NoteHistory: Equatable, Sendable {
    public struct Batch: Equatable, Sendable, Identifiable {
        public let id: String
        public let sentAt: Date
        public let notes: [PinResult]
        public fileprivate(set) var filter: NoteFilter
        public fileprivate(set) var receivedOnMac = false
    }

    public private(set) var batches: [Batch] = []

    public init() {}

    /// Repeated disk discovery must not replace a receipt or a failed local write.
    public mutating func record(id: String, sentAt: Date, notes: [PinResult]) {
        guard !batches.contains(where: { $0.id == id }) else { return }
        batches.append(Batch(id: id, sentAt: sentAt, notes: notes, filter: .sending))
        batches.sort { $0.sentAt > $1.sentAt }
    }

    /// Only a validated receipt for a known batch moves its notes into Sent.
    public mutating func acknowledge(_ receipt: T3DeliveryReceipt) {
        guard receipt.version == 1,
              let index = batches.firstIndex(where: { $0.id == receipt.sessionID }),
              batches[index].filter == .sending else { return }
        batches[index].filter = .sent
    }

    /// Mac acceptance ends the phone's queue, without claiming T3 has received it.
    public mutating func acknowledge(_ receipt: MacReceipt) {
        guard receipt.version == 1,
              let index = batches.firstIndex(where: { $0.id == receipt.sessionID }),
              batches[index].filter == .sending else { return }
        batches[index].filter = .sent
        batches[index].receivedOnMac = true
    }

    public mutating func fail(id: String) {
        guard let index = batches.firstIndex(where: { $0.id == id }),
              batches[index].filter == .sending else { return }
        batches[index].filter = .failed
    }
}
