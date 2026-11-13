import AnnotateCore
import Foundation

/// Coordinates the Mac inbox's window app and menu bar extra, which run as separate processes.
///
/// Only the process holding the receiver lock writes the queue. Every other process is a viewer:
/// it reads the queue without mutating it, reads the owner's published status, and submits its
/// actions as durable command files that the owner applies in order. Commands survive a handoff,
/// so an action submitted just before the owner quits is applied by the next owner.
public enum MacInboxControl {
    public enum Command: Codable, Sendable, Equatable {
        case send(ids: [String])
        case sendNote(sessionID: String, annotationID: UUID)
        case trash(sessionID: String, annotationID: UUID)
        case restore(trashID: String)
        case setListener(Bool)
        case setAutomaticallySend(Bool)
    }

    /// What the owner last published for viewers. Viewers ignore a status whose owner is gone.
    public struct Status: Codable, Sendable, Equatable {
        public var version: Int = 1
        public var ownerProcessID: Int32
        public var listening: Bool
        public var automaticallySend: Bool
        public var sending: Bool
        public var error: String?
        public var updatedAt: Date

        public init(ownerProcessID: Int32, listening: Bool, automaticallySend: Bool, sending: Bool, error: String?, updatedAt: Date = Date()) {
            self.ownerProcessID = ownerProcessID
            self.listening = listening
            self.automaticallySend = automaticallySend
            self.sending = sending
            self.error = error
            self.updatedAt = updatedAt
        }
    }

    public struct PendingCommand: Sendable {
        public var url: URL
        public var command: Command?
    }

    static let commandFolder = "mac-commands"
    static let statusFile = "mac-inbox-status.json"

    /// Writes a command atomically; the sortable name preserves submission order across processes.
    public static func enqueue(_ command: Command, in output: URL, now: Date = Date()) throws {
        let directory = output.appendingPathComponent(commandFolder)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stamp = String(format: "%020llu", UInt64(max(0, now.timeIntervalSince1970) * 1_000_000_000))
        let url = directory.appendingPathComponent("\(stamp)-\(UUID().uuidString.lowercased()).json")
        try AnnotationSession.encoder.encode(command).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Lists submitted commands oldest first. An unreadable command is returned without a value so
    /// the owner can discard it instead of retrying it forever.
    public static func pendingCommands(in output: URL) -> [PendingCommand] {
        let directory = output.appendingPathComponent(commandFolder)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.sorted().map { name in
            let url = directory.appendingPathComponent(name)
            let command = (try? Data(contentsOf: url)).flatMap { try? AnnotationSession.decoder.decode(Command.self, from: $0) }
            return PendingCommand(url: url, command: command)
        }
    }

    public static func hasPendingCommands(in output: URL) -> Bool { !pendingCommands(in: output).isEmpty }

    public static func complete(_ command: PendingCommand) { try? FileManager.default.removeItem(at: command.url) }

    public static func writeStatus(_ status: Status, in output: URL) throws {
        let url = output.appendingPathComponent(statusFile)
        try AnnotationSession.encoder.encode(status).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func readStatus(in output: URL) -> Status? {
        guard let data = try? Data(contentsOf: output.appendingPathComponent(statusFile)),
              let status = try? AnnotationSession.decoder.decode(Status.self, from: data), status.version == 1 else { return nil }
        return status
    }

    public static func removeStatus(in output: URL) { try? FileManager.default.removeItem(at: output.appendingPathComponent(statusFile)) }
}
