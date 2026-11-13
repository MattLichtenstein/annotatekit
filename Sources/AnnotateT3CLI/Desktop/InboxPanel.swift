#if os(macOS)
import AnnotateCore
import SwiftUI

/// The menu bar extra's compact panel: receiver switches, the queue with Send All, and app actions.
/// Send All sits with the queue it sends; Trash and the other app actions stay apart in the footer.
struct InboxPanel: View {
    @ObservedObject var model: InboxModel
    /// Opens the window app at a destination, or nil when no window app is packaged alongside.
    let open: ((InboxDestination) -> Void)?
    let quit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, UX.horizontalPadding).padding(.vertical, UX.messagePadding)
                Divider()
            }
            queue
            Divider()
            footer
        }
        .frame(width: UX.width)
    }

    private var controls: some View {
        VStack(spacing: UX.controlSpacing) {
            switchRow("Listener",
                isOn: Binding(get: { model.listenerEnabled }, set: model.setListener))
                .disabled(model.changingListener || model.role == .starting)
            switchRow("Auto-Send New Batches",
                isOn: Binding(get: { model.automaticallySend }, set: model.setAutomaticallySend))
                .disabled(model.role == .starting)
        }
        .padding(.horizontal, UX.horizontalPadding).padding(.vertical, UX.controlsVerticalPadding)
    }

    private func switchRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch).controlSize(.small)
    }

    @ViewBuilder
    private var queue: some View {
        let items = model.queuedItems
        HStack {
            Text("Queue").font(.subheadline.weight(.semibold))
            if !items.isEmpty {
                Text(items.count, format: .number).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.send(ids: model.sendableItems.map(\.id)) } label: {
                FormationPaperplaneIcon()
            }
            .buttonStyle(PanelIconButtonStyle())
            .disabled(model.sendableItems.isEmpty)
            .help("Send All to T3")
            .accessibilityLabel("Send All to T3")
        }
        .padding(.horizontal, UX.horizontalPadding).padding(.top, UX.queueHeaderTopPadding)
        if items.isEmpty {
            Text("No queued annotations")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, UX.emptyPadding)
        } else {
            let rows = VStack(spacing: 0) {
                ForEach(items) { item in
                    InboxBatchRow(item: item,
                        open: open.map { open in { open(.batch(item.id)) } },
                        send: { model.send(ids: [item.id]) },
                        trash: { model.trash(batch: item) })
                }
            }
            .padding(UX.listInset)
            if items.count > UX.maximumVisibleRows {
                ScrollView { rows }.frame(height: UX.scrollHeight)
            } else {
                rows
            }
        }
    }

    /// Menu-style action rows, one per line, so Trash is never beside a send control.
    private var footer: some View {
        VStack(spacing: 0) {
            if let open {
                Button("Show Inbox", systemImage: "macwindow") { open(.inbox) }
                Button("Show Trash", systemImage: "trash") { open(.trash) }
            }
            Button("Quit Annotate Inbox", systemImage: "power", action: quit)
        }
        .buttonStyle(PanelMenuRowStyle())
        .padding(UX.listInset)
    }

    private enum UX {
        static let width: CGFloat = 320
        static let horizontalPadding: CGFloat = 14
        static let controlSpacing: CGFloat = 10
        static let controlsVerticalPadding: CGFloat = 12
        static let messagePadding: CGFloat = 8
        static let queueHeaderTopPadding: CGFloat = 10
        static let emptyPadding: CGFloat = 16
        static let listInset: CGFloat = 6
        static let maximumVisibleRows = 6
        static let scrollHeight: CGFloat = 264
    }
}

/// One queued batch: its first note and details, a send control, and a menu-style hover.
private struct InboxBatchRow: View {
    let item: ReceiverService.Item
    let open: (() -> Void)?
    let send: () -> Void
    let trash: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: UX.spacing) {
            Button { open?() } label: {
                VStack(alignment: .leading, spacing: UX.textSpacing) {
                    Text(item.title).lineLimit(1)
                    Text("\(item.noteCount) · \(item.sentAt)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(open == nil)
            .help(open == nil ? "" : "Open in Annotate Inbox")
            .accessibilityLabel("\(item.title). \(item.noteCount), sent \(item.sentAt).")
            .accessibilityHint(open == nil ? "" : "Opens the batch in Annotate Inbox.")

            status
        }
        .padding(.horizontal, UX.rowHorizontalPadding).padding(.vertical, UX.rowVerticalPadding)
        .background(isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: UX.rowRadius))
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var status: some View {
        if item.error != nil {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
                .help("Waiting to retry delivery")
                .accessibilityLabel("Waiting to retry delivery")
        } else if item.entry.sendRequested {
            ProgressView().controlSize(.small)
                .help("Sending to T3")
                .accessibilityLabel("Sending to T3")
        } else {
            HStack(spacing: UX.actionSpacing) {
                Button(action: send) { Image(systemName: "paperplane") }
                    .help("Send to T3")
                    .accessibilityLabel("Send \(item.title) batch to T3")
                Button(action: trash) { Image(systemName: "trash") }
                    .help("Move this batch's notes to Trash")
                    .accessibilityLabel("Move \(item.title) batch to Trash")
            }
            .buttonStyle(PanelIconButtonStyle())
        }
    }

    private enum UX {
        static let spacing: CGFloat = 8
        static let actionSpacing: CGFloat = 2
        static let textSpacing: CGFloat = 1
        static let rowHorizontalPadding: CGFloat = 8
        static let rowVerticalPadding: CGFloat = 6
        static let rowRadius: CGFloat = 6
    }
}
/// A full-width, menu-like action row with a hover highlight.
private struct PanelMenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PanelMenuRow(configuration: configuration)
    }

    private struct PanelMenuRow: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .labelStyle(PanelMenuLabelStyle())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, PanelMenuRowUX.horizontalPadding).padding(.vertical, PanelMenuRowUX.verticalPadding)
                .background(isHovered && isEnabled ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: PanelMenuRowUX.radius))
                .opacity(configuration.isPressed ? PanelMenuRowUX.pressedOpacity : 1)
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
        }
    }

    private struct PanelMenuLabelStyle: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: PanelMenuRowUX.iconSpacing) {
                configuration.icon.foregroundStyle(.secondary).frame(width: PanelMenuRowUX.iconWidth)
                configuration.title
            }
        }
    }
}

private enum PanelMenuRowUX {
    static let horizontalPadding: CGFloat = 8
    static let verticalPadding: CGFloat = 5
    static let radius: CGFloat = 6
    static let iconSpacing: CGFloat = 8
    static let iconWidth: CGFloat = 16
    static let pressedOpacity = 0.6
}
/// Three small paper planes flying in formation toward the top right, for sending every batch.
/// SF Symbols has no multiple paper plane, so this arranges `paperplane.fill`; it scales with text.
struct FormationPaperplaneIcon: View {
    @ScaledMetric(relativeTo: .body) private var unit: CGFloat = 1

    var body: some View {
        ZStack {
            ForEach(Array(FormationPaperplaneUX.formation.enumerated()), id: \.offset) { _, plane in
                Image(systemName: "paperplane.fill")
                    .font(.system(size: FormationPaperplaneUX.planeSize * unit, weight: .semibold))
                    .opacity(plane.opacity)
                    .offset(x: plane.x * unit, y: plane.y * unit)
            }
        }
        .frame(width: FormationPaperplaneUX.width * unit, height: FormationPaperplaneUX.height * unit)
        .accessibilityHidden(true)
    }
}

private enum FormationPaperplaneUX {
    static let planeSize: CGFloat = 7.5
    static let width: CGFloat = 20
    static let height: CGFloat = 19
    /// A V formation heading toward the top right, matching the symbol's direction: the lead
    /// plane in front, two wingmen behind on either side, slightly faded for motion.
    static let formation: [(x: CGFloat, y: CGFloat, opacity: Double)] = [
        (x: -5, y: -2, opacity: 0.6),
        (x: 2.5, y: 5.5, opacity: 0.6),
        (x: 4, y: -3.5, opacity: 1),
    ]
}
/// An icon-only control with a hover highlight, so every icon in the panel shows it is clickable.
struct PanelIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PanelIconButton(configuration: configuration)
    }

    private struct PanelIconButton: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .foregroundStyle(isEnabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                .frame(minWidth: PanelIconButtonUX.size, minHeight: PanelIconButtonUX.size)
                .background(isHovered && isEnabled ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: PanelIconButtonUX.radius))
                .opacity(configuration.isPressed ? PanelIconButtonUX.pressedOpacity : 1)
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
        }
    }
}

private enum PanelIconButtonUX {
    static let size: CGFloat = 24
    static let radius: CGFloat = 6
    static let pressedOpacity = 0.6
}
#endif
