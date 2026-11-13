#if os(macOS)
import AnnotateAgent
import AnnotateCore
import Darwin
import Foundation

/// Runs the existing device transport and T3 adapter under one exclusive Mac inbox owner, and
/// reads the queue without writing it for a viewer process that does not hold the lock.
actor ReceiverService {
    struct Configuration: Codable, Sendable {
        var root: String
        var projectID: String
        var node: String
        var credentials: String
        var output: URL { URL(fileURLWithPath: root).appendingPathComponent(".annotate/t3") }
    }

    struct Item: Identifiable, Sendable {
        var entry: MacInboxStore.Entry
        var session: AnnotationSession
        var error: String?
        var destination: String
        var id: String { entry.sessionID }
        var annotations: [Annotation] { session.annotations.filter { !entry.excludedAnnotationIDs.contains($0.id) } }
    }

    struct TrashItem: Identifiable, Sendable {
        var entry: MacInboxStore.TrashEntry
        var session: AnnotationSession
        var id: String { entry.id }
    }

    /// Another process (the other inbox surface or a CLI receiver) holds the receiver lock.
    enum OwnershipError: Error { case ownedElsewhere }

    let configuration: Configuration
    private let queue: MacInboxStore
    private let lock: Int32
    private var listenerTask: Task<Void, Never>?
    private var runtime: AgentRuntime?

    init(configuration: Configuration) throws {
        self.configuration = configuration
        let output = configuration.output
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: output.path)
        let descriptor = Darwin.open(output.appendingPathComponent("receiver.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw AnnotateT3Main.failure("Cannot open the receiver lock.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw OwnershipError.ownedElsewhere
        }
        lock = descriptor
        queue = MacInboxStore(output: output, projectID: configuration.projectID)
    }

    deinit { flock(lock, LOCK_UN); close(lock) }

    func prepare(automaticallySend: Bool) async throws {
        try await queue.activate()
        try await queue.recoverTrash()
        try await queue.purgeExpiredTrash()
        try await queue.receiveExisting()
        await queue.setAutomaticallySendNewBatches(automaticallySend)
    }

    var isListening: Bool { listenerTask != nil }

    func setAutomaticallySend(_ enabled: Bool) async {
        await queue.setAutomaticallySendNewBatches(enabled)
    }

    func setListening(_ enabled: Bool) async throws {
        if !enabled {
            listenerTask?.cancel()
            await listenerTask?.value
            listenerTask = nil
            runtime = nil
            return
        }
        guard listenerTask == nil else { return }
        let queue = queue
        guard let bridge = DeviceCtlBridge.makeIfAvailable() else {
            throw AnnotateT3Main.failure("Xcode’s developer connection is unavailable. Open Xcode and check its command-line tools.")
        }
        let mirror = DeviceMirror(outputDirectory: configuration.output, cutoffID: "", bridge: bridge,
            projectRoot: URL(fileURLWithPath: configuration.root), remoteDirectory: "Documents/.annotate/t3",
            sharedFiles: [T3ThreadCatalog.fileName], onReceive: { session in try await queue.receive(session) })
        let runtime = AgentRuntime(outputDirectory: configuration.output, mirror: mirror) {
            AgentPresence(agent: "Mac inbox", mode: .push, via: "t3")
        }
        self.runtime = runtime
        listenerTask = Task { await runtime.run() }
    }

    func acceptSimulatorBatches() async throws {
        guard listenerTask != nil else { return }
        try await queue.receiveAvailable()
    }

    func requestSend(ids: [String]) async throws { try await queue.requestSend(ids: ids) }
    func sendNote(sessionID: String, annotationID: UUID) async throws { try await queue.sendNote(sessionID: sessionID, annotationID: annotationID) }

    func items() async throws -> [Item] {
        try Self.items(for: try await queue.entries(), configuration: configuration)
    }

    func trashItems() async throws -> [TrashItem] {
        try Self.trashItems(for: try await queue.trashEntries(), configuration: configuration)
    }

    /// Reads the queue and Trash without the lock or any write, for a viewer process.
    nonisolated static func readSnapshot(configuration: Configuration) throws -> (items: [Item], trash: [TrashItem]) {
        let output = configuration.output
        return (try items(for: MacInboxStore.readEntries(output: output, projectID: configuration.projectID), configuration: configuration),
                try trashItems(for: MacInboxStore.readTrashEntries(output: output, projectID: configuration.projectID), configuration: configuration))
    }

    private nonisolated static func items(for entries: [MacInboxStore.Entry], configuration: Configuration) throws -> [Item] {
        let catalogURL = configuration.output.appendingPathComponent(T3ThreadCatalog.fileName)
        let catalog = (try? Data(contentsOf: catalogURL)).flatMap { try? AnnotationSession.decoder.decode(T3ThreadCatalog.self, from: $0) }
        return try entries.map { entry in
            let session = try SessionInbox.loadSession(id: entry.sessionID, in: configuration.output)
            let errorURL = configuration.output.appendingPathComponent("mac-errors/\(entry.sessionID).json")
            let hasError = FileManager.default.fileExists(atPath: errorURL.path)
            let title = session.t3Route?.threadID.map { id in catalog?.threads.first { $0.id == id }?.title ?? "Existing T3 Thread" } ?? "New Thread"
            return Item(entry: entry, session: session, error: hasError ? "Delivery unavailable. Check T3 and sign-in. This batch is safely stored on your Mac." : nil, destination: title)
        }
    }

    private nonisolated static func trashItems(for entries: [MacInboxStore.TrashEntry], configuration: Configuration) throws -> [TrashItem] {
        try entries.map { entry in
            let file = configuration.output.appendingPathComponent("mac-trash/\(entry.id)/bundle/session.json")
            return TrashItem(entry: entry, session: try AnnotationSession.decoder.decode(AnnotationSession.self, from: Data(contentsOf: file)))
        }
    }

    func trash(sessionID: String, annotationID: UUID) async throws { try await queue.trash(sessionID: sessionID, annotationID: annotationID) }
    func restore(trashID: String) async throws { try await queue.restore(trashID: trashID) }
    func purgeTrash() async throws { try await queue.purgeExpiredTrash() }

    func deliverRequested() async throws -> Bool {
        let entries = try await queue.entries()
        guard entries.contains(where: \.sendRequested) else { return true }
        let script = Bundle.module.resourceURL!.appendingPathComponent("Resources/t3-bridge.mjs").path
        return try await AnnotateT3Main.helper(configuration.node, script,
            ["tick", configuration.credentials, configuration.output.path, configuration.projectID], capturesOutput: true)
    }

    func refreshCatalog() async throws {
        let script = Bundle.module.resourceURL!.appendingPathComponent("Resources/t3-bridge.mjs").path
        _ = try await AnnotateT3Main.helper(configuration.node, script,
            ["catalog", configuration.credentials, configuration.output.path, configuration.projectID], capturesOutput: true)
    }
}
#endif
