import Foundation

/// Transient drag routing; saved annotations and the versioned session format never carry this state.
public enum OverlayDragMode: Equatable, Sendable {
    case draw
    case scroll

    public var toggled: Self { self == .draw ? .scroll : .draw }

    /// A capture's coordinates stay fixed while a note, reply, sheet, or new selection owns the screen.
    public func allowsAppScrolling(
        isActive: Bool,
        hasOpenCard: Bool,
        showsNotes: Bool,
        isPreparingSelection: Bool
    ) -> Bool {
        self == .scroll && isActive && !hasOpenCard && !showsNotes && !isPreparingSelection
    }
}
