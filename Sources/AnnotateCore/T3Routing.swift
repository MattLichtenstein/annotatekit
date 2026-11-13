import Foundation

/// Non-secret routing metadata shared by the phone and the Mac-only T3 adapter.
public struct T3Route: Codable, Sendable, Equatable {
    public var projectID: String
    /// Set for an existing destination; otherwise conversationID identifies one new thread.
    public var threadID: String?
    /// Process-local identity, persisted with each batch so offline sends share their new thread.
    public var conversationID: UUID
    /// Additive capability: T3 must own the complete bundle before local content can be cleared.
    public var delivery: String?
    /// Opt-in to transferring phone storage ownership to the Mac before T3 delivery.
    public var acceptsMacReceipt: Bool?

    public init(projectID: String, threadID: String? = nil, conversationID: UUID = UUID(), delivery: String? = nil, acceptsMacReceipt: Bool? = nil) {
        self.projectID = projectID
        self.threadID = threadID
        self.conversationID = conversationID
        self.delivery = delivery
        self.acceptsMacReceipt = acceptsMacReceipt
    }
}

/// A bounded, replaceable catalog, never a credential or a copy of thread messages.
public struct T3ThreadCatalog: Codable, Sendable, Equatable {
    public static let fileName = "t3-threads.json"
    public static let staleAfter: TimeInterval = 30
    public var version: Int = 1
    public var projectID: String
    public var updatedAt: Date
    public var isAvailable: Bool
    public var threads: [T3Thread]
    public var supportsOwnedDelivery: Bool?

    public init(projectID: String, updatedAt: Date = Date(), isAvailable: Bool, threads: [T3Thread], supportsOwnedDelivery: Bool? = nil) {
        self.projectID = projectID
        self.updatedAt = updatedAt
        self.isAvailable = isAvailable
        self.threads = Array(threads.prefix(5))
        self.supportsOwnedDelivery = supportsOwnedDelivery
    }

    public func isLive(now: Date = Date()) -> Bool {
        version == 1 && isAvailable && abs(now.timeIntervalSince(updatedAt)) < Self.staleAfter
    }
}

/// The minimum thread information needed to choose a destination.
public struct T3Thread: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var isWorking: Bool

    public init(id: String, title: String, isWorking: Bool) {
        self.id = id
        self.title = title
        self.isWorking = isWorking
    }
}

/// Delivery acknowledgement, distinct from an agent starting or completing the requested work.
public struct T3DeliveryReceipt: Codable, Sendable, Equatable {
    public static let fileName = "t3-delivery.json"
    public var version: Int = 1
    public var sessionID: String
    public var threadID: String
    public var title: String
    public var link: String
    public var contentStoredInT3: Bool?

    public init(sessionID: String, threadID: String, title: String, link: String, contentStoredInT3: Bool? = nil) {
        self.sessionID = sessionID
        self.threadID = threadID
        self.title = title
        self.link = link
        self.contentStoredInT3 = contentStoredInT3
    }
}
