#if canImport(UIKit)
import SwiftUI
import UIKit

/// Vamp Stream's multi-touch surface uses the same semantics as Vamp Control:
/// one-finger pan moves the pointer, long press toggles drag-lock, two-finger pan scrolls,
/// two-finger tap right-clicks, and three-finger tap middle-clicks.
struct AppStreamGestureView: UIViewRepresentable {
    var viewportZoom: CGFloat = 1
    var viewportOffset: CGSize = .zero
    var viewSize: CGSize = .zero
    var onTap: (CGPoint) -> Void
    var onDoubleTap: (CGPoint) -> Void
    var onRightClick: (CGPoint) -> Void
    var onMiddleClick: (CGPoint) -> Void
    var onPointerMove: (CGPoint) -> Void
    var onPointerEnded: () -> Void
    var onScroll: (Double, Double) -> Void
    var onViewportPan: (CGSize) -> Void = { _ in }
    var onPinchChanged: (CGFloat, CGPoint) -> Void = { _, _ in }
    var onPinchEnded: () -> Void = {}
    var onLongPress: (CGPoint) -> Void
    var onHoverDelta: (Double, Double) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true
        view.isMultipleTouchEnabled = true
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        context.coordinator.install(on: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.viewportZoom = viewportZoom
        context.coordinator.viewportOffset = viewportOffset
        context.coordinator.viewSize = viewSize
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.remove(from: uiView)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: AppStreamGestureView

        var viewportZoom: CGFloat = 1
        var viewportOffset: CGSize = .zero
        var viewSize: CGSize = .zero

        private var lastPointerTranslation: CGPoint = .zero
        private var lastViewportTranslation: CGPoint = .zero
        private var twoFingerPansViewport = false
        private var scrollVelocity: CGSize = .zero
        private var momentumLink: CADisplayLink?
        private weak var pinchRecognizer: UIPinchGestureRecognizer?
        private var lastHoverLocation: CGPoint?

        init(_ parent: AppStreamGestureView) {
            self.parent = parent
        }

        func install(on view: UIView) {
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(onDoubleTap(_:)))
            doubleTap.numberOfTapsRequired = 2
            doubleTap.numberOfTouchesRequired = 1

            let singleTap = UITapGestureRecognizer(target: self, action: #selector(onSingleTap(_:)))
            singleTap.numberOfTapsRequired = 1
            singleTap.numberOfTouchesRequired = 1
            singleTap.require(toFail: doubleTap)

            let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(onTwoFingerTap(_:)))
            twoFingerTap.numberOfTouchesRequired = 2

            let threeFingerTap = UITapGestureRecognizer(target: self, action: #selector(onThreeFingerTap(_:)))
            threeFingerTap.numberOfTouchesRequired = 3

            let pointerPan = UIPanGestureRecognizer(target: self, action: #selector(onPointerPan(_:)))
            pointerPan.minimumNumberOfTouches = 1
            pointerPan.maximumNumberOfTouches = 1

            let twoFingerPan = UIPanGestureRecognizer(target: self, action: #selector(onTwoFingerPan(_:)))
            twoFingerPan.minimumNumberOfTouches = 2
            twoFingerPan.maximumNumberOfTouches = 2

            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinch(_:)))
            pinch.delegate = self
            pinchRecognizer = pinch

            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(onLongPress(_:)))
            longPress.minimumPressDuration = 0.5
            longPress.numberOfTouchesRequired = 1

            let hover = UIHoverGestureRecognizer(target: self, action: #selector(onHover(_:)))

            [singleTap, doubleTap, twoFingerTap, threeFingerTap, pointerPan, twoFingerPan, pinch, longPress, hover]
                .forEach {
                    $0.cancelsTouchesInView = false
                    $0.delegate = self
                    view.addGestureRecognizer($0)
                }
        }

        func remove(from view: UIView) {
            momentumLink?.invalidate()
            momentumLink = nil
            for recognizer in view.gestureRecognizers ?? [] {
                recognizer.delegate = nil
                view.removeGestureRecognizer(recognizer)
            }
        }

        @objc private func onSingleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            cancelMomentum()
            parent.onTap(adjustedPoint(recognizer.location(in: view)))
        }

        @objc private func onDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            parent.onDoubleTap(adjustedPoint(recognizer.location(in: view)))
        }

        @objc private func onTwoFingerTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            parent.onRightClick(adjustedPoint(recognizer.location(in: view)))
        }

        @objc private func onThreeFingerTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            parent.onMiddleClick(adjustedPoint(recognizer.location(in: view)))
        }

        @objc private func onPointerPan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            switch recognizer.state {
            case .began:
                // Do not press on every swipe. Vamp Control reserves mouse-down for drag-lock.
                cancelMomentum()
                lastPointerTranslation = .zero
            case .changed:
                let translation = recognizer.translation(in: view)
                let dx = translation.x - lastPointerTranslation.x
                let dy = translation.y - lastPointerTranslation.y
                lastPointerTranslation = CGPoint(x: translation.x, y: translation.y)
                guard dx != 0 || dy != 0 else { return }
                parent.onPointerMove(adjustedPoint(recognizer.location(in: view)))
            case .ended, .cancelled, .failed:
                lastPointerTranslation = .zero
                parent.onPointerEnded()
            default:
                break
            }
        }

        @objc private func onTwoFingerPan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            switch recognizer.state {
            case .began:
                cancelMomentum()
                lastViewportTranslation = .zero
                scrollVelocity = .zero
                // A two-finger gesture is remote scrolling at 1×. Once the user has
                // zoomed in, the same gesture pans the local viewport instead.
                twoFingerPansViewport = viewportZoom > 1.05 || isPinching
            case .changed:
                let translation = recognizer.translation(in: view)
                let dx = translation.x - lastViewportTranslation.x
                let dy = translation.y - lastViewportTranslation.y
                lastViewportTranslation = translation
                if isPinching { twoFingerPansViewport = true }
                if twoFingerPansViewport {
                    parent.onViewportPan(CGSize(width: dx, height: dy))
                } else {
                    let scrollX = Double(-dx)
                    let scrollY = Double(dy)
                    parent.onScroll(scrollX, scrollY)
                    scrollVelocity = CGSize(width: scrollX, height: scrollY)
                }
            case .ended:
                lastViewportTranslation = .zero
                if !twoFingerPansViewport { startMomentum() }
            case .cancelled, .failed:
                lastViewportTranslation = .zero
            default:
                break
            }
        }

        @objc private func onPinch(_ recognizer: UIPinchGestureRecognizer) {
            switch recognizer.state {
            case .began:
                cancelMomentum()
                twoFingerPansViewport = true
            case .changed:
                guard let view = recognizer.view else { return }
                parent.onPinchChanged(recognizer.scale, recognizer.location(in: view))
                // Send incremental scale values to the SwiftUI state machine.
                recognizer.scale = 1
            case .ended, .cancelled, .failed:
                parent.onPinchEnded()
            default:
                break
            }
        }

        @objc private func onLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began, let view = recognizer.view else { return }
            parent.onLongPress(adjustedPoint(recognizer.location(in: view)))
        }

        @objc private func onHover(_ recognizer: UIHoverGestureRecognizer) {
            let location = recognizer.location(in: recognizer.view)
            switch recognizer.state {
            case .began:
                lastHoverLocation = location
            case .changed:
                guard let last = lastHoverLocation else {
                    lastHoverLocation = location
                    return
                }
                let dx = location.x - last.x
                let dy = location.y - last.y
                lastHoverLocation = location
                if dx != 0 || dy != 0 {
                    parent.onHoverDelta(Double(dx), Double(dy))
                }
            case .ended, .cancelled, .failed:
                lastHoverLocation = nil
            default:
                break
            }
        }

        private func adjustedPoint(_ point: CGPoint) -> CGPoint {
            guard viewportZoom != 1 || viewportOffset != .zero else { return point }
            let centerX = viewSize.width / 2
            let centerY = viewSize.height / 2
            return CGPoint(
                x: centerX + (point.x - centerX - viewportOffset.width) / viewportZoom,
                y: centerY + (point.y - centerY - viewportOffset.height) / viewportZoom
            )
        }

        private func startMomentum() {
            let speed = hypot(scrollVelocity.width, scrollVelocity.height)
            guard speed > 1.5 else { return }
            momentumLink?.invalidate()
            let link = CADisplayLink(target: self, selector: #selector(momentumTick))
            link.add(to: .main, forMode: .common)
            momentumLink = link
        }

        private func cancelMomentum() {
            momentumLink?.invalidate()
            momentumLink = nil
            scrollVelocity = .zero
        }

        @objc private func momentumTick() {
            parent.onScroll(Double(scrollVelocity.width), Double(scrollVelocity.height))
            scrollVelocity = CGSize(width: scrollVelocity.width * 0.92, height: scrollVelocity.height * 0.92)
            if hypot(scrollVelocity.width, scrollVelocity.height) < 0.4 {
                cancelMomentum()
            }
        }

        private var isPinching: Bool {
            guard let pinchRecognizer else { return false }
            return pinchRecognizer.state == .began || pinchRecognizer.state == .changed
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            if gestureRecognizer is UIHoverGestureRecognizer || other is UIHoverGestureRecognizer {
                return true
            }
            let isPinch = gestureRecognizer is UIPinchGestureRecognizer
            let otherIsPinch = other is UIPinchGestureRecognizer
            let isTwoFingerPan = (gestureRecognizer as? UIPanGestureRecognizer)?.minimumNumberOfTouches == 2
            let otherIsTwoFingerPan = (other as? UIPanGestureRecognizer)?.minimumNumberOfTouches == 2
            if (isPinch && otherIsTwoFingerPan) || (otherIsPinch && isTwoFingerPan) {
                return true
            }
            // Long-press must be allowed alongside the one-finger pan so it can toggle
            // the explicit drag-lock instead of being cancelled when the pan activates.
            if gestureRecognizer is UILongPressGestureRecognizer || other is UILongPressGestureRecognizer {
                return true
            }
            if gestureRecognizer is UIPanGestureRecognizer && other is UIPanGestureRecognizer {
                return false
            }
            return false
        }
    }
}
#endif
