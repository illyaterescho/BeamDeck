#if os(iOS)
import CoreMotion
import SwiftUI
import UIKit

/// Turns the phone into a pointer: rotation rate from the gyroscope becomes cursor motion.
/// Yaw is taken around the real vertical (gravity), so it works however the phone is held.
@MainActor
final class AirMouse {
    private let motion = CMMotionManager()

    var available: Bool { motion.isDeviceMotionAvailable }

    /// `speed` is the touchpad speed setting (1…5). Updates arrive at 60 Hz on the main queue.
    func start(speed: Double, onMove: @escaping (CGSize) -> Void) {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 60
        let gain = 600.0 * speed / 60 // pixels per radian, per tick
        motion.startDeviceMotionUpdates(to: .main) { data, _ in
            guard let data else { return }
            let rate = data.rotationRate
            let gravity = data.gravity
            let yaw = rate.x * gravity.x + rate.y * gravity.y + rate.z * gravity.z
            let pitch = rate.x
            // Dead zone removes hand tremor; a gentle curve keeps slow aiming precise and fast sweeps quick.
            func shape(_ value: Double) -> Double {
                let magnitude = abs(value)
                guard magnitude > 0.035 else { return 0 }
                return (value < 0 ? -1 : 1) * (magnitude - 0.035) * (1 + min(magnitude, 3) * 0.6)
            }
            onMove(CGSize(width: shape(yaw) * gain, height: -shape(pitch) * gain))
        }
    }

    func stop() {
        if motion.isDeviceMotionActive { motion.stopDeviceMotionUpdates() }
    }
}

/// A trackpad surface with real multi-touch: one finger moves, two fingers scroll,
/// tap clicks, two-finger tap right-clicks, press-and-hold then move drags.
struct TrackpadSurface: UIViewRepresentable {
    var onMove: (CGSize) -> Void
    var onScroll: (CGFloat, CGFloat) -> Void
    var onTap: () -> Void
    var onSecondaryTap: () -> Void
    var onDragStart: () -> Void
    var onDragEnd: () -> Void
    var dragEnabled: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        let c = context.coordinator

        let hold = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.hold(_:)))
        hold.minimumPressDuration = 0.45
        hold.allowableMovement = 10
        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.require(toFail: hold)
        let scroll = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.scroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tap))
        let secondary = UITapGestureRecognizer(target: c, action: #selector(Coordinator.secondaryTap))
        secondary.numberOfTouchesRequired = 2

        [hold, pan, scroll, tap, secondary].forEach(view.addGestureRecognizer)
        c.holdGesture = hold
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.holdGesture?.isEnabled = dragEnabled
    }

    final class Coordinator: NSObject {
        var parent: TrackpadSurface
        weak var holdGesture: UILongPressGestureRecognizer?
        private var lastHold: CGPoint = .zero
        private var scrollRest: CGPoint = .zero

        init(_ parent: TrackpadSurface) { self.parent = parent }

        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            let delta = gesture.translation(in: gesture.view)
            gesture.setTranslation(.zero, in: gesture.view)
            if delta != .zero { parent.onMove(CGSize(width: delta.x, height: delta.y)) }
        }

        @objc func scroll(_ gesture: UIPanGestureRecognizer) {
            if gesture.state == .began { scrollRest = .zero }
            let delta = gesture.translation(in: gesture.view)
            gesture.setTranslation(.zero, in: gesture.view)
            scrollRest.x += delta.x
            scrollRest.y += delta.y
            // Send in small steps so the projector scrolls smoothly instead of jumping.
            if abs(scrollRest.y) >= 12 || abs(scrollRest.x) >= 12 {
                parent.onScroll(abs(scrollRest.x) >= 12 ? scrollRest.x : 0, abs(scrollRest.y) >= 12 ? scrollRest.y : 0)
                scrollRest = .zero
            }
        }

        @objc func hold(_ gesture: UILongPressGestureRecognizer) {
            let point = gesture.location(in: gesture.view)
            switch gesture.state {
            case .began:
                lastHold = point
                parent.onDragStart()
            case .changed:
                parent.onMove(CGSize(width: point.x - lastHold.x, height: point.y - lastHold.y))
                lastHold = point
            case .ended, .cancelled, .failed:
                parent.onDragEnd()
            default: break
            }
        }

        @objc func tap() { parent.onTap() }
        @objc func secondaryTap() { parent.onSecondaryTap() }
    }
}
#endif
