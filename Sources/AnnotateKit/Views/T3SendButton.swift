#if DEBUG && canImport(UIKit)
#if canImport(AnnotateCore)
import AnnotateCore
#endif
import SwiftUI
import UIKit

/// A native menu button: one held touch opens the menu, tracks a destination, and selects on release.
struct T3SendButton: UIViewRepresentable {
    let controller: AnnotateController
    private let snapshot: ThreadMenuSnapshot
    private let canSend: Bool

    init(controller: AnnotateController) {
        self.controller = controller
        // Read observable inputs during SwiftUI evaluation; UIKit receives a stable menu snapshot.
        snapshot = ThreadMenuSnapshot(controller: controller)
        canSend = controller.chrome.canSend
    }

    func makeUIView(context: Context) -> ThreadMenuButton {
        let button = ThreadMenuButton(type: .system)
        button.controller = controller
        button.showsMenuAsPrimaryAction = false
        button.preferredMenuElementOrder = .fixed
        button.accessibilityLabel = "Send"
        button.accessibilityHint = "Tap to send notes. Touch and hold to choose a thread."
        button.accessibilityIdentifier = "annotate-send"
        button.addTarget(button, action: #selector(ThreadMenuButton.sendNotes), for: .primaryActionTriggered)
        return button
    }

    func updateUIView(_ button: ThreadMenuButton, context: Context) {
        button.isEnabled = canSend
        // Freeze destination order while a finger is choosing; later catalog updates apply next time.
        if !button.isPresentingMenu {
            button.configureAppearance(canSend: canSend)
            button.menu = snapshot.menu(controller: controller)
        }
    }

    static func dismantleUIView(_ button: ThreadMenuButton, coordinator: ()) {
        button.contextMenuInteraction?.dismissMenu()
        button.controller?.closeThreadPicker()
    }
}

/// Owns the native control-menu lifecycle so Scroll mode never passes menu touches to the app.
final class ThreadMenuButton: UIButton {
    weak var controller: AnnotateController?
    private(set) var isPresentingMenu = false

    private enum UX {
        static let glyphSize: CGFloat = 17
    }

    func configureAppearance(canSend: Bool) {
        var style: UIButton.Configuration
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { style = canSend ? .prominentGlass() : .glass() }
        else { style = canSend ? .filled() : .gray() }
        #else
        style = canSend ? .filled() : .gray()
        #endif
        style.image = UIImage(systemName: "arrow.up", withConfiguration: UIImage.SymbolConfiguration(pointSize: UX.glyphSize, weight: .medium))
        style.baseForegroundColor = canSend ? .white : .secondaryLabel
        style.baseBackgroundColor = canSend ? UIColor(AnnotateStyle.action) : nil
        style.cornerStyle = .capsule
        style.contentInsets = .zero
        configuration = style
    }

    @objc func sendNotes() {
        guard !isPresentingMenu else { return }
        controller?.send(keepAnnotating: true)
    }

    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let controller, controller.chrome.canSend else { return nil }
        isPresentingMenu = true
        controller.openThreadPicker()
        let configuration = super.contextMenuInteraction(interaction, configurationForMenuAtLocation: location)
        isPresentingMenu = configuration != nil
        if configuration == nil { controller.closeThreadPicker() }
        return configuration
    }

    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willEndFor configuration: UIContextMenuConfiguration, animator: (any UIContextMenuInteractionAnimating)?) {
        super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
        let completion = { [weak self] in
            self?.isPresentingMenu = false
            self?.controller?.closeThreadPicker()
        }
        if let animator { animator.addCompletion(completion) }
        else { completion() }
    }
}

/// Immutable presentation inputs keep native menu order and selection stable throughout a gesture.
private struct ThreadMenuSnapshot {
    let currentTitle: String?
    let selectedID: String?
    let hasReadCatalog: Bool
    let isAvailable: Bool
    let threads: [T3Thread]

    @MainActor init(controller: AnnotateController) {
        currentTitle = controller.selectedT3Route == nil ? nil : controller.selectedThreadTitle ?? "New thread"
        selectedID = controller.selectedT3Route?.threadID
        hasReadCatalog = controller.hasReadThreadCatalog
        isAvailable = controller.threadCatalog?.isLive() == true
            && (!controller.options.clearsT3DeliveredFeedback || controller.threadCatalog?.supportsOwnedDelivery == true)
        threads = Array((controller.threadCatalog?.threads ?? []).prefix(5))
    }

    @MainActor func menu(controller: AnnotateController) -> UIMenu {
        let newThread = UIAction(title: "New thread", subtitle: "Use project defaults", image: UIImage(systemName: "square.and.pencil"), state: selectedID == nil ? .on : .off) { [weak controller] _ in
            controller?.sendToThread(nil)
        }
        let destination = UIMenu(title: currentTitle.map { "Current: \($0)" } ?? "Send to T3", options: .displayInline, children: [newThread])
        let recents: [UIMenuElement]
        if !hasReadCatalog {
            recents = [UIAction(title: "Loading recent threads…", attributes: .disabled) { _ in }]
        } else if !isAvailable {
            recents = [UIAction(title: "Mac unavailable", subtitle: "Send saves notes for later delivery", image: UIImage(systemName: "laptopcomputer.trianglebadge.exclamationmark"), attributes: .disabled) { _ in }]
        } else if threads.isEmpty {
            recents = [UIAction(title: "No recent threads", attributes: .disabled) { _ in }]
        } else {
            recents = threads.map { thread in
                UIAction(title: thread.title, subtitle: thread.isWorking ? "Working · queues next turn" : "Ready", image: UIImage(systemName: "bubble.left"), state: selectedID == thread.id ? .on : .off) { [weak controller] _ in
                    controller?.sendToThread(thread)
                }
            }
        }
        return UIMenu(children: [destination, UIMenu(options: .displayInline, children: recents)])
    }
}
#endif
