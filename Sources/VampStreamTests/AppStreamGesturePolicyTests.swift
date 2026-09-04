import XCTest
import UIKit
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
}
