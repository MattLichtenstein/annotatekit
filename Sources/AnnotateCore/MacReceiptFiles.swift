import Foundation

/// Acknowledges a complete Mac copy without claiming that T3 has received the feedback.
public struct MacReceipt: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var sessionID: String
    public var projectID: String
    public var receivedAt: Date

    public init(sessionID: String, projectID: String, receivedAt: Date = Date()) {
        self.sessionID = sessionID
        self.projectID = projectID
        self.receivedAt = receivedAt
    }
}

/// Keeps Mac ownership separate from T3 receipts and authorizes cleanup only in a phone container.
public enum MacReceiptFiles {
    public static let folder = "mac-receipts"

    public static func receiptURL(id: String, in output: URL) -> URL {
        output.appendingPathComponent(folder, isDirectory: true).appendingPathComponent("\(id).json")
    }

    public static func read(id: String, in output: URL) -> MacReceipt? {
        guard SessionInbox.isValidSessionID(id),
              let data = try? Data(contentsOf: receiptURL(id: id, in: output)),
              let receipt = try? AnnotationSession.decoder.decode(MacReceipt.self, from: data),
              receipt.version == 1, receipt.sessionID == id else { return nil }
        return receipt
    }

    /// The caller must explicitly identify a phone container; simulator and Mac inboxes share files.
    @discardableResult
    public static func clearAcknowledgedPhoneContent(in output: URL, isPhoneContainer: Bool) -> [String] {
        guard isPhoneContainer else { return [] }
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: output.appendingPathComponent(folder).path)) ?? []
        var cleared: [String] = []
        for name in names where name.hasSuffix(".json") {
            let id = String(name.dropLast(5))
            guard let receipt = read(id: id, in: output),
                  let session = try? SessionInbox.loadSession(id: id, in: output),
                  session.t3Route?.acceptsMacReceipt == true,
                  session.t3Route?.delivery == T3DeliveryFiles.ownedDelivery,
                  session.t3Route?.projectID == receipt.projectID else { continue }
            do {
                try manager.removeItem(at: SessionInbox.sessionDirectory(id, in: output))
                let latest = output.appendingPathComponent("latest")
                if (try? String(contentsOf: latest, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) == "sessions/\(id)" {
                    try? manager.removeItem(at: latest)
                }
                cleared.append(id)
            } catch { continue }
        }
        return cleared
    }
}
