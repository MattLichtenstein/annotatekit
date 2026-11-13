#if os(macOS)
import AnnotateCore
import AppKit
import SwiftUI

/// The window app has queued batches, initially collapsed Trash, and Settings in its sidebar.
/// Its detail pane shows each screenshot and its numbered notes together on one surface.
struct InboxInspector: View {
    static let settingsSelection = "settings"

    @ObservedObject var model: InboxModel
    @ObservedObject var menuBarExtra: MenuBarExtraController
    @State private var isTrashExpanded = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: UX.minimumSidebarWidth, ideal: UX.sidebarWidth)
        } detail: {
            detail
                .frame(minWidth: UX.minimumDetailWidth)
                .background(.background)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.send(ids: model.sendableItems.map(\.id)) } label: {
                    Label { Text("Send All") } icon: { FormationPaperplaneIcon() }
                }
                    .disabled(model.sendableItems.isEmpty)
                    .help("Send every queued batch to T3")
            }
        }
        .navigationSubtitle(model.status)
        .onReceive(model.$selection) { selection in
            // Explicit Show Trash requests reveal the section, even if the same note is selected.
            if selection?.hasPrefix("trash:") == true || selection == "trash-empty" {
                isTrashExpanded = true
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $model.selection) {
            Section("Queue") {
                ForEach(model.queuedItems) { item in
                    BatchSidebarRow(item: item).tag(item.id)
                }
                if model.queuedItems.isEmpty {
                    Text("No queued annotations").foregroundStyle(.secondary)
                }
            }
            Section("Trash", isExpanded: $isTrashExpanded) {
                ForEach(model.trashItems) { item in
                    VStack(alignment: .leading, spacing: UX.rowSpacing) {
                        Text(item.session.annotations.first?.comment.nonEmpty ?? "Visual feedback").lineLimit(1)
                        Text("Deleted \(InboxDateFormat.sent(item.entry.deletedAt))")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.vertical, UX.rowVerticalPadding)
                    .tag("trash:\(item.id)")
                }
                if model.trashItems.isEmpty { Text("Trash is empty").foregroundStyle(.secondary) }
                Text("Kept for 7 days").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                let isActive = model.selection == Self.settingsSelection
                Button { model.selection = Self.settingsSelection } label: {
                    Image(systemName: isActive ? "gearshape.fill" : "gearshape")
                        .font(.title3)
                        .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.borderless)
                .help("Settings (⌘,)")
                .accessibilityLabel("Settings")
                Spacer()
            }
            .padding(.horizontal, UX.footerPadding * 1.6).padding(.vertical, UX.footerPadding)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        VStack(spacing: 0) {
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, UX.contentPadding).padding(.vertical, UX.bannerVerticalPadding)
                    .background(.bar)
                Divider()
            }
            if model.selection == Self.settingsSelection {
                InboxSettingsPage(model: model, menuBarExtra: menuBarExtra)
            } else if let item = model.items.first(where: { $0.id == model.selection && !$0.annotations.isEmpty }) {
                batchDetail(item)
            } else if let item = model.trashItems.first(where: { "trash:\($0.id)" == model.selection }) {
                trashDetail(item)
            } else if model.selection == "trash-empty" {
                ContentUnavailableView("Trash Is Empty", systemImage: "trash",
                    description: Text("Deleted notes stay here for seven days."))
            } else if model.queuedItems.isEmpty {
                ContentUnavailableView("No Annotations", systemImage: "tray",
                    description: Text(model.listenerEnabled ? "New feedback from your phone will appear here." : "Turn on the listener in Settings to receive feedback from your phone."))
            } else {
                ContentUnavailableView("No Batch Selected", systemImage: "tray.full",
                    description: Text("Choose a batch to review its notes and screenshots."))
            }
        }
    }

    private func batchDetail(_ item: ReceiverService.Item) -> some View {
        let directory = batchDirectory(item.id)
        let screens = item.session.screens.filter { screen in item.annotations.contains { $0.screen == screen.index } }
        let orphanNotes = item.annotations.filter { note in !item.session.screens.contains { $0.index == note.screen } }
        let locked = item.entry.sendRequested
        return ScrollView {
            VStack(alignment: .leading, spacing: UX.sectionSpacing) {
                HStack(alignment: .top, spacing: UX.headerSpacing) {
                    VStack(alignment: .leading, spacing: UX.headerTextSpacing) {
                        Text(item.title).font(.title2.weight(.semibold)).lineLimit(2).textSelection(.enabled)
                        Text(batchSubtitle(item)).foregroundStyle(.secondary)
                        if let error = item.error {
                            Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                        } else if locked {
                            Label("Queued for delivery. Notes can’t change while it sends.", systemImage: "lock")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    batchAction(item)
                }

                ForEach(screens) { screen in
                    let hasTrashedMarkup = item.session.annotations.contains { $0.screen == screen.index && item.entry.excludedAnnotationIDs.contains($0.id) }
                    ScreenCard(directory: directory, title: "Screen \(screen.index)",
                        imagePath: hasTrashedMarkup ? screen.image : (screen.annotatedImage ?? screen.image),
                        notes: item.annotations.filter { $0.screen == screen.index }) { note in
                        noteActions(item: item, note: note, locked: locked)
                    }
                }
                // A malformed or missing screen must not hide a note from review.
                if !orphanNotes.isEmpty {
                    ScreenCard(directory: directory, title: nil, imagePath: nil, notes: orphanNotes) { note in
                        noteActions(item: item, note: note, locked: locked)
                    }
                }
            }
            .padding(UX.contentPadding)
            .frame(maxWidth: UX.maximumContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func batchAction(_ item: ReceiverService.Item) -> some View {
        if item.entry.sendRequested {
            HStack(spacing: UX.headerTextSpacing * 2) {
                ProgressView().controlSize(.small)
                Text(item.error == nil ? "Sending…" : "Waiting to retry").foregroundStyle(.secondary)
            }
        } else {
            Button("Send to T3", systemImage: "paperplane.fill") { model.send(ids: [item.id]) }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Send every note in this batch to T3")
        }
    }

    /// Sending one note moves it into its own delivery; the rest of the batch stays queued.
    private func noteActions(item: ReceiverService.Item, note: Annotation, locked: Bool) -> some View {
        HStack(spacing: UX.noteActionSpacing) {
            Button { model.send(sessionID: item.id, annotationID: note.id) } label: {
                Image(systemName: "paperplane")
            }
            .help(locked ? "This batch is already sending" : "Send only this note to T3")
            .accessibilityLabel("Send note \(note.index) to T3")
            Button { model.trash(sessionID: item.id, annotationID: note.id) } label: {
                Image(systemName: "trash")
            }
            .help(locked ? "Notes can’t be removed while the batch is sending" : "Move this note to Trash")
            .accessibilityLabel("Move note \(note.index) to Trash")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .disabled(locked)
    }

    private func trashDetail(_ item: ReceiverService.TrashItem) -> some View {
        let directory = model.configuration.output.appendingPathComponent("mac-trash/\(item.id)/bundle")
        let orphanNotes = item.session.annotations.filter { note in !item.session.screens.contains { $0.index == note.screen } }
        return ScrollView {
            VStack(alignment: .leading, spacing: UX.sectionSpacing) {
                HStack(alignment: .top, spacing: UX.headerSpacing) {
                    VStack(alignment: .leading, spacing: UX.headerTextSpacing) {
                        Text("In Trash").font(.title2.weight(.semibold))
                        Text("Deleted \(InboxDateFormat.sent(item.entry.deletedAt)) · Removed permanently \(InboxDateFormat.sent(item.entry.expiresAt))")
                            .foregroundStyle(.secondary)
                        Text("Trashed notes are never sent to T3. Restoring returns the note to its original waiting batch, or to a new queued batch with the same destination.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button("Restore", systemImage: "arrow.uturn.backward") { model.restore(trashID: item.id) }
                        .controlSize(.large)
                }
                ForEach(item.session.screens) { screen in
                    ScreenCard(directory: directory, title: "Screen \(screen.index)", imagePath: screen.annotatedImage ?? screen.image,
                        notes: item.session.annotations.filter { $0.screen == screen.index }) { _ in EmptyView() }
                }
                if !orphanNotes.isEmpty {
                    ScreenCard(directory: directory, title: nil, imagePath: nil, notes: orphanNotes) { _ in EmptyView() }
                }
            }
            .padding(UX.contentPadding)
            .frame(maxWidth: UX.maximumContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func batchSubtitle(_ item: ReceiverService.Item) -> String {
        let app = [item.session.app.name, item.session.app.version.map { "v\($0)" }].compactMap { $0 }.joined(separator: " ")
        return [item.noteCount, "Sent \(item.sentAt)", app.isEmpty ? nil : app, item.session.device.model]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func batchDirectory(_ id: String) -> URL { model.configuration.output.appendingPathComponent("sessions/\(id)") }

    private enum UX {
        static let rowSpacing: CGFloat = 2
        static let rowVerticalPadding: CGFloat = 3
        static let headerSpacing: CGFloat = 16
        static let headerTextSpacing: CGFloat = 4
        static let noteActionSpacing: CGFloat = 12
        static let footerPadding: CGFloat = 10
        static let sectionSpacing: CGFloat = 24
        static let contentPadding: CGFloat = 28
        static let bannerVerticalPadding: CGFloat = 10
        static let maximumContentWidth: CGFloat = 860
        static let minimumSidebarWidth: CGFloat = 220
        static let sidebarWidth: CGFloat = 270
        static let minimumDetailWidth: CGFloat = 460
    }
}

/// A queued batch in the sidebar: its destination, then its note count, with the send time trailing.
private struct BatchSidebarRow: View {
    let item: ReceiverService.Item

    var body: some View {
        VStack(alignment: .leading, spacing: UX.spacing) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.title).fontWeight(.medium).lineLimit(1)
                Spacer(minLength: UX.minimumGap)
                Text(item.sentAt).font(.caption).foregroundStyle(.secondary).lineLimit(1).layoutPriority(1)
            }
            HStack(spacing: UX.statusSpacing) {
                if item.error != nil {
                    Image(systemName: "exclamationmark.circle").accessibilityLabel("Waiting to retry")
                } else if item.entry.sendRequested {
                    Image(systemName: "paperplane").accessibilityLabel("Sending")
                }
                Text(item.noteCount).lineLimit(1)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, UX.verticalPadding)
    }

    private enum UX {
        static let spacing: CGFloat = 2
        static let minimumGap: CGFloat = 8
        static let statusSpacing: CGFloat = 4
        static let verticalPadding: CGFloat = 3
    }
}

/// One screen on a single surface: the marked-up screenshot beside its numbered notes, whose
/// numbers match the pins drawn on the screenshot. Stacks vertically when the pane is narrow.
private struct ScreenCard<NoteAction: View>: View {
    let directory: URL
    let title: String?
    let imagePath: String?
    let notes: [Annotation]
    @ViewBuilder let action: (Annotation) -> NoteAction

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, ScreenCardUX.padding).padding(.top, ScreenCardUX.titleTopPadding)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    if imagePath != nil {
                        screenshot.frame(width: ScreenCardUX.screenshotWidth).padding(ScreenCardUX.padding)
                        Divider()
                    }
                    noteList.frame(minWidth: ScreenCardUX.minimumNotesWidth, maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 0) {
                    if imagePath != nil {
                        screenshot.frame(maxWidth: ScreenCardUX.screenshotWidth).padding(ScreenCardUX.padding)
                        Divider()
                    }
                    noteList
                }
            }
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: ScreenCardUX.radius))
        .overlay(RoundedRectangle(cornerRadius: ScreenCardUX.radius).strokeBorder(.separator, lineWidth: ScreenCardUX.hairline))
    }

    @ViewBuilder
    private var screenshot: some View {
        if let imagePath {
            FeedbackImage(directory: directory, relativePath: imagePath, maximumHeight: ScreenCardUX.screenshotHeight)
        }
    }

    private var noteList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(notes.enumerated()), id: \.element.id) { offset, note in
                if offset > 0 { Divider().padding(.leading, ScreenCardUX.dividerInset) }
                NoteRow(note: note, directory: directory, showsCrop: imagePath == nil) { action(note) }
            }
        }
    }
}

/// Generic views cannot hold static constants, so the screen card keeps them here.
private enum ScreenCardUX {
    static let padding: CGFloat = 16
    static let titleTopPadding: CGFloat = 12
    static let screenshotWidth: CGFloat = 220
    static let screenshotHeight: CGFloat = 480
    static let minimumNotesWidth: CGFloat = 280
    static let radius: CGFloat = 12
    static let hairline: CGFloat = 0.5
    /// Aligns note dividers with the note text, past the number badge.
    static let dividerInset: CGFloat = 50
}

/// One note: a number badge matching its pin, the request itself, then quiet metadata.
private struct NoteRow<Action: View>: View {
    let note: Annotation
    let directory: URL
    /// Crops repeat the screenshot's markup, so they are shown only when no screenshot is.
    let showsCrop: Bool
    @ViewBuilder let action: () -> Action

    private var details: String {
        [(note.intent ?? .fix).title, note.element?.label?.nonEmpty].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: NoteRowUX.spacing) {
            Text(note.index, format: .number)
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: NoteRowUX.badgeSize, height: NoteRowUX.badgeSize)
                .background(Color.accentColor, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: NoteRowUX.textSpacing) {
                if let comment = note.comment.nonEmpty {
                    Text(comment).textSelection(.enabled)
                }
                if let edit = note.textEdit {
                    Text("Replace “\(edit.from)” with “\(edit.to)”").textSelection(.enabled)
                }
                if note.comment.nonEmpty == nil && note.textEdit == nil {
                    Text("Visual note").foregroundStyle(.secondary)
                }
                Text(details).font(.callout).foregroundStyle(.secondary)
                if let source = note.source {
                    Text("\(source.file):\(source.line)")
                        .font(.caption.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
                }
                let images = (showsCrop ? [note.crop].compactMap { $0 } : []) + (note.attachments ?? [])
                if !images.isEmpty {
                    HStack(alignment: .top, spacing: NoteRowUX.spacing) {
                        ForEach(images, id: \.self) { path in
                            FeedbackImage(directory: directory, relativePath: path, maximumHeight: NoteRowUX.attachmentHeight)
                                .frame(maxWidth: NoteRowUX.attachmentWidth, alignment: .leading)
                        }
                    }
                    .padding(.top, NoteRowUX.textSpacing)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            action()
        }
        .padding(NoteRowUX.padding)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Note \(note.index)")
    }
}

/// Generic views cannot hold static constants, so the note row keeps them here.
private enum NoteRowUX {
    static let spacing: CGFloat = 12
    static let textSpacing: CGFloat = 4
    static let badgeSize: CGFloat = 22
    static let padding: CGFloat = 16
    static let attachmentWidth: CGFloat = 140
    static let attachmentHeight: CGFloat = 96
}

/// Settings, reached from the sidebar's gear: one card of System Settings–style rows.
private struct InboxSettingsPage: View {
    @ObservedObject var model: InboxModel
    @ObservedObject var menuBarExtra: MenuBarExtraController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UX.sectionSpacing) {
                Text("Settings").font(.largeTitle.weight(.semibold))
                VStack(spacing: 0) {
                    SettingsRow(symbol: "antenna.radiowaves.left.and.right", color: .blue, title: "Listener",
                        detail: model.listenerEnabled ? "Receiving annotations from your phone and simulators." : "Not receiving. Queued batches can still be reviewed and sent.",
                        isOn: Binding(get: { model.listenerEnabled }, set: model.setListener))
                        .disabled(model.changingListener || model.role == .starting)
                    Divider().padding(.leading, UX.dividerInset)
                    SettingsRow(symbol: "paperplane.fill", color: .green, title: "Auto-Send New Batches",
                        detail: "Send new arrivals to T3. Batches already waiting stay queued.",
                        isOn: Binding(get: { model.automaticallySend }, set: model.setAutomaticallySend))
                        .disabled(model.role == .starting)
                    if menuBarExtra.isAvailable {
                        Divider().padding(.leading, UX.dividerInset)
                        SettingsRow(symbol: "menubar.rectangle", color: .gray, title: "Show in Menu Bar",
                            detail: "When on, opening Annotate Inbox starts in the menu bar. When off, it opens this window.",
                            isOn: Binding(get: { menuBarExtra.isShown }, set: menuBarExtra.setShown))
                            .disabled(menuBarExtra.isChanging)
                    }
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: UX.radius))
                .overlay(RoundedRectangle(cornerRadius: UX.radius).strokeBorder(.separator, lineWidth: UX.hairline))

                if let error = menuBarExtra.error {
                    Text(error).font(.callout).foregroundStyle(.red)
                }

                HStack {
                    Text("Annotations are stored privately in this project’s .annotate folder.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.open(model.configuration.output) }
                        .buttonStyle(.link)
                }
            }
            .padding(UX.padding)
            .frame(maxWidth: UX.maximumWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private enum UX {
        static let sectionSpacing: CGFloat = 20
        static let padding: CGFloat = 36
        static let maximumWidth: CGFloat = 600
        static let radius: CGFloat = 12
        static let hairline: CGFloat = 0.5
        /// Aligns row dividers with the row text, past the icon tile.
        static let dividerInset: CGFloat = 58
    }
}

/// An icon tile, a title with a one-line explanation, and a switch.
private struct SettingsRow: View {
    let symbol: String
    let color: Color
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: UX.spacing) {
                Image(systemName: symbol)
                    .font(.system(size: UX.symbolSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: UX.tileSize, height: UX.tileSize)
                    .background(color.gradient, in: RoundedRectangle(cornerRadius: UX.tileRadius))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: UX.textSpacing) {
                    Text(title)
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .toggleStyle(.switch)
        .padding(.horizontal, UX.horizontalPadding).padding(.vertical, UX.verticalPadding)
        .accessibilityHint(detail)
    }

    private enum UX {
        static let spacing: CGFloat = 12
        static let textSpacing: CGFloat = 2
        static let tileSize: CGFloat = 30
        static let tileRadius: CGFloat = 7
        static let symbolSize: CGFloat = 14
        static let horizontalPadding: CGFloat = 16
        static let verticalPadding: CGFloat = 12
    }
}

/// Loads only validated local bundle images off the main thread. Double-clicking opens the full file in
/// the default viewer, so the window never needs a zoomed copy.
private struct FeedbackImage: View {
    let directory: URL
    let relativePath: String
    let maximumHeight: CGFloat
    @State private var image: NSImage?
    @State private var file: URL?
    @State private var finished = false

    var body: some View {
        Group {
            if let image {
                // Double-click, like a Finder thumbnail, so a stray click never opens a viewer.
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(maxHeight: maximumHeight, alignment: .topLeading)
                    .clipShape(RoundedRectangle(cornerRadius: UX.radius))
                    .overlay(RoundedRectangle(cornerRadius: UX.radius).strokeBorder(.separator, lineWidth: UX.hairline))
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2, perform: openFullSize)
                    .help("Double-click to open full size")
                    .accessibilityElement()
                    .accessibilityLabel("Annotation image")
                    .accessibilityAddTraits(.isImage)
                    .accessibilityAction(named: "Open Full Size", openFullSize)
            } else if finished {
                Label("Image unavailable", systemImage: "photo").foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: directory.appendingPathComponent(relativePath)) {
            let directory = directory
            let path = relativePath
            let loaded = await Task.detached(priority: .utility) { () -> (Data, URL)? in
                guard SessionInbox.isSafeRelativePath(path) else { return nil }
                let file = directory.appendingPathComponent(path).resolvingSymlinksInPath()
                guard file.path.hasPrefix(directory.resolvingSymlinksInPath().path + "/"),
                      let data = try? Data(contentsOf: file) else { return nil }
                return (data, file)
            }.value
            guard !Task.isCancelled else { return }
            image = loaded.flatMap { NSImage(data: $0.0) }
            file = loaded?.1
            finished = true
        }
    }

    private func openFullSize() { if let file { NSWorkspace.shared.open(file) } }

    private enum UX {
        static let radius: CGFloat = 8
        static let hairline: CGFloat = 0.5
    }
}

private extension String {
    var nonEmpty: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
#endif
