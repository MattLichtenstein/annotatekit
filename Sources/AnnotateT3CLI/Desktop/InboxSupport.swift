#if os(macOS)
import AnnotateCore
import AppKit
import Foundation

/// Identifies the two inbox surfaces packaged in one app bundle and how each finds the other.
///
/// Finder opens the outer menu bar app, which forwards to its nested window app when the saved
/// menu bar preference is off. Each surface keeps its existing bundle identifier and process.
enum InboxSurface {
    case window
    case menuBar

    static let windowBundleID = "dev.annotatekit.inbox"
    static let menuBarBundleID = "dev.annotatekit.inbox.menu"
    static let windowHelperPath = "Contents/Helpers/Annotate Inbox Window.app"
    static let urlScheme = "annotate-inbox"

    /// The enclosing menu bar app, when running from its nested window app.
    static var menuBarHelperURL: URL? {
        var url = Bundle.main.bundleURL
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return Bundle(url: url)?.bundleIdentifier == menuBarBundleID ? url : nil
    }

    /// The nested window app, opened only by explicit menu actions while menu bar mode is enabled.
    static var windowAppURL: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent(windowHelperPath)
        return Bundle(url: url)?.bundleIdentifier == windowBundleID ? url : nil
    }
}

/// Where the window app should open when the menu bar extra hands off to it.
enum InboxDestination: Equatable {
    case inbox
    case batch(String)
    case trash

    var url: URL {
        switch self {
        case .inbox: URL(string: "\(InboxSurface.urlScheme)://inbox")!
        case let .batch(id): URL(string: "\(InboxSurface.urlScheme)://batch/\(id)")!
        case .trash: URL(string: "\(InboxSurface.urlScheme)://trash")!
        }
    }

    init?(url: URL) {
        guard url.scheme == InboxSurface.urlScheme else { return nil }
        switch url.host() {
        case "inbox": self = .inbox
        case "trash": self = .trash
        case "batch":
            let id = url.lastPathComponent
            guard SessionInbox.isValidSessionID(id) else { return nil }
            self = .batch(id)
        default: return nil
        }
    }
}

/// Saved receiver choices shared by both surfaces under the window app's preference domain.
enum InboxPreferences {
    static let listenerKey = "listenerEnabled"
    static let automaticallySendKey = "automaticallySendNewBatches"
    static let showInMenuBarKey = "showInMenuBar"

    /// Synchronize before crossing a process boundary so a newly launched peer sees the choice.
    /// An absent key is false, preserving window-first behavior until the user enables the extra.
    static var showInMenuBar: Bool {
        get {
            shared.synchronize()
            return shared.bool(forKey: showInMenuBarKey)
        }
        set {
            shared.set(newValue, forKey: showInMenuBarKey)
            shared.synchronize()
        }
    }

    /// A process cannot open its own bundle identifier as a suite, so the window app uses its
    /// standard defaults; the menu bar extra and command-line runs open that same domain by name.
    /// UserDefaults is documented as thread-safe.
    nonisolated(unsafe) static let shared: UserDefaults = Bundle.main.bundleIdentifier == InboxSurface.windowBundleID
        ? .standard : UserDefaults(suiteName: InboxSurface.windowBundleID) ?? .standard
}

/// Cross-process wake-ups. Payloads stay on disk; these only prompt an immediate refresh.
enum InboxSignal {
    static let commandsSubmitted = Notification.Name("dev.annotatekit.inbox.commandsSubmitted")
    static let stateChanged = Notification.Name("dev.annotatekit.inbox.stateChanged")
}

/// Formats when the phone sent a batch, without a continuously updating relative timer.
enum InboxDateFormat {
    static func sent(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday, \(time)"
        }
        let day = calendar.isDate(date, equalTo: now, toGranularity: .year)
            ? date.formatted(.dateTime.month(.abbreviated).day())
            : date.formatted(.dateTime.month(.abbreviated).day().year())
        return "\(day), \(time)"
    }
}

extension ReceiverService.Item {
    /// A batch is named for where it goes: the T3 thread it continues, or New Thread.
    var title: String { destination }

    var noteCount: String { "\(annotations.count) \(annotations.count == 1 ? "note" : "notes")" }

    var sentAt: String { InboxDateFormat.sent(session.createdAt) }

}
#endif
