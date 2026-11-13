#if os(macOS)
import AppKit
import Combine
import SwiftUI

/// Runs the window scene or the menu bar process, which routes ordinary launches by preference.
@MainActor
enum InboxLaunch {
    static var configuration: ReceiverService.Configuration?
    static var surface = InboxSurface.window

    static func run(_ surface: InboxSurface, configuration: ReceiverService.Configuration) {
        self.configuration = configuration
        self.surface = surface
        switch surface {
        case .window: InboxWindowApp.main()
        case .menuBar:
            // The extra uses AppKit directly: SwiftUI's MenuBarExtra cannot close its panel when
            // the menu bar icon is clicked again.
            let application = NSApplication.shared
            let delegate = InboxAppDelegate()
            application.delegate = delegate
            withExtendedLifetime(delegate) { application.run() }
        }
    }
}

/// Owns the process's inbox model and releases receiver ownership before either app quits.
@MainActor
final class InboxAppDelegate: NSObject, NSApplicationDelegate {
    let model: InboxModel
    private var isQuitting = false
    private var modelStarted = false
    private var statusItem: InboxStatusItem?

    override init() {
        guard let configuration = InboxLaunch.configuration else { fatalError("Inbox launched without a configuration") }
        model = InboxModel(configuration: configuration)
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Command-line runs have no Info.plist, so set the role-appropriate Dock presence here too.
        NSApplication.shared.setActivationPolicy(InboxLaunch.surface == .window ? .regular : .accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if InboxLaunch.surface == .menuBar {
            guard Bundle.main.bundleIdentifier != InboxSurface.menuBarBundleID || InboxPreferences.showInMenuBar else {
                openWindowAndQuit()
                return
            }
            statusItem = InboxStatusItem(model: model)
        }
        model.start()
        modelStarted = true
    }

    /// Reopening from Finder/Spotlight never raises the window while menu bar mode is enabled.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard InboxLaunch.surface == .menuBar else { return true }
        if Bundle.main.bundleIdentifier == InboxSurface.menuBarBundleID, !InboxPreferences.showInMenuBar { openWindowAndQuit() }
        return false
    }

    private func openWindowAndQuit() {
        guard let app = InboxSurface.windowAppURL else {
            showLaunchError()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: app, configuration: configuration) { [weak self] _, error in
            // AppKit can enter a nested run loop while waiting for terminateLater. Calling it
            // from a Swift task would hold the main actor and prevent shutdown's reply task.
            DispatchQueue.main.async {
                if error != nil { self?.showLaunchError() }
                else { NSApplication.shared.terminate(nil) }
            }
        }
    }

    private func showLaunchError() {
        let alert = NSAlert()
        alert.messageText = "Annotate Inbox could not open"
        alert.informativeText = "Reinstall Annotate Inbox and try again. Your queued annotations are preserved."
        alert.runModal()
        NSApplication.shared.terminate(nil)
    }

    /// Closing the window quits the window app, which hands ownership to a running menu bar extra.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        InboxLaunch.surface == .window
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A launch forwarded to the window owns no receiver or background work to drain.
        // Finish synchronously so AppKit never waits in a nested quit loop for a queued reply.
        guard modelStarted, !isQuitting else { return .terminateNow }
        isQuitting = true
        Task {
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// The nested window app provides full review, Trash, and settings; closing it leaves the menu app alone.
struct InboxWindowApp: App {
    @NSApplicationDelegateAdaptor(InboxAppDelegate.self) private var delegate
    @StateObject private var menuBarExtra = MenuBarExtraController()

    var body: some Scene {
        Window("Annotate Inbox", id: "inbox") {
            InboxInspector(model: delegate.model, menuBarExtra: menuBarExtra)
                .onOpenURL { url in
                    switch InboxDestination(url: url) {
                    case let .batch(id): delegate.model.selection = id
                    case .trash: delegate.model.selection = delegate.model.trashItems.first.map { "trash:\($0.id)" } ?? "trash-empty"
                    case .inbox, nil: break
                    }
                }
        }
        .defaultSize(width: UX.windowWidth, height: UX.windowHeight)
        .handlesExternalEvents(matching: [InboxSurface.urlScheme])
        .commands {
            CommandGroup(after: .newItem) {
                Button("Show Inbox in Finder") { NSWorkspace.shared.open(delegate.model.configuration.output) }
            }
            // Settings is a page in the window's sidebar rather than a separate window.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { delegate.model.selection = InboxInspector.settingsSelection }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }

    private enum UX {
        static let windowWidth: CGFloat = 960
        static let windowHeight: CGFloat = 680
    }
}

/// The menu bar extra's status item and panel. Clicking the icon toggles the panel; it also closes
/// when another app becomes active, so the extra behaves like a native menu bar item.
@MainActor
private final class InboxStatusItem: NSObject {
    private let model: InboxModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private var observers: [NSObjectProtocol] = []
    private var keyMonitor: Any?
    private var outsideClickMonitor: Any?
    private var iconUpdates: AnyCancellable?

    init(model: InboxModel) {
        self.model = model
        super.init()
        // Application-defined: a transient popover closes on the icon's mouse-down and then the
        // click reopens it. Closing on resign-active and Escape replaces transient dismissal.
        popover.behavior = .applicationDefined
        let content = InboxPanel(model: model, open: InboxSurface.windowAppURL.map { app in { [weak self] destination in
            self?.close()
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([destination.url], withApplicationAt: app, configuration: configuration)
        } }, quit: {
            // Quitting from the menu bar quits the whole app: the window app, then this extra.
            NSRunningApplication.runningApplications(withBundleIdentifier: InboxSurface.windowBundleID).forEach { $0.terminate() }
            NSApplication.shared.terminate(nil)
        })
        let controller = NSHostingController(rootView: content)
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        item.button?.target = self
        item.button?.action = #selector(toggle)
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        })
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == UX.escapeKeyCode else { return event }
            MainActor.assumeIsolated { self?.close() }
            return nil
        }
        iconUpdates = model.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.updateIcon() }
        }
        updateIcon()
    }

    private func updateIcon() {
        let image = NSImage(systemSymbolName: model.listenerEnabled ? "tray.and.arrow.down" : "tray", accessibilityDescription: "Annotate Inbox")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "Annotate Inbox — \(model.status)"
    }

    @objc private func toggle() {
        if popover.isShown { close(); return }
        guard let button = item.button else { return }
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSApplication.shared.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        button.highlight(true)
        // Clicks in other apps, including their menu bar items, don't always change the active
        // app. Mouse-only global monitors need no accessibility permission.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private func close() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        guard popover.isShown else { return }
        popover.performClose(nil)
        item.button?.highlight(false)
    }

    private enum UX { static let escapeKeyCode: UInt16 = 53 }
}

#endif
