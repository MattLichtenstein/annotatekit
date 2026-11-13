#if os(macOS)
import AnnotateAgent
import AnnotateCore
import AppKit
import Foundation
import SwiftUI

/// Publishes inbox state to the window app or menu bar extra, whichever process hosts it.
///
/// The first process to take the receiver lock becomes the owner: it listens, delivers, and is
/// the only writer of the queue. Any other process runs as a viewer that reads the same queue,
/// forwards actions as durable commands, and takes ownership automatically when the owner quits.
@MainActor
final class InboxModel: ObservableObject {
    enum Role: Equatable { case starting, owner, viewer }

    @Published private(set) var role: Role = .starting
    @Published private(set) var listenerEnabled: Bool
    @Published private(set) var automaticallySend: Bool
    @Published private(set) var changingListener = false
    @Published private(set) var items: [ReceiverService.Item] = []
    @Published private(set) var trashItems: [ReceiverService.TrashItem] = []
    @Published private(set) var error: String?
    @Published private(set) var isSending = false
    @Published var selection: String?

    let configuration: ReceiverService.Configuration
    private var service: ReceiverService?
    private var loop: Task<Void, Never>?
    private let preferences: UserDefaults
    private let wakeup = InboxWakeup()
    private var observers: [NSObjectProtocol] = []
    private var publishedSignature = ""
    private var catalogUpdatedAt = Date.distantPast

    init(configuration: ReceiverService.Configuration) {
        self.configuration = configuration
        preferences = InboxPreferences.shared
        listenerEnabled = preferences.bool(forKey: InboxPreferences.listenerKey)
        automaticallySend = preferences.bool(forKey: InboxPreferences.automaticallySendKey)
    }

    var queuedItems: [ReceiverService.Item] { items.filter { !$0.annotations.isEmpty } }
    var sendableItems: [ReceiverService.Item] { items.filter { !$0.entry.sendRequested && !$0.annotations.isEmpty } }

    var status: String {
        if role == .starting { return "Opening inbox…" }
        if changingListener { return "Updating listener…" }
        if isSending { return "Sending to T3…" }
        return listenerEnabled ? "Listening" : "Listener off"
    }

    func start() {
        let center = DistributedNotificationCenter.default()
        let scope = configuration.output.path
        for name in [InboxSignal.commandsSubmitted, InboxSignal.stateChanged] {
            observers.append(center.addObserver(forName: name, object: scope, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.wakeup.signal() }
            })
        }
        loop = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.tick()
                await self.wakeup.wait(for: .seconds(2))
            }
        }
    }

    // MARK: - Actions

    func setListener(_ enabled: Bool) {
        guard !changingListener else { return }
        changingListener = true
        listenerEnabled = enabled // Optimistic; the owner's result corrects it if listening fails.
        submit(.setListener(enabled))
    }

    func setAutomaticallySend(_ enabled: Bool) {
        automaticallySend = enabled
        submit(.setAutomaticallySend(enabled))
    }

    func send(ids: [String]) { submit(.send(ids: ids)) }
    func send(sessionID: String, annotationID: UUID) { submit(.sendNote(sessionID: sessionID, annotationID: annotationID)) }
    func trash(sessionID: String, annotationID: UUID) { submit(.trash(sessionID: sessionID, annotationID: annotationID)) }
    func restore(trashID: String) { submit(.restore(trashID: trashID)) }

    /// Moves every remaining note in a batch to Trash, each restorable for seven days.
    func trash(batch item: ReceiverService.Item) {
        guard !item.entry.sendRequested else { return }
        for note in item.annotations { trash(sessionID: item.id, annotationID: note.id) }
    }

    /// Both roles use the durable command path, so actions behave the same before and after a handoff.
    private func submit(_ command: MacInboxControl.Command) {
        do {
            try MacInboxControl.enqueue(command, in: configuration.output)
            if role != .owner {
                DistributedNotificationCenter.default().postNotificationName(InboxSignal.commandsSubmitted,
                    object: configuration.output.path, userInfo: nil, deliverImmediately: true)
            }
            wakeup.signal()
        } catch {
            self.error = "That change could not be saved. Your annotations are unchanged."
            changingListener = false
        }
    }

    // MARK: - Loop

    private func tick() async {
        if service == nil { await acquireOwnership() }
        if let service { await ownerTick(service) } else { viewerTick() }
    }

    private func acquireOwnership() async {
        let service: ReceiverService
        do { service = try ReceiverService(configuration: configuration) }
        catch ReceiverService.OwnershipError.ownedElsewhere {
            role = .viewer
            return
        } catch {
            role = .viewer
            self.error = error.localizedDescription
            return
        }
        // Read the latest saved choices: a previous owner may have changed them.
        listenerEnabled = preferences.bool(forKey: InboxPreferences.listenerKey)
        automaticallySend = preferences.bool(forKey: InboxPreferences.automaticallySendKey)
        do {
            try await service.prepare(automaticallySend: automaticallySend)
            self.service = service
            role = .owner
            error = nil
            do { try await service.setListening(listenerEnabled) }
            catch {
                // Keep the saved choice so a later owner retries, but show the actual state.
                listenerEnabled = false
                self.error = error.localizedDescription
            }
        } catch {
            role = .viewer
            self.error = "The inbox could not be opened. Saved annotations have been retained."
        }
    }

    private func ownerTick(_ service: ReceiverService) async {
        await applyCommands(service)
        do {
            try await service.acceptSimulatorBatches()
            try await service.purgeTrash()
            try await reload(service)
            isSending = items.contains { $0.entry.sendRequested }
            if isSending {
                publish()
                let succeeded = try await service.deliverRequested()
                error = succeeded ? nil : "T3 is unavailable. Check that T3 is open and signed in. Queued batches are kept."
                try await reload(service)
            }
            if listenerEnabled, Date().timeIntervalSince(catalogUpdatedAt) >= 10 {
                try await service.refreshCatalog()
                catalogUpdatedAt = Date()
            }
        } catch {
            self.error = "The inbox could not complete its last operation. Saved annotations have been retained."
        }
        isSending = false
        publish()
    }

    private func applyCommands(_ service: ReceiverService) async {
        for pending in MacInboxControl.pendingCommands(in: configuration.output) {
            defer { MacInboxControl.complete(pending) }
            guard let command = pending.command else { continue } // Unreadable commands are discarded.
            do {
                switch command {
                case let .send(ids): try await service.requestSend(ids: ids)
                case let .sendNote(sessionID, annotationID): try await service.sendNote(sessionID: sessionID, annotationID: annotationID)
                case let .trash(sessionID, annotationID): try await service.trash(sessionID: sessionID, annotationID: annotationID)
                case let .restore(trashID): try await service.restore(trashID: trashID)
                case let .setAutomaticallySend(enabled):
                    await service.setAutomaticallySend(enabled)
                    automaticallySend = enabled
                    preferences.set(enabled, forKey: InboxPreferences.automaticallySendKey)
                case let .setListener(enabled):
                    do { try await service.setListening(enabled) }
                    catch { listenerEnabled = await service.isListening; throw error }
                    listenerEnabled = enabled
                    preferences.set(enabled, forKey: InboxPreferences.listenerKey)
                }
                error = nil
            } catch {
                self.error = Self.failureMessage(for: command, error: error)
            }
        }
        changingListener = false
    }

    private func reload(_ service: ReceiverService) async throws {
        items = try await service.items()
        trashItems = try await service.trashItems()
    }

    /// Mirrors the owner's state, keeping the last good snapshot if a read races an owner write.
    private func viewerTick() {
        let output = configuration.output
        let hasPendingCommands = MacInboxControl.hasPendingCommands(in: output)
        if let status = MacInboxControl.readStatus(in: output), status.ownerProcessID != getpid() {
            // Keep optimistic switch values until the owner has applied this viewer's commands.
            if !hasPendingCommands {
                listenerEnabled = status.listening
                automaticallySend = status.automaticallySend
            }
            isSending = status.sending
            error = status.error
        }
        changingListener = changingListener && hasPendingCommands
        if let snapshot = try? ReceiverService.readSnapshot(configuration: configuration) {
            items = snapshot.items
            trashItems = snapshot.trash
        }
    }

    /// Writes the status file and tells viewers to refresh only when visible state changed.
    private func publish() {
        let signature = ([listenerEnabled, automaticallySend, isSending].map(String.init(describing:)) + [error ?? ""]
            + items.map { "\($0.id):\($0.entry.sendRequested):\($0.annotations.count):\($0.error != nil):\($0.destination)" }
            + trashItems.map(\.id)).joined(separator: "|")
        guard signature != publishedSignature else { return }
        publishedSignature = signature
        try? MacInboxControl.writeStatus(.init(ownerProcessID: getpid(), listening: listenerEnabled,
            automaticallySend: automaticallySend, sending: isSending, error: error), in: configuration.output)
        DistributedNotificationCenter.default().postNotificationName(InboxSignal.stateChanged,
            object: configuration.output.path, userInfo: nil, deliverImmediately: true)
    }

    private static func failureMessage(for command: MacInboxControl.Command, error: Error) -> String {
        switch command {
        case .send: "This batch could not be queued for T3. Its files remain on your Mac."
        case .sendNote: "This note could not be queued for T3. It remains in its batch."
        case .trash: "This annotation could not be moved to Trash. Its files are retained."
        case .restore: "This annotation could not be restored. Its files are retained until Trash expires."
        case .setListener: error.localizedDescription
        case .setAutomaticallySend: "Auto-send could not be changed."
        }
    }

    /// Stops listening and releases the lock so a running viewer can take over within seconds.
    func shutdown() async {
        observers.forEach(DistributedNotificationCenter.default().removeObserver)
        observers = []
        loop?.cancel()
        wakeup.signal()
        await loop?.value
        guard let service else { return }
        try? await service.setListening(false)
        MacInboxControl.removeStatus(in: configuration.output)
        self.service = nil
        DistributedNotificationCenter.default().postNotificationName(InboxSignal.stateChanged,
            object: configuration.output.path, userInfo: nil, deliverImmediately: true)
    }
}

/// Lets the refresh loop sleep between passes but wake at once for a local action or a peer's signal.
@MainActor
private final class InboxWakeup {
    private var continuation: CheckedContinuation<Void, Never>?
    private var pending = false

    func signal() {
        if let continuation {
            self.continuation = nil
            continuation.resume()
        } else {
            pending = true
        }
    }

    func wait(for duration: Duration) async {
        if pending || Task.isCancelled { pending = false; return }
        let timer = Task { [weak self] in
            do { try await Task.sleep(for: duration); self?.signal() } catch {}
        }
        await withCheckedContinuation { continuation = $0 }
        timer.cancel()
        pending = false
    }
}
#endif
