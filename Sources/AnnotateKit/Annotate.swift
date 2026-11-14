// Public entry point. Everything here exists in every configuration so call sites compile in
// Debug and Release; UIKit hosts must authorize installation and invocation. Other platforms are no-ops.
// Public: Annotate.install(_:file:), start(), stop(), toggle(), isActive; AnnotateOptions; PromptDetail

#if canImport(AnnotateCore) // the CocoaPods build compiles AnnotateCore into this module
import AnnotateCore
#endif
import Foundation

#if canImport(AnnotateCore)
/// Re-exported so apps importing only AnnotateKit can write `promptDetail: .compact`.
public typealias PromptDetail = AnnotateCore.PromptDetail
#endif

public struct AnnotateOptions: Sendable {
    /// Floating button that enters annotate mode. Turn off if you trigger it yourself.
    public var showsLauncher: Bool
    /// Where session bundles go. Default: `<project root>/.annotate` in the Simulator (found from the
    /// `install` call site), the app's Documents folder on a device, which `annotate` on the Mac
    /// copies from over the developer connection (no network setup in the app).
    public var outputDirectory: URL?
    /// Turns on the in-process accessibility tree (the first time annotate mode starts, not at
    /// launch) in Debug so un-annotated SwiftUI content is selectable. Release never invokes
    /// the private accessibility hook; location pins and drawings remain available.
    public var enablesAccessibilityTree: Bool
    /// Launch-environment key that starts the app in annotate mode when set to "1", once the first
    /// screen has settled (past launch screens and splash animations). `<key>_DELAY=<seconds>`
    /// waits a fixed time instead.
    public var launchEnvironmentKey: String
    /// Also put the prompt on the clipboard on Send. Off by default: the `annotate` CLI on the Mac
    /// delivers sessions to Claude Code; turn this on to paste into other tools.
    public var copiesPromptToClipboard: Bool
    /// Last paragraph of every prompt.
    public var completionNote: String?
    /// Seconds without any status.json before the overlay says nothing picked the session up.
    public var unclaimedAfter: Double
    /// Also write each screen at native resolution (`screens/N@3x.png`). Off by default: per-pin
    /// crops already carry native-resolution detail, and the full image is the heaviest file.
    public var includesHiResScreens: Bool
    /// Session folders kept in `.annotate/sessions`; older ones are deleted after each Send.
    public var keepsSessions: Int
    /// How much each Send's prompt carries. `.compact` saves tokens; `.detailed` adds every
    /// screen's visible text.
    public var promptDetail: PromptDetail
    /// Called after annotation mode closes and releases its keyboard/window ownership.
    /// Hosts can use this to restore their own invocation responder without observing SDK internals.
    public var onDismiss: (@MainActor @Sendable () -> Void)?
    /// Enables the opt-in T3 Send picker. Use a dedicated `.annotate/t3` output directory and receiver.
    public var t3ProjectID: String?
    /// Permit the menu bar receiver to take durable ownership before sending feedback to T3.
    public var clearsMacReceivedFeedback: Bool
    /// Clear sent feedback content only after T3 owns and acknowledges the complete bundle.
    public var clearsT3DeliveredFeedback: Bool

    public init(
        showsLauncher: Bool = true,
        outputDirectory: URL? = nil,
        enablesAccessibilityTree: Bool = true,
        launchEnvironmentKey: String = "ANNOTATE",
        copiesPromptToClipboard: Bool = false,
        completionNote: String? = "When you're done, finish with a one-line summary of what you changed.",
        unclaimedAfter: Double = 10,
        includesHiResScreens: Bool = false,
        keepsSessions: Int = 30,
        promptDetail: PromptDetail = .standard,
        onDismiss: (@MainActor @Sendable () -> Void)? = nil,
        t3ProjectID: String? = nil,
        clearsMacReceivedFeedback: Bool = false,
        clearsT3DeliveredFeedback: Bool = false
    ) {
        self.showsLauncher = showsLauncher
        self.outputDirectory = outputDirectory
        #if DEBUG
        self.enablesAccessibilityTree = enablesAccessibilityTree
        #else
        self.enablesAccessibilityTree = false
        #endif
        self.launchEnvironmentKey = launchEnvironmentKey
        self.copiesPromptToClipboard = copiesPromptToClipboard
        self.completionNote = completionNote
        self.unclaimedAfter = unclaimedAfter
        self.includesHiResScreens = includesHiResScreens
        self.keepsSessions = keepsSessions
        self.promptDetail = promptDetail
        self.onDismiss = onDismiss
        self.t3ProjectID = t3ProjectID
        self.clearsMacReceivedFeedback = clearsMacReceivedFeedback
        self.clearsT3DeliveredFeedback = clearsT3DeliveredFeedback
    }
}

@MainActor
public enum Annotate {
    /// Call once at launch, e.g. in your `App.init()`. Hosts must gate this call and invocation to their authorized users.
    /// - Parameter file: leave the default — the call site's path locates your project root.
    public static func install(_ options: AnnotateOptions = AnnotateOptions(), file: String = #filePath) {
        #if canImport(UIKit)
        OverlayInstaller.shared.install(options: options, callerFile: file)
        #endif
    }

    /// Enters annotate mode.
    public static func start() {
        #if canImport(UIKit)
        OverlayInstaller.shared.ensureAttached()
        OverlayInstaller.shared.controller.start()
        #endif
    }

    /// Leaves annotate mode, keeping unsent annotations.
    public static func stop() {
        #if canImport(UIKit)
        OverlayInstaller.shared.controller.stop()
        #endif
    }

    /// Removes content acknowledged by T3 or, in a phone container, the opted-in Mac receiver.
    public static func clearDeliveredFeedback(in output: URL) async {
        #if canImport(UIKit)
        _ = await Task.detached(priority: .utility) {
            T3DeliveryFiles.clearAcknowledgedContent(in: output)
            #if !targetEnvironment(simulator)
            MacReceiptFiles.clearAcknowledgedPhoneContent(in: output, isPhoneContainer: true)
            #endif
        }.value
        #endif
    }

    public static func toggle() {
        isActive ? stop() : start()
    }

    public static var isActive: Bool {
        #if canImport(UIKit)
        OverlayInstaller.shared.controller.isActive
        #else
        false
        #endif
    }
}
