import Testing
@testable import AnnotateCore

/// Ensures live movement cannot invalidate the frozen coordinates of a draft or in-flight selection.
@Suite struct OverlayDragModeTests {
    @Test("Scroll mode passes app movement only during active, unobstructed review")
    func scrollsOnlyWhileReviewing() {
        #expect(OverlayDragMode.scroll.allowsAppScrolling(
            isActive: true, hasOpenCard: false, showsNotes: false, isPreparingSelection: false
        ))
        #expect(!OverlayDragMode.draw.allowsAppScrolling(
            isActive: true, hasOpenCard: false, showsNotes: false, isPreparingSelection: false
        ))
    }

    @Test("Inactive sessions, open notes and unfinished selections never expose live app movement",
          arguments: [
              (false, false, false, false),
              (true, true, false, false),
              (true, false, true, false),
              (true, false, false, true),
              (true, true, true, true)
          ])
    func capturesStayFixed(active: Bool, card: Bool, notes: Bool, preparing: Bool) {
        #expect(!OverlayDragMode.scroll.allowsAppScrolling(
            isActive: active, hasOpenCard: card, showsNotes: notes, isPreparingSelection: preparing
        ))
    }

    @Test("Mode switching is reversible and contains no persisted session semantics")
    func togglesBackToOriginal() {
        #expect(OverlayDragMode.draw.toggled == .scroll)
        #expect(OverlayDragMode.scroll.toggled == .draw)
        #expect(OverlayDragMode.draw.toggled.toggled == .draw)
    }
}
