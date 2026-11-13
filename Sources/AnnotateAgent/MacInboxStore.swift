import AnnotateCore
import Foundation

/// Owns durable receipt-time decisions and manual send requests, independently of the phone listener.
public actor MacInboxStore {
    public struct Entry: Codable, Sendable, Equatable, Identifiable {
        public var version: Int = 1
        public var sessionID: String
        public var projectID: String
        public var receivedAt: Date
        public var sendRequested: Bool
        public var trashedAnnotationIDs: [UUID]?
        public var hasProjection: Bool?
        /// Notes sent on their own through a split batch; this batch never sends them again.
        public var detachedAnnotationIDs: [UUID]?
        /// Set on a batch created to send one note from another batch, for crash recovery.
        public var splitFromSessionID: String?
        public var splitAnnotationID: UUID?
        public var id: String { sessionID }
        /// Notes this batch still owns and would send.
        public var excludedAnnotationIDs: Set<UUID> { Set((trashedAnnotationIDs ?? []) + (detachedAnnotationIDs ?? [])) }
    }

    public enum Failure: Error { case invalidBundle, unsupportedQueue }
    public struct TrashEntry: Codable, Sendable, Identifiable {
        public var version: Int = 1
        public var id: String
        public var originalSessionID: String
        public var annotationID: UUID
        public var projectID: String
        public var deletedAt: Date
        public var isRestored: Bool?
        public var expiresAt: Date { deletedAt.addingTimeInterval(7 * 24 * 60 * 60) }
    }
    public static let folder = "mac-queue"
    static let splitFolder = "mac-splitting"
    private let output: URL
    private let projectID: String
    private var automaticallySendNewBatches = false

    public init(output: URL, projectID: String) {
        self.output = output
        self.projectID = projectID
    }

    /// Marks the inbox managed so a later CLI cannot bypass the saved per-batch decisions.
    public func activate() throws {
        struct Header: Codable { var version = 1; var projectID: String }
        let marker = output.appendingPathComponent("mac-inbox.json")
        if FileManager.default.fileExists(atPath: marker.path) {
            let existing = try AnnotationSession.decoder.decode(Header.self, from: Data(contentsOf: marker))
            guard existing.version == 1, existing.projectID == projectID else { throw Failure.unsupportedQueue }
            return
        }
        try writeDurably(AnnotationSession.encoder.encode(Header(projectID: projectID)),
                         to: marker)
    }

    /// Changing this value never rewrites already accepted entries.
    public func setAutomaticallySendNewBatches(_ enabled: Bool) {
        automaticallySendNewBatches = enabled
    }

    /// Adopt pre-existing batches with auto-send disabled before restoring the saved preference.
    public func receiveExisting() throws {
        for id in SessionInbox.sessionIDs(in: output) {
            let session = try SessionInbox.loadSession(id: id, in: output)
            guard session.t3Route?.projectID == projectID else { continue }
            try receive(session, automaticallySend: false)
        }
    }

    public func receive(_ session: AnnotationSession) throws {
        try receive(session, automaticallySend: automaticallySendNewBatches)
    }

    public func receiveAvailable() throws {
        for id in SessionInbox.sessionIDs(in: output) {
            let session = try SessionInbox.loadSession(id: id, in: output)
            guard session.t3Route?.projectID == projectID else { continue }
            try receive(session)
        }
    }

    private func receive(_ session: AnnotationSession, automaticallySend: Bool) throws {
        guard SessionInbox.isValidSessionID(session.id), session.schemaVersion == 1,
              session.t3Route?.projectID == projectID else { throw Failure.invalidBundle }
        if T3DeliveryFiles.read(id: session.id, in: output)?.contentStoredInT3 == true { return }
        let recordURL = entryURL(session.id)
        if !FileManager.default.fileExists(atPath: recordURL.path) {
            try validateCompleteBundle(session)
            let entry = Entry(sessionID: session.id, projectID: projectID, receivedAt: Date(), sendRequested: automaticallySend)
            try writeDurably(AnnotationSession.encoder.encode(entry), to: recordURL)
        } else {
            _ = try readEntry(session.id) // Never overwrite malformed or future-version decisions.
        }
        if session.t3Route?.acceptsMacReceipt == true,
           session.t3Route?.delivery == T3DeliveryFiles.ownedDelivery,
           MacReceiptFiles.read(id: session.id, in: output) == nil {
            try validateCompleteBundle(session)
            // A receipt is the final commit: the complete bundle and queue decision precede it.
            let entry = try readEntry(session.id)
            let receipt = MacReceipt(sessionID: session.id, projectID: projectID, receivedAt: entry.receivedAt)
            try writeDurably(AnnotationSession.encoder.encode(receipt), to: MacReceiptFiles.receiptURL(id: session.id, in: output))
        }
    }

    public func entries() throws -> [Entry] {
        try recoverTrash()
        return try Self.readEntries(output: output, projectID: projectID)
    }

    /// Lists queued entries without recovery or any other write, so a viewer process that does not
    /// own the inbox can display it while the owning process remains its only writer.
    public static func readEntries(output: URL, projectID: String) throws -> [Entry] {
        let directory = output.appendingPathComponent(folder)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".json") && SessionInbox.isValidSessionID(String($0.dropLast(5))) }
            .map { try readEntry(String($0.dropLast(5)), output: output, projectID: projectID) }
            .filter { entry in
                T3DeliveryFiles.read(id: entry.sessionID, in: output) == nil &&
                FileManager.default.fileExists(atPath: SessionInbox.sessionDirectory(entry.sessionID, in: output).appendingPathComponent("session.json").path)
            }
            .sorted { $0.receivedAt < $1.receivedAt }
    }

    /// Snapshot the selected IDs: Send All never authorizes a batch that arrives afterward.
    public func requestSend(ids: [String]) throws {
        try recoverTrash()
        for id in ids {
            var entry = try readEntry(id)
            guard !entry.sendRequested else { continue }
            let session = try SessionInbox.loadSession(id: id, in: output)
            let kept = session.annotations.filter { !entry.excludedAnnotationIDs.contains($0.id) }
            guard !kept.isEmpty else { continue }
            if !entry.excludedAnnotationIDs.isEmpty {
                let destination = output.appendingPathComponent("mac-delivery/\(id)")
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                try MacBundleProjection.write(source: SessionInbox.sessionDirectory(id, in: output), destination: destination, keeping: Set(kept.map(\.id)))
                entry.hasProjection = true
            }
            entry.sendRequested = true
            try writeDurably(AnnotationSession.encoder.encode(entry), to: entryURL(id))
        }
    }

    /// Sends one note now while the rest of its batch stays queued. The note is copied into a new
    /// batch with the same route, which is queued for delivery; the original then excludes it.
    /// Sending a batch's only remaining note sends the batch itself.
    public func sendNote(sessionID: String, annotationID: UUID, now: Date = Date()) throws {
        try recoverTrash()
        var entry = try readEntry(sessionID)
        guard !entry.sendRequested else { throw Failure.invalidBundle }
        let session = try SessionInbox.loadSession(id: sessionID, in: output)
        let remaining = session.annotations.filter { !entry.excludedAnnotationIDs.contains($0.id) }
        guard remaining.contains(where: { $0.id == annotationID }) else { throw Failure.invalidBundle }
        if remaining.count == 1 { return try requestSend(ids: [sessionID]) }
        let id = SessionWriter.makeSessionID(date: now, suffix: String(UUID().uuidString.prefix(8)).lowercased())
        let staging = output.appendingPathComponent("\(Self.splitFolder)/\(id)")
        try MacBundleProjection.write(source: SessionInbox.sessionDirectory(sessionID, in: output), destination: staging, keeping: [annotationID], sessionID: id)
        // The split's queue record is written first but stays invisible until its bundle exists;
        // moving the bundle into place is the commit point, and recovery finishes either side.
        let split = Entry(sessionID: id, projectID: projectID, receivedAt: now, sendRequested: true,
                          splitFromSessionID: sessionID, splitAnnotationID: annotationID)
        try writeDurably(AnnotationSession.encoder.encode(split), to: entryURL(id))
        try commitSplit(split)
        entry.detachedAnnotationIDs = (entry.detachedAnnotationIDs ?? []) + [annotationID]
        try writeDurably(AnnotationSession.encoder.encode(entry), to: entryURL(sessionID))
    }

    private func commitSplit(_ split: Entry) throws {
        let manager = FileManager.default
        let destination = SessionInbox.sessionDirectory(split.sessionID, in: output)
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.moveItem(at: output.appendingPathComponent("\(Self.splitFolder)/\(split.sessionID)"), to: destination)
        try MacBundleProjection.synchronize(directory: destination)
    }

    /// Completes or abandons an interrupted single-note send so no note is sent twice or lost.
    private func recoverSplits() throws {
        let manager = FileManager.default
        let directory = output.appendingPathComponent(Self.folder)
        for name in (try? manager.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasSuffix(".json") {
            let id = String(name.dropLast(5))
            guard SessionInbox.isValidSessionID(id), let split = try? readEntry(id),
                  let originalID = split.splitFromSessionID, let annotationID = split.splitAnnotationID else { continue }
            let committed = manager.fileExists(atPath: SessionInbox.sessionDirectory(id, in: output).appendingPathComponent("session.json").path)
            if !committed {
                if manager.fileExists(atPath: output.appendingPathComponent("\(Self.splitFolder)/\(id)/session.json").path) {
                    try commitSplit(split)
                } else {
                    try manager.removeItem(at: entryURL(id))
                    continue
                }
            }
            if var original = try? readEntry(originalID), !(original.detachedAnnotationIDs ?? []).contains(annotationID) {
                original.detachedAnnotationIDs = (original.detachedAnnotationIDs ?? []) + [annotationID]
                try writeDurably(AnnotationSession.encoder.encode(original), to: entryURL(originalID))
            }
        }
        // Staged copies without a queue record never took ownership of their note.
        let staging = output.appendingPathComponent(Self.splitFolder)
        for id in (try? manager.contentsOfDirectory(atPath: staging.path)) ?? [] where !manager.fileExists(atPath: entryURL(id).path) {
            try manager.removeItem(at: staging.appendingPathComponent(id))
        }
    }

    public func trash(sessionID: String, annotationID: UUID, now: Date = Date()) throws {
        var entry = try readEntry(sessionID)
        guard !entry.sendRequested else { throw Failure.invalidBundle }
        if (entry.trashedAnnotationIDs ?? []).contains(annotationID) { return }
        let session = try SessionInbox.loadSession(id: sessionID, in: output)
        guard session.annotations.contains(where: { $0.id == annotationID }) else { throw Failure.invalidBundle }
        let id = SessionWriter.makeSessionID(date: now, suffix: String(UUID().uuidString.prefix(8)).lowercased())
        let directory = output.appendingPathComponent("mac-trash/\(id)")
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: directory) } }
        try MacBundleProjection.write(source: SessionInbox.sessionDirectory(sessionID, in: output), destination: directory.appendingPathComponent("bundle"), keeping: [annotationID], sessionID: id)
        let record = TrashEntry(id: id, originalSessionID: sessionID, annotationID: annotationID, projectID: projectID, deletedAt: now)
        try writeDurably(AnnotationSession.encoder.encode(record), to: directory.appendingPathComponent("trash.json"))
        committed = true // Recovery completes the queue change if its following write is interrupted.
        entry.trashedAnnotationIDs = (entry.trashedAnnotationIDs ?? []) + [annotationID]
        try writeDurably(AnnotationSession.encoder.encode(entry), to: entryURL(sessionID))
    }

    public func trashEntries() throws -> [TrashEntry] { try allTrashEntries().filter { $0.isRestored != true } }

    /// Lists visible Trash without completing interrupted decisions; only the owning process recovers.
    public static func readTrashEntries(output: URL, projectID: String) throws -> [TrashEntry] {
        try allTrashEntries(output: output, projectID: projectID).filter { $0.isRestored != true }
    }

    private func allTrashEntries() throws -> [TrashEntry] { try Self.allTrashEntries(output: output, projectID: projectID) }

    private static func allTrashEntries(output: URL, projectID: String) throws -> [TrashEntry] {
        let directory = output.appendingPathComponent("mac-trash")
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path).filter(SessionInbox.isValidSessionID).compactMap { id in
            let url = directory.appendingPathComponent("\(id)/trash.json")
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let record = try AnnotationSession.decoder.decode(TrashEntry.self, from: Data(contentsOf: url))
            guard record.version == 1, record.id == id, record.projectID == projectID,
                  SessionInbox.isValidSessionID(record.originalSessionID) else { throw Failure.unsupportedQueue }
            return record
        }.sorted { $0.deletedAt > $1.deletedAt }
    }

    public func restore(trashID: String, now: Date = Date()) throws {
        guard var trash = try allTrashEntries().first(where: { $0.id == trashID }), now < trash.expiresAt else { throw Failure.invalidBundle }
        trash.isRestored = true
        try writeDurably(AnnotationSession.encoder.encode(trash), to: output.appendingPathComponent("mac-trash/\(trashID)/trash.json"))
        try finishRestore(trash)
    }

    private func finishRestore(_ trash: TrashEntry) throws {
        let trashID = trash.id
        let manager = FileManager.default
        let directory = output.appendingPathComponent("mac-trash/\(trashID)")
        if var original = try? readEntry(trash.originalSessionID), !original.sendRequested,
           let session = try? SessionInbox.loadSession(id: original.sessionID, in: output),
           session.annotations.contains(where: { $0.id == trash.annotationID }) {
            original.trashedAnnotationIDs = (original.trashedAnnotationIDs ?? []).filter { $0 != trash.annotationID }
            try writeDurably(AnnotationSession.encoder.encode(original), to: entryURL(original.sessionID))
        } else {
            let destination = SessionInbox.sessionDirectory(trashID, in: output)
            if !manager.fileExists(atPath: destination.path) {
                try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.copyItem(at: directory.appendingPathComponent("bundle"), to: destination)
                try MacBundleProjection.synchronize(directory: destination)
            }
            let session = try SessionInbox.loadSession(id: trashID, in: output)
            try receive(session, automaticallySend: false)
        }
        try manager.removeItem(at: directory)
    }

    /// Finish interrupted user actions before interpreting queue contents or sending anything.
    public func recoverTrash() throws {
        try recoverSplits()
        let directory = output.appendingPathComponent("mac-trash")
        for id in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] where SessionInbox.isValidSessionID(id) {
            let item = directory.appendingPathComponent(id)
            if !FileManager.default.fileExists(atPath: item.appendingPathComponent("trash.json").path) {
                // No commit marker means deletion never took ownership from the original batch.
                try FileManager.default.removeItem(at: item)
            }
        }
        for trash in try allTrashEntries() {
            if trash.isRestored == true {
                try finishRestore(trash)
            } else if var entry = try? readEntry(trash.originalSessionID), !entry.sendRequested,
                      !(entry.trashedAnnotationIDs ?? []).contains(trash.annotationID) {
                entry.trashedAnnotationIDs = (entry.trashedAnnotationIDs ?? []) + [trash.annotationID]
                try writeDurably(AnnotationSession.encoder.encode(entry), to: entryURL(entry.sessionID))
            }
        }
    }

    /// Expiry is enforced on launch and while running, including source copies of deleted notes.
    public func purgeExpiredTrash(now: Date = Date()) throws {
        let manager = FileManager.default
        for trash in try trashEntries() where now >= trash.expiresAt {
            let original = SessionInbox.sessionDirectory(trash.originalSessionID, in: output)
            if manager.fileExists(atPath: original.path) {
                let session = try SessionInbox.loadSession(id: trash.originalSessionID, in: output)
                let kept = Set(session.annotations.filter { $0.id != trash.annotationID }.map(\.id))
                if kept.isEmpty {
                    try manager.removeItem(at: original)
                    try? manager.removeItem(at: entryURL(trash.originalSessionID))
                } else {
                    let compact = output.appendingPathComponent("mac-compacting/\(trash.originalSessionID)")
                    try? manager.removeItem(at: compact)
                    try MacBundleProjection.write(source: original, destination: compact, keeping: kept)
                    // Commit the manifest first, then remove no-longer-referenced images. Sending
                    // uses an immutable projection whenever this batch contains trashed notes.
                    for name in ["prompt.md", "session.json"] {
                        try Data(contentsOf: compact.appendingPathComponent(name)).write(to: original.appendingPathComponent(name), options: .atomic)
                    }
                    guard let enumerator = manager.enumerator(atPath: compact.path) else { throw Failure.invalidBundle }
                    let compactFiles = Set(enumerator.allObjects as? [String] ?? []).union(["t3-delivery.json", "status.json", "replies.json"])
                    let originals = (manager.enumerator(at: original, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL]) ?? []
                    for file in originals where (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
                        let relative = String(file.resolvingSymlinksInPath().path.dropFirst(original.resolvingSymlinksInPath().path.count + 1))
                        if !compactFiles.contains(relative) { try manager.removeItem(at: file) }
                    }
                    try MacBundleProjection.synchronize(directory: original)
                    try manager.removeItem(at: compact)
                }
            }
            try manager.removeItem(at: output.appendingPathComponent("mac-trash/\(trash.id)"))
        }
    }

    private func entryURL(_ id: String) -> URL {
        output.appendingPathComponent(Self.folder).appendingPathComponent("\(id).json")
    }

    private func readEntry(_ id: String) throws -> Entry { try Self.readEntry(id, output: output, projectID: projectID) }

    private static func readEntry(_ id: String, output: URL, projectID: String) throws -> Entry {
        guard SessionInbox.isValidSessionID(id) else { throw Failure.invalidBundle }
        let url = output.appendingPathComponent(folder).appendingPathComponent("\(id).json")
        let entry = try AnnotationSession.decoder.decode(Entry.self, from: Data(contentsOf: url))
        guard entry.version == 1, entry.sessionID == id, entry.projectID == projectID else { throw Failure.unsupportedQueue }
        return entry
    }

    private func validateCompleteBundle(_ session: AnnotationSession) throws {
        let directory = SessionInbox.sessionDirectory(session.id, in: output)
        let manager = FileManager.default
        let resources: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        // Never acknowledge an escaped directory, link, or missing referenced image.
        guard directory.resolvingSymlinksInPath().path == output.resolvingSymlinksInPath().appendingPathComponent("sessions/\(session.id)").path,
              let files = manager.enumerator(at: directory, includingPropertiesForKeys: Array(resources)) else { throw Failure.invalidBundle }
        for case let file as URL in files {
            let values = try file.resourceValues(forKeys: resources)
            guard values.isSymbolicLink != true, values.isRegularFile == true || values.isDirectory == true else { throw Failure.invalidBundle }
            try manager.setAttributes([.posixPermissions: values.isDirectory == true ? 0o700 : 0o600], ofItemAtPath: file.path)
            if values.isRegularFile == true {
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.synchronize()
            }
        }
        let paths = ["session.json", "prompt.md"] + session.screens.flatMap { [$0.image, $0.annotatedImage, $0.hiResImage].compactMap { $0 } }
            + session.annotations.flatMap { [$0.crop].compactMap { $0 } + ($0.attachments ?? []) }
        for path in paths {
            guard SessionInbox.isSafeRelativePath(path),
                  (try directory.appendingPathComponent(path).resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { throw Failure.invalidBundle }
        }
    }

    private func writeDurably(_ data: Data, to url: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }
}
