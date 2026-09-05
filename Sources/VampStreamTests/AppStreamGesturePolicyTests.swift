import XCTest
import UIKit
import SharedModels
@testable import Vamp_Stream

@MainActor
final class AppStreamGesturePolicyTests: XCTestCase {
    private func coordinator(adjusting: Bool) -> AppStreamGestureView.Coordinator {
        let view = AppStreamGestureView(
            allowsViewportAdjustment: adjusting,
            onTap: { _ in }, onDoubleTap: { _ in }, onRightClick: { _ in },
            onMiddleClick: { _ in }, onPointerMove: { _ in }, onPointerEnded: {},
            onScroll: { _, _ in }, onLongPress: { _ in }, onHoverDelta: { _, _ in })
        return view.makeCoordinator()
    }

    func testControlModeRejectsPinchButAllowsScrollingAtAnyZoom() {
        let sut = coordinator(adjusting: false)
        sut.viewportZoom = 3
        let scroll = UIPanGestureRecognizer()
        scroll.minimumNumberOfTouches = 2
        XCTAssertFalse(sut.gestureRecognizerShouldBegin(UIPinchGestureRecognizer()))
        XCTAssertTrue(sut.gestureRecognizerShouldBegin(scroll))
        XCTAssertTrue(sut.gestureRecognizerShouldBegin(UITapGestureRecognizer()))
    }

    func testAdjustmentModeAllowsPinchAndPanWithoutRemoteClicks() {
        let sut = coordinator(adjusting: true)
        let pan = UIPanGestureRecognizer()
        pan.minimumNumberOfTouches = 2
        XCTAssertTrue(sut.gestureRecognizerShouldBegin(UIPinchGestureRecognizer()))
        XCTAssertTrue(sut.gestureRecognizerShouldBegin(pan))
        XCTAssertFalse(sut.gestureRecognizerShouldBegin(UITapGestureRecognizer()))
        XCTAssertFalse(sut.gestureRecognizerShouldBegin(UILongPressGestureRecognizer()))
        XCTAssertFalse(sut.gestureRecognizerShouldBegin(UIPanGestureRecognizer()))
    }
    func testInputSuspensionReleasesDragAndRejectsNewDrag() {
        let environment = ClientAppEnvironment.makeDefault(clientName: "Input suspension test")
        let input = AppStreamInputController(webRTC: environment.webRTCSessionManager)
        let descriptor = DisplayDescriptor(id: "42", name: "Window",
            frame: DesktopRect(origin: .zero, size: DesktopSize(width: 800, height: 600)),
            pixelSize: DesktopSize(width: 1600, height: 1200), scaleFactor: 2,
            isPrimary: true, isActive: true)
        input.setWindow(descriptor)
        input.setViewSize(DesktopSize(width: 400, height: 600))
        input.toggleDragLock(at: DesktopPoint(x: 200, y: 300))
        XCTAssertFalse(input.dragLocked)
        input.isEnabled = true
        input.toggleDragLock(at: DesktopPoint(x: 200, y: 300))
        XCTAssertTrue(input.dragLocked)
        input.isEnabled = false
        XCTAssertFalse(input.dragLocked)
        input.toggleDragLock(at: DesktopPoint(x: 200, y: 300))
        XCTAssertFalse(input.dragLocked)
        XCTAssertEqual(input.commandsSent, 0, "No attachment means no commands leave the controller")
    }

    func testAdaptiveOrientationAllowsDeviceRotation() {
        StreamOrientation.set(aspect: 0.5, adaptive: true)
        XCTAssertEqual(VampStreamAppDelegate.orientationMask, .allButUpsideDown)
        StreamOrientation.set(aspect: 2, adaptive: true)
        XCTAssertEqual(VampStreamAppDelegate.orientationMask, .allButUpsideDown)
        StreamOrientation.set(aspect: nil)
        XCTAssertEqual(VampStreamAppDelegate.orientationMask, .portrait)
    }

}
