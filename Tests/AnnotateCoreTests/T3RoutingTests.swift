import Foundation
import Testing
@testable import AnnotateCore

/// Verifies optional routing remains compatible with schema 1 and protects durable offline batches.
struct T3RoutingTests {
    @Test func onlyAnOwnedReceiptCanClearMatchingFeedback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var session = AnnotationSession(id: "20261112-120000-owned", createdAt: Date(), app: AppInfo(),
            device: Fixtures.device, screens: [], annotations: [])
        session.t3Route = T3Route(projectID: "koa", delivery: T3DeliveryFiles.ownedDelivery)
        let directory = try SessionWriter.write(SessionBundle(session: session, images: ["screens/1.png": Data("pixels".utf8)]), prompt: "feedback", to: root)
        var receipt = T3DeliveryReceipt(sessionID: session.id, threadID: "thread", title: "Feedback", link: "local")
        let receiptURL = T3DeliveryFiles.receiptURL(id: session.id, in: root)
        try AnnotationSession.encoder.encode(receipt).write(to: receiptURL)
        #expect(T3DeliveryFiles.clearAcknowledgedContent(in: root).isEmpty)
        #expect(FileManager.default.fileExists(atPath: directory.path))
        var history = T3NoteHistory()
        let note = PinResult(index: 1, comment: "Feedback", subject: "Button", intent: .fix, outcome: .open)
        history.record(id: session.id, sentAt: session.createdAt, notes: [note])
        receipt.contentStoredInT3 = true
        history.acknowledge(receipt)
        try AnnotationSession.encoder.encode(receipt).write(to: receiptURL)
        #expect(T3DeliveryFiles.clearAcknowledgedContent(in: root) == [session.id])
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(history.batches.first?.filter == .sent)
        #expect(history.batches.first?.notes == [note])
        #expect(FileManager.default.fileExists(atPath: receiptURL.path))
        #expect(T3DeliveryFiles.read(id: session.id, in: root)?.threadID == "thread")
        #expect(T3DeliveryFiles.read(id: "../outside", in: root) == nil)
    }

    @Test func ownedPromptsUseGenericInstructionsAndPortableArtifactPaths() {
        var session = AnnotationSession(id: "20261112-120000-owned", createdAt: Date(), app: AppInfo(),
            device: Fixtures.device, screens: [Fixtures.screen], annotations: [])
        session.t3Route = T3Route(projectID: "koa", delivery: T3DeliveryFiles.ownedDelivery)
        let prompt = PromptRenderer.render(session, sessionPath: "/private/deleted-bundle")
        #expect(!prompt.contains("/private/deleted-bundle"))
        #expect(!prompt.contains("annotate ack"))
        #expect(prompt.contains("Fix notes request code changes"))
        #expect(!prompt.contains("Hide / Keep"))
    }

    @Test func catalogsAreBoundedAndExpire() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let catalog = T3ThreadCatalog(projectID: "koa", updatedAt: now, isAvailable: true,
            threads: (0..<10).map { T3Thread(id: String($0), title: "Thread", isWorking: false) })
        #expect(catalog.threads.count == 5)
        #expect(catalog.isLive(now: now))
        #expect(!catalog.isLive(now: now.addingTimeInterval(31)))
        #expect(!catalog.isLive(now: now.addingTimeInterval(-31)))
        #expect(try AnnotationSession.decoder.decode(T3ThreadCatalog.self, from: AnnotationSession.encoder.encode(catalog)) == catalog)
    }

    @Test func legacySessionsDecodeWithoutRoutingAndOfflineBundlesSurvivePruning() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        var session = AnnotationSession(id: SessionWriter.makeSessionID(date: now.addingTimeInterval(-7 * 86400)),
            createdAt: now, app: AppInfo(), device: Fixtures.device, screens: [], annotations: [])
        let legacy = try AnnotationSession.encoder.encode(session)
        #expect(try AnnotationSession.decoder.decode(AnnotationSession.self, from: legacy).t3Route == nil)
        session.t3Route = T3Route(projectID: "koa")
        let directory = SessionInbox.sessionDirectory(session.id, in: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try AnnotationSession.encoder.encode(session).write(to: directory.appendingPathComponent("session.json"))
        #expect(SessionInbox.prune(keeping: 0, in: root, now: now).isEmpty)
        let receipt = T3DeliveryReceipt(sessionID: session.id, threadID: "thread", title: "Review", link: "local")
        try AnnotationSession.encoder.encode(receipt).write(to: directory.appendingPathComponent(T3DeliveryReceipt.fileName))
        #expect(SessionInbox.prune(keeping: 0, in: root, now: now).isEmpty)
    }
}
