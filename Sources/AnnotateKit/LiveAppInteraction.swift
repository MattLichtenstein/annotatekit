#if DEBUG && canImport(UIKit)
#if canImport(AnnotateCore)
import AnnotateCore
#endif
import UIKit

/// Observes taps in the host window while leaving real pan gestures with the app's own recognizers.
@MainActor
final class LiveAppInteraction {
    private var recognizers: [LiveAnnotationTapRecognizer] = []

    func attach(to windows: [UIWindow], select: @escaping (CGPoint, PointerIntent) -> Void) {
        detach()
        for window in windows {
            let recognizer = LiveAnnotationTapRecognizer(select: select)
            // Delay/cancel view touches so tapping a row selects a pin instead of activating its button.
            // Gesture recognizers still see the original touch stream, including native scroll pans.
            recognizer.delaysTouchesBegan = true
            recognizer.delaysTouchesEnded = true
            recognizer.cancelsTouchesInView = true
            window.addGestureRecognizer(recognizer)
            recognizers.append(recognizer)
        }
    }

    func detach() {
        for recognizer in recognizers { recognizer.view?.removeGestureRecognizer(recognizer) }
        recognizers.removeAll()
    }
}

/// A discrete tap/hold recognizer that fails as soon as a drag belongs to the underlying app.
private final class LiveAnnotationTapRecognizer: UIGestureRecognizer {
    private let select: (CGPoint, PointerIntent) -> Void
    private var start: CGPoint?
    private var beganAt: TimeInterval = 0
    private var hold: Task<Void, Never>?
    private var recognizedIntent: PointerIntent = .tap

    init(select: @escaping (CGPoint, PointerIntent) -> Void) {
        self.select = select
        super.init(target: nil, action: nil)
        addTarget(self, action: #selector(recognized))
        name = "AnnotateKit.LiveSelection"
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard start == nil, touches.count == 1, let touch = touches.first else {
            state = .failed
            return
        }
        start = touch.location(in: nil)
        beganAt = touch.timestamp
        hold = Task { [weak self] in
            try? await Task.sleep(for: .seconds(PointerIntent.holdDuration))
            guard let self, !Task.isCancelled, self.state == .possible else { return }
            self.recognizedIntent = .hold
            self.state = .recognized
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let start, let touch = touches.first else { return }
        let point = touch.location(in: nil)
        let distance = Double(hypot(point.x - start.x, point.y - start.y))
        if distance > PointerIntent.moveThreshold {
            hold?.cancel()
            state = .failed
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        hold?.cancel()
        guard state == .possible, let start, let touch = touches.first else { return }
        let point = touch.location(in: nil)
        let distance = Double(hypot(point.x - start.x, point.y - start.y))
        let intent = PointerIntent.classify(distance: distance, duration: touch.timestamp - beganAt, isEnded: true)
        guard intent != .draw else { state = .failed; return }
        recognizedIntent = intent ?? .tap
        state = .recognized
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        hold?.cancel()
        state = .failed
    }

    override func reset() {
        hold?.cancel()
        hold = nil
        start = nil
        recognizedIntent = .tap
        super.reset()
    }

    // Host taps must not win over annotation selection. Native pans remain free to recognize.
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        !(preventedGestureRecognizer is UIPanGestureRecognizer)
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        preventingGestureRecognizer is UIPanGestureRecognizer
    }

    @objc private func recognized() {
        guard let start else { return }
        select(start, recognizedIntent)
    }
}
#endif
