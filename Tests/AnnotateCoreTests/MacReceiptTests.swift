import Foundation
import Testing
@testable import AnnotateCore

/// Checks opt-in phone cleanup without granting the Mac permission to delete its only queued copy.
struct MacReceiptTests {
    @Test func macReceiptClearsOnlyOptedInMatchingPhoneContent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var session = AnnotationSession(id: "20261113-010101-mac", createdAt: Date(), app: AppInfo(), device: Fixtures.device, screens: [], annotations: [],
            t3Route: T3Route(projectID: "koa", delivery: T3DeliveryFiles.ownedDelivery, acceptsMacReceipt: true))
        let directory = try SessionWriter.write(SessionBundle(session: session, images: [:]), prompt: "feedback", to: root)
        let url = MacReceiptFiles.receiptURL(id: session.id, in: root)
        try AnnotationSession.encoder.encode(MacReceipt(sessionID: session.id, projectID: "other")).write(to: url)
        #expect(MacReceiptFiles.clearAcknowledgedPhoneContent(in: root, isPhoneContainer: true).isEmpty)
        try AnnotationSession.encoder.encode(MacReceipt(sessionID: session.id, projectID: "koa")).write(to: url)
        #expect(MacReceiptFiles.clearAcknowledgedPhoneContent(in: root, isPhoneContainer: false).isEmpty)
        #expect(T3DeliveryFiles.clearAcknowledgedContent(in: root).isEmpty)
        session.t3Route?.acceptsMacReceipt = nil
        try AnnotationSession.encoder.encode(session).write(to: directory.appendingPathComponent("session.json"))
        #expect(MacReceiptFiles.clearAcknowledgedPhoneContent(in: root, isPhoneContainer: true).isEmpty)
        session.t3Route?.acceptsMacReceipt = true
        try AnnotationSession.encoder.encode(session).write(to: directory.appendingPathComponent("session.json"))
        #expect(MacReceiptFiles.clearAcknowledgedPhoneContent(in: root, isPhoneContainer: true) == [session.id])
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func installedRouteDecoderAndLegacyPendingBatchesKeepTheirContract() throws {
        struct InstalledRoute: Decodable { var projectID: String; var threadID: String?; var conversationID: UUID; var delivery: String? }
        let route = T3Route(projectID: "koa", delivery: T3DeliveryFiles.ownedDelivery, acceptsMacReceipt: true)
        let data = try AnnotationSession.encoder.encode(route)
        #expect(try AnnotationSession.decoder.decode(InstalledRoute.self, from: data).delivery == T3DeliveryFiles.ownedDelivery)
        let old = T3Route(projectID: "koa", delivery: T3DeliveryFiles.ownedDelivery)
        #expect(try AnnotationSession.decoder.decode(T3Route.self, from: AnnotationSession.encoder.encode(old)).acceptsMacReceipt == nil)
        #expect(MacReceiptFiles.read(id: "../outside", in: URL(fileURLWithPath: "/tmp")) == nil)
    }
}
