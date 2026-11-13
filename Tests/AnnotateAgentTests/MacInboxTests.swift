import AnnotateCore
import Foundation
import Testing
@testable import AnnotateAgent

/// Exercises durable handoff, receipt-time auto-send, filtered payloads, and seven-day Trash recovery.
struct MacInboxTests {
    private func fixture(_ run: (URL, MacInboxStore, AnnotationSession) async throws -> Void) async throws {
        let root = try AgentFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = Annotation(index: 1, kind: .point, comment: "KEEP THIS", frame: AnnotationRect(x: 0, y: 0, width: 20, height: 20), crop: "crops/1.png")
        let second = Annotation(index: 2, kind: .point, comment: "DELETE THIS", frame: AnnotationRect(x: 30, y: 30, width: 20, height: 20), crop: "crops/2.png", attachments: ["attachments/deleted.png"])
        let session = AnnotationSession(id: "20261113-010101-batch", createdAt: Date(), app: AppInfo(name: "Koa"),
            device: DeviceInfo(model: "iPhone", systemName: "iOS", systemVersion: "26", isSimulator: false,
                screen: AnnotationSize(width: 402, height: 874), scale: 3, colorScheme: "light", contentSize: "L", orientation: "portrait"),
            screens: [Screen(index: 1, capturedAt: Date(), size: AnnotationSize(width: 402, height: 874), image: "screens/1.png", annotatedImage: "screens/1-annotated.png")],
            annotations: [first, second], t3Route: T3Route(projectID: "koa", threadID: "existing", delivery: T3DeliveryFiles.ownedDelivery, acceptsMacReceipt: true))
        let images = ["screens/1.png", "screens/1-annotated.png", "crops/1.png", "crops/2.png", "attachments/deleted.png"]
        try SessionWriter.write(SessionBundle(session: session, images: Dictionary(uniqueKeysWithValues: images.map { ($0, Data("pixels".utf8)) })),
            prompt: PromptRenderer.render(session, sessionPath: nil, completion: "Keep this completion instruction."), to: root)
        let store = MacInboxStore(output: root, projectID: "koa")
        try await store.activate()
        try await run(root, store, session)
    }

    @Test func togglesOnlyAffectFirstAcceptanceAndRequestsSurviveRestart() async throws {
        try await fixture { root, store, session in
            try await store.receive(session)
            #expect(try await store.entries().first?.sendRequested == false)
            await store.setAutomaticallySendNewBatches(true)
            try await store.receive(session)
            #expect(try await store.entries().first?.sendRequested == false)
            try await store.requestSend(ids: [session.id])
            let restarted = MacInboxStore(output: root, projectID: "koa")
            try await restarted.receiveExisting()
            #expect(try await restarted.entries().first?.sendRequested == true)
            #expect(MacReceiptFiles.read(id: session.id, in: root)?.projectID == "koa")
        }
    }

    @Test func enabledAutoSendIsLatchedAndTurningOffDoesNotRewriteIt() async throws {
        try await fixture { _, store, session in
            await store.setAutomaticallySendNewBatches(true)
            try await store.receive(session)
            await store.setAutomaticallySendNewBatches(false)
            try await store.receive(session)
            #expect(try await store.entries().first?.sendRequested == true)
        }
    }

    @Test func startupAdoptsExistingBundlesWithoutAutomaticallySendingThem() async throws {
        try await fixture { _, store, _ in
            await store.setAutomaticallySendNewBatches(true)
            try await store.receiveExisting()
            #expect(try await store.entries().first?.sendRequested == false)
        }
    }

    @Test func incompleteBundleNeverGetsOwnershipReceiptOrQueueRecord() async throws {
        try await fixture { root, store, session in
            try FileManager.default.removeItem(at: root.appendingPathComponent("sessions/\(session.id)/crops/2.png"))
            await #expect(throws: (any Error).self) { try await store.receive(session) }
            #expect(MacReceiptFiles.read(id: session.id, in: root) == nil)
            #expect(try await store.entries().isEmpty)
        }
    }

    @Test func missingReceiptCanBeRecoveredWithoutReevaluatingAutoSend() async throws {
        try await fixture { root, store, session in
            try await store.receive(session)
            try FileManager.default.removeItem(at: MacReceiptFiles.receiptURL(id: session.id, in: root))
            await store.setAutomaticallySendNewBatches(true)
            try await store.receive(session)
            #expect(MacReceiptFiles.read(id: session.id, in: root) != nil)
            #expect(try await store.entries().first?.sendRequested == false)
        }
    }

    @Test func trashIsExcludedFromManifestPromptAttachmentsAndMarkedFrames() async throws {
        try await fixture { root, store, session in
            let source = root.appendingPathComponent("sessions/\(session.id)")
            var raw = try JSONSerialization.jsonObject(with: Data(contentsOf: source.appendingPathComponent("session.json"))) as! [String: Any]
            raw["futureOptionalField"] = "preserved"
            try JSONSerialization.data(withJSONObject: raw).write(to: source.appendingPathComponent("session.json"))
            try await store.receive(session)
            try await store.trash(sessionID: session.id, annotationID: session.annotations[1].id)
            try await store.requestSend(ids: [session.id])
            let projected = root.appendingPathComponent("mac-delivery/\(session.id)")
            let filtered = try AnnotationSession.decoder.decode(AnnotationSession.self, from: Data(contentsOf: projected.appendingPathComponent("session.json")))
            #expect(filtered.annotations.map(\.id) == [session.annotations[0].id])
            #expect(filtered.screens[0].annotatedImage == nil)
            let prompt = try String(contentsOf: projected.appendingPathComponent("prompt.md"), encoding: .utf8)
            #expect(prompt.contains("KEEP THIS"))
            #expect(prompt.contains("Keep this completion instruction."))
            #expect(!prompt.contains("DELETE THIS"))
            #expect(!FileManager.default.fileExists(atPath: projected.appendingPathComponent("crops/2.png").path))
            #expect(!FileManager.default.fileExists(atPath: projected.appendingPathComponent("attachments/deleted.png").path))
            let manifest = try String(contentsOf: projected.appendingPathComponent("session.json"), encoding: .utf8)
            #expect(manifest.contains("futureOptionalField"))
            #expect(!manifest.contains("DELETE THIS"))
            #expect(try await store.trashEntries().count == 1)
        }
    }

    @Test func restoringReturnsNoteToUnsentBatchAndPreservesRouting() async throws {
        try await fixture { _, store, session in
            try await store.receive(session)
            try await store.trash(sessionID: session.id, annotationID: session.annotations[1].id)
            let trash = try #require(try await store.trashEntries().first)
            try await store.restore(trashID: trash.id)
            #expect(try await store.entries().first?.trashedAnnotationIDs == [])
            #expect(try await store.entries().first?.sendRequested == false)
            #expect(try await store.trashEntries().isEmpty)
        }
    }

    @Test func restoreAfterOriginalDeliveryMakesNewPausedBatch() async throws {
        try await fixture { root, store, session in
            try await store.receive(session)
            try await store.trash(sessionID: session.id, annotationID: session.annotations[1].id)
            let trash = try #require(try await store.trashEntries().first)
            try FileManager.default.removeItem(at: root.appendingPathComponent("sessions/\(session.id)"))
            await store.setAutomaticallySendNewBatches(true)
            try await store.restore(trashID: trash.id)
            let restored = try SessionInbox.loadSession(id: trash.id, in: root)
            #expect(restored.annotations.map(\.id) == [session.annotations[1].id])
            #expect(restored.t3Route?.threadID == "existing")
            #expect(try await store.entries().first?.sendRequested == false)
        }
    }

    @Test func sevenDayExpiryPurgesTrashAndDeletedContentFromOriginalBundle() async throws {
        try await fixture { root, store, session in
            let deletedAt = Date(timeIntervalSince1970: 1_800_000_000)
            try await store.receive(session)
            try await store.trash(sessionID: session.id, annotationID: session.annotations[1].id, now: deletedAt)
            try await store.purgeExpiredTrash(now: deletedAt.addingTimeInterval(7 * 86400 - 1))
            #expect(try await store.trashEntries().count == 1)
            try await store.purgeExpiredTrash(now: deletedAt.addingTimeInterval(7 * 86400))
            #expect(try await store.trashEntries().isEmpty)
            let source = root.appendingPathComponent("sessions/\(session.id)")
            let compact = try SessionInbox.loadSession(id: session.id, in: root)
            #expect(compact.annotations.count == 1)
            #expect(!FileManager.default.fileExists(atPath: source.appendingPathComponent("crops/2.png").path))
            #expect(!FileManager.default.fileExists(atPath: source.appendingPathComponent("screens/1-annotated.png").path))
            #expect(!(try String(contentsOf: source.appendingPathComponent("prompt.md"), encoding: .utf8)).contains("DELETE THIS"))
        }
    }

    @Test func whollyTrashedBatchCannotBeSentAndExpires() async throws {
        try await fixture { root, store, session in
            let deletedAt = Date(timeIntervalSince1970: 1_800_000_000)
            try await store.receive(session)
            for annotation in session.annotations { try await store.trash(sessionID: session.id, annotationID: annotation.id, now: deletedAt) }
            try await store.requestSend(ids: [session.id])
            #expect(try await store.entries().first?.sendRequested == false)
            try await store.purgeExpiredTrash(now: deletedAt.addingTimeInterval(7 * 86400))
            #expect(try await store.entries().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("sessions/\(session.id)").path))
        }
    }

    @Test func interruptedTrashDecisionIsRecoveredBeforeSending() async throws {
        try await fixture { root, store, session in
            try await store.receive(session)
            try await store.trash(sessionID: session.id, annotationID: session.annotations[1].id)
            let path = root.appendingPathComponent("mac-queue/\(session.id).json")
            var raw = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
            raw.removeValue(forKey: "trashedAnnotationIDs")
            try JSONSerialization.data(withJSONObject: raw).write(to: path)
            try await store.requestSend(ids: [session.id])
            let manifest = try String(contentsOf: root.appendingPathComponent("mac-delivery/\(session.id)/session.json"), encoding: .utf8)
            #expect(!manifest.contains("DELETE THIS"))
        }
    }

    @Test func interruptedExpiryRemovesOrphanImagesAndPreservesDeliveryReceipt() async throws {
        try await fixture { root, store, session in
            let deletedAt = Date(timeIntervalSince1970: 1_800_000_000)
            try await store.receive(session)
            try await store.trash(sessionID: session.id, annotationID: session.annotations[1].id, now: deletedAt)
            let source = root.appendingPathComponent("sessions/\(session.id)")
            var compact = session
            compact.annotations.removeLast()
            compact.screens[0].annotatedImage = nil
            try AnnotationSession.encoder.encode(compact).write(to: source.appendingPathComponent("session.json"))
            try Data("legacy delivery".utf8).write(to: source.appendingPathComponent("t3-delivery.json"))
            try await store.purgeExpiredTrash(now: deletedAt.addingTimeInterval(7 * 86400))
            #expect(!FileManager.default.fileExists(atPath: source.appendingPathComponent("crops/2.png").path))
            #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("t3-delivery.json").path))
            #expect(try await store.trashEntries().isEmpty)
        }
    }

    @Test func viewerReadsNeverCompleteRecoveryOrWriteTheQueue() async throws {
        try await fixture { root, store, session in
            try await store.receive(session)
            try await store.trash(sessionID: session.id, annotationID: session.annotations[1].id)
            let path = root.appendingPathComponent("mac-queue/\(session.id).json")
            var raw = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
            raw.removeValue(forKey: "trashedAnnotationIDs")
            let interrupted = try JSONSerialization.data(withJSONObject: raw)
            try interrupted.write(to: path)
            #expect(try MacInboxStore.readEntries(output: root, projectID: "koa").first?.trashedAnnotationIDs == nil)
            #expect(try MacInboxStore.readTrashEntries(output: root, projectID: "koa").count == 1)
            #expect(try Data(contentsOf: path) == interrupted)
            #expect(try await store.entries().first?.trashedAnnotationIDs == [session.annotations[1].id])
        }
    }

    @Test func sendingOneNoteSplitsItIntoAQueuedBatchAndTheOriginalExcludesIt() async throws {
        try await fixture { root, store, session in
            try await store.receive(session)
            let sent = session.annotations[0]
            try await store.sendNote(sessionID: session.id, annotationID: sent.id)
            let entries = try await store.entries()
            let original = try #require(entries.first { $0.sessionID == session.id })
            let split = try #require(entries.first { $0.sessionID != session.id })
            #expect(original.sendRequested == false)
            #expect(original.detachedAnnotationIDs == [sent.id])
            #expect(split.sendRequested == true && split.splitFromSessionID == session.id)
            let splitSession = try SessionInbox.loadSession(id: split.sessionID, in: root)
            #expect(splitSession.annotations.map(\.id) == [sent.id])
            #expect(splitSession.t3Route == session.t3Route)
            try await store.requestSend(ids: [session.id])
            let manifest = try String(contentsOf: root.appendingPathComponent("mac-delivery/\(session.id)/session.json"), encoding: .utf8)
            #expect(!manifest.contains("KEEP THIS") && manifest.contains("DELETE THIS"))
        }
    }

    @Test func sendingTheLastRemainingNoteSendsTheBatchItself() async throws {
        try await fixture { _, store, session in
            try await store.receive(session)
            try await store.trash(sessionID: session.id, annotationID: session.annotations[1].id)
            try await store.sendNote(sessionID: session.id, annotationID: session.annotations[0].id)
            let entries = try await store.entries()
            #expect(entries.count == 1)
            #expect(entries.first?.sendRequested == true)
            #expect(entries.first?.detachedAnnotationIDs == nil)
        }
    }

    @Test func interruptedSplitIsCompletedOrAbandonedWithoutDuplicatingTheNote() async throws {
        try await fixture { root, store, session in
            try await store.receive(session)
            let note = session.annotations[0]
            try await store.sendNote(sessionID: session.id, annotationID: note.id)
            let split = try #require(try await store.entries().first { $0.sessionID != session.id })
            // Interrupted before commit: the bundle is still staged and the original not updated.
            let manager = FileManager.default
            try manager.createDirectory(at: root.appendingPathComponent("mac-splitting"), withIntermediateDirectories: true)
            try manager.moveItem(at: root.appendingPathComponent("sessions/\(split.sessionID)"), to: root.appendingPathComponent("mac-splitting/\(split.sessionID)"))
            let originalURL = root.appendingPathComponent("mac-queue/\(session.id).json")
            var raw = try JSONSerialization.jsonObject(with: Data(contentsOf: originalURL)) as! [String: Any]
            raw.removeValue(forKey: "detachedAnnotationIDs")
            try JSONSerialization.data(withJSONObject: raw).write(to: originalURL)
            #expect(try MacInboxStore.readEntries(output: root, projectID: "koa").count == 1)
            let recovered = try await store.entries()
            #expect(recovered.count == 2)
            #expect(recovered.first { $0.sessionID == session.id }?.detachedAnnotationIDs == [note.id])

            // Interrupted before staging finished: the split record is dropped and the note stays.
            try manager.removeItem(at: root.appendingPathComponent("sessions/\(split.sessionID)"))
            raw.removeValue(forKey: "detachedAnnotationIDs")
            try JSONSerialization.data(withJSONObject: raw).write(to: originalURL)
            let abandoned = try await store.entries()
            #expect(abandoned.map(\.sessionID) == [session.id])
            #expect(abandoned.first?.detachedAnnotationIDs == nil)
            #expect(!manager.fileExists(atPath: root.appendingPathComponent("mac-queue/\(split.sessionID).json").path))
        }
    }

    @Test func viewerReadsRejectAnotherProjectsQueue() async throws {
        try await fixture { root, store, session in
            try await store.receive(session)
            #expect(throws: MacInboxStore.Failure.self) { try MacInboxStore.readEntries(output: root, projectID: "other") }
        }
    }
}

/// Exercises the cross-process command channel between the inbox window app and menu bar extra.
struct MacInboxControlTests {
    @Test func commandsArePreservedInSubmissionOrderUntilCompleted() throws {
        let root = try AgentFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let annotation = UUID()
        try MacInboxControl.enqueue(.setListener(true), in: root, now: start)
        try MacInboxControl.enqueue(.trash(sessionID: "20261113-010101-batch", annotationID: annotation), in: root, now: start.addingTimeInterval(1))
        try MacInboxControl.enqueue(.send(ids: ["20261113-010101-batch"]), in: root, now: start.addingTimeInterval(2))
        let pending = MacInboxControl.pendingCommands(in: root)
        #expect(pending.map(\.command) == [.setListener(true), .trash(sessionID: "20261113-010101-batch", annotationID: annotation), .send(ids: ["20261113-010101-batch"])])
        MacInboxControl.complete(pending[0])
        #expect(MacInboxControl.pendingCommands(in: root).count == 2)
        let mode = try FileManager.default.attributesOfItem(atPath: pending[1].url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func unreadableCommandIsSurfacedForDiscardInsteadOfBlockingLaterCommands() throws {
        let root = try AgentFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("mac-commands")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{\"future\":{}}".utf8).write(to: directory.appendingPathComponent("00000000000000000000-future.json"))
        try MacInboxControl.enqueue(.setAutomaticallySend(false), in: root)
        let pending = MacInboxControl.pendingCommands(in: root)
        #expect(pending.map(\.command) == [nil, .setAutomaticallySend(false)])
        MacInboxControl.complete(pending[0])
        #expect(MacInboxControl.pendingCommands(in: root).map(\.command) == [.setAutomaticallySend(false)])
    }

    @Test func statusRoundTripsAndCanBeCleared() throws {
        let root = try AgentFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let status = MacInboxControl.Status(ownerProcessID: 42, listening: true, automaticallySend: false, sending: true,
            error: "T3 unavailable", updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try MacInboxControl.writeStatus(status, in: root)
        #expect(MacInboxControl.readStatus(in: root) == status)
        MacInboxControl.removeStatus(in: root)
        #expect(MacInboxControl.readStatus(in: root) == nil)
    }
}
