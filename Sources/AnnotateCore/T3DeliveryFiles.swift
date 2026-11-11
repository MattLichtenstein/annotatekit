import Foundation

/// Stores content-free delivery receipts separately from feedback that can be deleted after upload.
public enum T3DeliveryFiles {
    public static let folder = "deliveries"
    public static let ownedDelivery = "t3-owned-bundle-v1"

    public static func receiptURL(id: String, in output: URL) -> URL {
        output.appendingPathComponent(folder, isDirectory: true).appendingPathComponent("\(id).json")
    }

    public static func read(id: String, in output: URL) -> T3DeliveryReceipt? {
        guard SessionInbox.isValidSessionID(id) else { return nil }
        let paths = [receiptURL(id: id, in: output),
                     SessionInbox.sessionDirectory(id, in: output).appendingPathComponent(T3DeliveryReceipt.fileName)]
        for path in paths {
            if let data = try? Data(contentsOf: path),
               let receipt = try? AnnotationSession.decoder.decode(T3DeliveryReceipt.self, from: data),
               receipt.version == 1, receipt.sessionID == id { return receipt }
        }
        return nil
    }

    /// A queued text message or legacy receipt cannot authorize screenshot deletion.
    @discardableResult
    public static func clearAcknowledgedContent(in output: URL, fileManager: FileManager = .default) -> [String] {
        let folder = output.appendingPathComponent(Self.folder, isDirectory: true)
        let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        var cleared: [String] = []
        for name in names where name.hasSuffix(".json") {
            let id = String(name.dropLast(5))
            guard let receipt = read(id: id, in: output), receipt.contentStoredInT3 == true,
                  let session = try? SessionInbox.loadSession(id: id, in: output),
                  session.t3Route?.delivery == ownedDelivery else { continue }
            let directory = SessionInbox.sessionDirectory(id, in: output)
            do {
                try fileManager.removeItem(at: directory)
                cleared.append(id)
                let latest = output.appendingPathComponent("latest")
                if (try? String(contentsOf: latest, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) == "sessions/\(id)" {
                    try? fileManager.removeItem(at: latest)
                }
            } catch { continue } // Retry cleanup at the next presence read; keep the durable receipt.
        }
        return cleared
    }
}
