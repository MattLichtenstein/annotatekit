#if os(macOS)
import AppKit
import Combine
import Foundation

/// Saves menu bar launch mode and waits for actual process launch/termination before settling the switch.
@MainActor
final class MenuBarExtraController: ObservableObject {
    @Published private(set) var isShown = InboxPreferences.showInMenuBar
    @Published private(set) var isChanging = false
    @Published private(set) var error: String?
    let helperURL = InboxSurface.menuBarHelperURL
    var isAvailable: Bool { helperURL != nil }
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.isChanging else { return }
                    self.isShown = InboxPreferences.showInMenuBar
                }
            })
        }
    }

    /// The saved preference chooses Finder/Spotlight behavior; running the window never enables it.
    func setShown(_ shown: Bool) {
        guard !isChanging, shown != isShown, let helperURL else { return }
        isChanging = true
        error = nil
        let previous = isShown
        isShown = shown
        Task {
            do {
                if shown {
                    // The menu process reads this before deciding whether to show its status item
                    // or forward an ordinary launch to the window app.
                    InboxPreferences.showInMenuBar = true
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = false
                    let app = try await NSWorkspace.shared.openApplication(at: helperURL, configuration: configuration)
                    guard !app.isTerminated else { throw LaunchFailure.unavailable }
                } else {
                    let applications = NSRunningApplication.runningApplications(withBundleIdentifier: InboxSurface.menuBarBundleID)
                        .filter { !$0.isTerminated }
                    guard applications.allSatisfy({ $0.terminate() }) else { throw LaunchFailure.unavailable }
                    // Graceful termination drains the receiver before releasing ownership. Workspace
                    // launch notifications alone can arrive before a helper is registered, so don't
                    // use one stale notification snapshot as the result of either transition.
                    for _ in 0..<Timing.terminationChecks {
                        if applications.allSatisfy(\.isTerminated) { break }
                        try await Task.sleep(for: Timing.terminationInterval)
                    }
                    guard applications.allSatisfy(\.isTerminated) else { throw LaunchFailure.unavailable }
                    InboxPreferences.showInMenuBar = false
                }
            } catch {
                InboxPreferences.showInMenuBar = previous
                isShown = previous
                self.error = shown
                    ? "The menu bar app could not start. Try again or reinstall Annotate Inbox."
                    : "The menu bar app has not finished quitting. Try again in a moment."
            }
            isChanging = false
        }
    }

    private enum LaunchFailure: Error { case unavailable }
    private enum Timing {
        static let terminationChecks = 100
        static let terminationInterval: Duration = .milliseconds(100)
    }
}
#endif
