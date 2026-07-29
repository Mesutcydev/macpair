import XCTest
@testable import SharedModels
@testable import SharedUtilities

final class ViewportCoordinateMapperTests: XCTestCase {

    // MARK: - Helpers

    private func makeDisplay(
        id: String = "main",
        width: Double = 1920,
        height: Double = 1080,
        originX: Double = 0,
        originY: Double = 0,
        scale: Double = 2.0,
        rotation: Double = 0
    ) -> DisplayDescriptor {
        DisplayDescriptor(
            id: id,
            name: "Display \(id)",
            frame: DesktopRect(
                origin: DesktopPoint(x: originX, y: originY),
                size: DesktopSize(width: width, height: height)
            ),
            pixelSize: DesktopSize(width: width * scale, height: height * scale),
            scaleFactor: scale,
            rotation: rotation,
            isPrimary: true
        )
    }

    private func makeMapper(
        displayWidth: Double = 1920,
        displayHeight: Double = 1080,
        viewWidth: Double = 390,
        viewHeight: Double = 844,
        mode: ViewportCoordinateMapper.InteractionMode = .absolute
    ) -> ViewportCoordinateMapper {
        ViewportCoordinateMapper(
            display: makeDisplay(width: displayWidth, height: displayHeight),
            viewSize: DesktopSize(width: viewWidth, height: viewHeight),
            interactionMode: mode
        )
    }

    // MARK: - Fitted Content Rect / Letterboxing

    func testFittedContentRectWiderDisplayThanView() {
        // 1920×1080 display (16:9) in a 390×844 view (≈0.46:1) → pillarbox
        let mapper = makeMapper()
        let fitted = mapper.fittedContentRect

        // Width should fill the view
        XCTAssertEqual(fitted.size.width, 390, accuracy: 0.01)
        // Height = 390 / (1920/1080) = 390 / 1.778 ≈ 219.375
        let expectedHeight = 390.0 / (1920.0 / 1080.0)
        XCTAssertEqual(fitted.size.height, expectedHeight, accuracy: 0.01)
        // Centered vertically
        let expectedOriginY = (844.0 - expectedHeight) / 2.0
        XCTAssertEqual(fitted.origin.y, expectedOriginY, accuracy: 0.01)
        XCTAssertEqual(fitted.origin.x, 0, accuracy: 0.01)
    }

    func testFittedContentRectTallerDisplayThanView() {
        // 1080×1920 display (9:16) in a 390×844 view
        // Display aspect = 1080/1920 = 0.5625
        // View aspect = 390/844 ≈ 0.4621
        // displayAspect > viewAspect → pillarbox (width fills, bars top/bottom)
        let mapper = makeMapper(displayWidth: 1080, displayHeight: 1920)
        let fitted = mapper.fittedContentRect

        // Width fills the view
        XCTAssertEqual(fitted.size.width, 390, accuracy: 0.01)
        // Height = 390 / (1080/1920) = 390 / 0.5625 = 693.33
        let expectedHeight = 390.0 / (1080.0 / 1920.0)
        XCTAssertEqual(fitted.size.height, expectedHeight, accuracy: 0.01)
        // Centered vertically
        XCTAssertEqual(fitted.origin.x, 0, accuracy: 0.01)
        let expectedOriginY = (844.0 - expectedHeight) / 2.0
        XCTAssertEqual(fitted.origin.y, expectedOriginY, accuracy: 0.01)
    }

    func testFittedContentRectMatchingAspectRatio() {
        // Same aspect ratio → no letterboxing
        let mapper = makeMapper(displayWidth: 1920, displayHeight: 1080, viewWidth: 1920, viewHeight: 1080)
        let fitted = mapper.fittedContentRect

        XCTAssertEqual(fitted.origin.x, 0, accuracy: 0.01)
        XCTAssertEqual(fitted.origin.y, 0, accuracy: 0.01)
        XCTAssertEqual(fitted.size.width, 1920, accuracy: 0.01)
        XCTAssertEqual(fitted.size.height, 1080, accuracy: 0.01)
    }

    func testFittedContentRectSquareViewWithWideDisplay() {
        // 1920×1080 display in 400×400 view → pillarbox
        let mapper = makeMapper(displayWidth: 1920, displayHeight: 1080, viewWidth: 400, viewHeight: 400)
        let fitted = mapper.fittedContentRect

        XCTAssertEqual(fitted.size.width, 400, accuracy: 0.01)
        let expectedHeight = 400.0 / (1920.0 / 1080.0)
        XCTAssertEqual(fitted.size.height, expectedHeight, accuracy: 0.01)
    }

    func testFittedContentRectLetterbox() {
        // 1024×768 display (4:3, aspect=1.333) in 1024×600 view (aspect=1.707)
        // displayAspect < viewAspect → letterbox (black bars left/right)
        let mapper = makeMapper(displayWidth: 1024, displayHeight: 768, viewWidth: 1024, viewHeight: 600)
        let fitted = mapper.fittedContentRect

        // Height fills the view
        XCTAssertEqual(fitted.size.height, 600, accuracy: 0.01)
        // Width = 600 * (1024/768) = 800
        let expectedWidth = 600.0 * (1024.0 / 768.0)
        XCTAssertEqual(fitted.size.width, expectedWidth, accuracy: 0.01)
        // Centered horizontally
        let expectedOriginX = (1024.0 - expectedWidth) / 2.0
        XCTAssertEqual(fitted.origin.x, expectedOriginX, accuracy: 0.01)
        XCTAssertEqual(fitted.origin.y, 0, accuracy: 0.01)
    }

    // MARK: - View → Display-Local Mapping

    func testViewToDisplayLocalCenter() {
        let mapper = makeMapper()
        let fitted = mapper.fittedContentRect
        let center = DesktopPoint(
            x: fitted.origin.x + fitted.size.width / 2,
            y: fitted.origin.y + fitted.size.height / 2
        )

        let result = mapper.viewToDisplayLocal(center)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.x, 960, accuracy: 0.5) // half of 1920
        XCTAssertEqual(result!.y, 540, accuracy: 0.5) // half of 1080
    }

    func testViewToDisplayLocalTopLeft() {
        let mapper = makeMapper()
        let fitted = mapper.fittedContentRect
        let topLeft = DesktopPoint(x: fitted.origin.x, y: fitted.origin.y)

        let result = mapper.viewToDisplayLocal(topLeft)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.x, 0, accuracy: 0.01)
        XCTAssertEqual(result!.y, 0, accuracy: 0.01)
    }

    func testViewToDisplayLocalBottomRight() {
        let mapper = makeMapper()
        let fitted = mapper.fittedContentRect
        let bottomRight = DesktopPoint(
            x: fitted.origin.x + fitted.size.width,
            y: fitted.origin.y + fitted.size.height
        )

        let result = mapper.viewToDisplayLocal(bottomRight)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.x, 1920, accuracy: 0.5)
        XCTAssertEqual(result!.y, 1080, accuracy: 0.5)
    }

    func testFillScreenMapsVisibleViewportIntoCroppedStream() {
        let mapper = ViewportCoordinateMapper(
            display: makeDisplay(width: 1920, height: 1080),
            viewSize: DesktopSize(width: 390, height: 844),
            displayMode: .fillScreen
        )

        let leftEdge = mapper.viewToDisplayLocal(DesktopPoint(x: 0, y: 422))
        let rightEdge = mapper.viewToDisplayLocal(DesktopPoint(x: 390, y: 422))

        XCTAssertNotNil(leftEdge)
        XCTAssertNotNil(rightEdge)
        XCTAssertGreaterThan(leftEdge!.x, 0)
        XCTAssertLessThan(rightEdge!.x, 1920)
    }

    func testQuarterTurnRotatedStreamMapsTopLeftIntoRotatedLogicalCorner() {
        let display = makeDisplay(width: 1920, height: 1080, rotation: 90)
        let streamConfiguration = DisplayStreamConfiguration(
            display: display,
            streamWidth: 1080,
            streamHeight: 1920
        )
        let mapper = ViewportCoordinateMapper(
            display: display,
            streamConfiguration: streamConfiguration,
            viewSize: DesktopSize(width: 390, height: 844)
        )
        let fitted = mapper.fittedContentRect

        let mapped = mapper.viewToDisplayLocal(DesktopPoint(x: fitted.minX, y: fitted.minY))
        XCTAssertNotNil(mapped)
        XCTAssertEqual(mapped!.x, 0, accuracy: 0.5)
        XCTAssertEqual(mapped!.y, 1080, accuracy: 0.5)
    }

    func testQuarterTurnRotatedStreamRoundTripsDisplayLocalPoint() {
        let display = makeDisplay(width: 1920, height: 1080, rotation: 90)
        let streamConfiguration = DisplayStreamConfiguration(
            display: display,
            streamWidth: 1080,
            streamHeight: 1920
        )
        let mapper = ViewportCoordinateMapper(
            display: display,
            streamConfiguration: streamConfiguration,
            viewSize: DesktopSize(width: 390, height: 844)
        )
        let original = DesktopPoint(x: 480, y: 810)

        let viewPoint = mapper.displayLocalToView(original)
        XCTAssertNotNil(viewPoint)
        let roundTripped = mapper.viewToDisplayLocal(viewPoint!)
        XCTAssertNotNil(roundTripped)
        XCTAssertEqual(roundTripped!.x, original.x, accuracy: 0.5)
        XCTAssertEqual(roundTripped!.y, original.y, accuracy: 0.5)
    }

    func testViewToDisplayLocalInLetterboxReturnsNil() {
        let mapper = makeMapper()
        // Touch in the pillarbox area (above the fitted rect)
        let result = mapper.viewToDisplayLocal(DesktopPoint(x: 195, y: 0))
        XCTAssertNil(result)
    }

    func testViewToDisplayLocalBelowContentReturnsNil() {
        let mapper = makeMapper()
        // Touch below the fitted rect
        _ = mapper.viewToDisplayLocal(DesktopPoint(x: 195, y: 843))
        // 843 may or may not be in the content area, let's check with a definitely-outside point
        _ = mapper.viewToDisplayLocal(DesktopPoint(x: 195, y: 844))
        // At least one should be nil depending on exact geometry
        // The fitted rect Y extends from about 312 to 532 for 1920×1080 in 390×844
        let fitted = mapper.fittedContentRect
        let outsidePoint = DesktopPoint(x: 195, y: fitted.origin.y + fitted.size.height + 10)
        XCTAssertNil(mapper.viewToDisplayLocal(outsidePoint))
    }

    // MARK: - Round-Trip Mapping

    func testRoundTripViewToDisplayAndBack() {
        let mapper = makeMapper()
        let fitted = mapper.fittedContentRect
        let original = DesktopPoint(
            x: fitted.origin.x + fitted.size.width * 0.3,
            y: fitted.origin.y + fitted.size.height * 0.7
        )

        let displayLocal = mapper.viewToDisplayLocal(original)
        XCTAssertNotNil(displayLocal)
        let backToView = mapper.displayLocalToView(displayLocal!)
        XCTAssertNotNil(backToView)
        XCTAssertEqual(backToView!.x, original.x, accuracy: 0.01)
        XCTAssertEqual(backToView!.y, original.y, accuracy: 0.01)
    }

    // MARK: - Relative Delta Mapping

    func testViewDeltaToDisplayDelta() {
        let mapper = makeMapper()
        let fitted = mapper.fittedContentRect

        let delta = mapper.viewDeltaToDisplayDelta(dx: 10, dy: 5)
        let expectedScaleX = 1920.0 / fitted.size.width
        let expectedScaleY = 1080.0 / fitted.size.height

        XCTAssertEqual(delta.x, 10 * expectedScaleX, accuracy: 0.01)
        XCTAssertEqual(delta.y, 5 * expectedScaleY, accuracy: 0.01)
    }

    func testViewDeltaToDisplayDeltaZeroIsZero() {
        let mapper = makeMapper()
        let delta = mapper.viewDeltaToDisplayDelta(dx: 0, dy: 0)
        XCTAssertEqual(delta.x, 0, accuracy: 0.001)
        XCTAssertEqual(delta.y, 0, accuracy: 0.001)
    }

    // MARK: - Hit Testing

    func testIsInsideContentForContentArea() {
        let mapper = makeMapper()
        let fitted = mapper.fittedContentRect
        let center = DesktopPoint(
            x: fitted.origin.x + fitted.size.width / 2,
            y: fitted.origin.y + fitted.size.height / 2
        )
        XCTAssertTrue(mapper.isInsideContent(center))
    }

    func testIsInsideContentForLetterboxArea() {
        let mapper = makeMapper()
        // Top-left corner of view — definitely in the pillarbox
        XCTAssertFalse(mapper.isInsideContent(DesktopPoint(x: 0, y: 0)))
    }

    // MARK: - Edge Cases

    func testZeroViewSizeReturnsFallback() {
        let mapper = makeMapper(viewWidth: 0, viewHeight: 0)
        let result = mapper.viewToDisplayLocal(DesktopPoint(x: 0, y: 0))
        XCTAssertNil(result)
    }

    func testDisplayLocalToViewZeroDisplayReturnsNil() {
        let mapper = ViewportCoordinateMapper(
            display: makeDisplay(width: 0, height: 0),
            viewSize: DesktopSize(width: 390, height: 844)
        )
        let result = mapper.displayLocalToView(DesktopPoint(x: 0, y: 0))
        XCTAssertNil(result)
    }
}

// MARK: - Gesture Interpreter Tests

final class GestureInterpreterTests: XCTestCase {

    private func makeDisplay(
        id: String = "main",
        width: Double = 1920,
        height: Double = 1080
    ) -> DisplayDescriptor {
        DisplayDescriptor(
            id: id,
            name: "Display \(id)",
            frame: DesktopRect(
                origin: DesktopPoint(x: 0, y: 0),
                size: DesktopSize(width: width, height: height)
            ),
            pixelSize: DesktopSize(width: width * 2, height: height * 2),
            scaleFactor: 2,
            isPrimary: true
        )
    }

    private func makeInterpreter(
        mode: ViewportCoordinateMapper.InteractionMode = .absolute
    ) -> GestureInterpreter {
        let mapper = ViewportCoordinateMapper(
            display: makeDisplay(),
            viewSize: DesktopSize(width: 390, height: 844),
            interactionMode: mode
        )
        return GestureInterpreter(displayID: "main", mapper: mapper)
    }

    // Touch point inside the fitted content
    private func contentCenter(for interpreter: GestureInterpreter) -> DesktopPoint {
        let fitted = interpreter.mapper.fittedContentRect
        return DesktopPoint(
            x: fitted.origin.x + fitted.size.width / 2,
            y: fitted.origin.y + fitted.size.height / 2
        )
    }

    // MARK: - Tap → Left Click (Absolute)

    func testTapAbsoluteProducesLeftClick() {
        let interpreter = makeInterpreter(mode: .absolute)
        let point = contentCenter(for: interpreter)
        let result = interpreter.tap(at: point)

        XCTAssertNotNil(result)
        if case .pointerButton(let cmd) = result {
            XCTAssertEqual(cmd.button, .left)
            XCTAssertEqual(cmd.action, .click)
            XCTAssertNotNil(cmd.location)
            XCTAssertEqual(cmd.displayID, "main")
        } else {
            XCTFail("Expected pointerButton command")
        }
    }

    func testTapAbsoluteInLetterboxReturnsNil() {
        let interpreter = makeInterpreter(mode: .absolute)
        let result = interpreter.tap(at: DesktopPoint(x: 0, y: 0))
        XCTAssertNil(result)
    }

    // MARK: - Tap → Left Click (Relative)

    func testTapRelativeProducesLeftClickNoLocation() {
        let interpreter = makeInterpreter(mode: .relative)
        let result = interpreter.tap(at: DesktopPoint(x: 100, y: 100))

        XCTAssertNotNil(result)
        if case .pointerButton(let cmd) = result {
            XCTAssertEqual(cmd.button, .left)
            XCTAssertEqual(cmd.action, .click)
            XCTAssertNil(cmd.location)
        } else {
            XCTFail("Expected pointerButton command")
        }
    }

    // MARK: - Double Tap → Double Click

    func testDoubleTapProducesDoubleClick() {
        let interpreter = makeInterpreter(mode: .absolute)
        let point = contentCenter(for: interpreter)
        let result = interpreter.doubleTap(at: point)

        XCTAssertNotNil(result)
        if case .pointerButton(let cmd) = result {
            XCTAssertEqual(cmd.button, .left)
            XCTAssertEqual(cmd.action, .doubleClick)
            XCTAssertNotNil(cmd.location)
            XCTAssertEqual(cmd.displayID, "main")
        } else {
            XCTFail("Expected pointerButton command")
        }
    }

    // MARK: - Two-Finger Tap → Right Click

    func testTwoFingerTapProducesRightClick() {
        let interpreter = makeInterpreter(mode: .absolute)
        let point = contentCenter(for: interpreter)
        let result = interpreter.twoFingerTap(at: point)

        XCTAssertNotNil(result)
        if case .pointerButton(let cmd) = result {
            XCTAssertEqual(cmd.button, .right)
            XCTAssertEqual(cmd.action, .click)
            XCTAssertEqual(cmd.displayID, "main")
        } else {
            XCTFail("Expected pointerButton command")
        }
    }

    // MARK: - Drag → Pointer Move (Absolute)

    func testDragAbsoluteProducesAbsoluteMove() {
        let interpreter = makeInterpreter(mode: .absolute)
        let point = contentCenter(for: interpreter)
        let result = interpreter.drag(
            translation: DesktopPoint(x: 5, y: 3),
            currentViewPoint: point
        )

        if case .pointerMove(let cmd) = result {
            XCTAssertTrue(cmd.isAbsolute)
            XCTAssertEqual(cmd.displayID, "main")
        } else {
            XCTFail("Expected pointerMove command")
        }
    }

    // MARK: - Drag → Pointer Move (Relative)

    func testDragRelativeProducesRelativeMove() {
        let interpreter = makeInterpreter(mode: .relative)
        let result = interpreter.drag(
            translation: DesktopPoint(x: 10, y: 5),
            currentViewPoint: DesktopPoint(x: 200, y: 400)
        )

        if case .pointerMove(let cmd) = result {
            XCTAssertFalse(cmd.isAbsolute)
            XCTAssertEqual(cmd.displayID, "main")
            // Delta should be scaled
            XCTAssertGreaterThan(cmd.location.x, 0)
        } else {
            XCTFail("Expected pointerMove command")
        }
    }

    // MARK: - Scroll

    func testScrollProducesScrollCommand() {
        let interpreter = makeInterpreter()
        let result = interpreter.scroll(deltaX: 0, deltaY: -10)

        if case .scroll(let cmd) = result {
            XCTAssertTrue(cmd.isPrecise)
            XCTAssertEqual(cmd.deltaX, 0, accuracy: 0.001)
            XCTAssertLessThan(cmd.deltaY, 0) // negative scroll
        } else {
            XCTFail("Expected scroll command")
        }
    }

    // MARK: - Drag Lock

    func testDragLockBeginProducesMouseDown() {
        let interpreter = makeInterpreter(mode: .absolute)
        let point = contentCenter(for: interpreter)
        let result = interpreter.dragLockBegin(at: point)

        XCTAssertNotNil(result)
        if case .pointerButton(let cmd) = result {
            XCTAssertEqual(cmd.button, .left)
            XCTAssertEqual(cmd.action, .down)
            XCTAssertEqual(cmd.displayID, "main")
        } else {
            XCTFail("Expected pointerButton command")
        }
    }

    func testDragLockEndProducesMouseUp() {
        let interpreter = makeInterpreter(mode: .absolute)
        let point = contentCenter(for: interpreter)
        let result = interpreter.dragLockEnd(at: point)

        XCTAssertNotNil(result)
        if case .pointerButton(let cmd) = result {
            XCTAssertEqual(cmd.button, .left)
            XCTAssertEqual(cmd.action, .up)
            XCTAssertEqual(cmd.displayID, "main")
        } else {
            XCTFail("Expected pointerButton command")
        }
    }

    // MARK: - Text & Key

    func testTextInputProducesTextCommand() {
        let interpreter = makeInterpreter()
        let result = interpreter.textInput("hello")

        if case .text(let cmd) = result {
            XCTAssertEqual(cmd.text, "hello")
        } else {
            XCTFail("Expected text command")
        }
    }

    func testKeyPressProducesKeyCommand() {
        let interpreter = makeInterpreter()
        let result = interpreter.keyPress(keyCode: 36, action: .down, modifiers: .command)

        if case .key(let cmd) = result {
            XCTAssertEqual(cmd.keyCode, 36)
            XCTAssertEqual(cmd.action, .down)
            XCTAssertTrue(cmd.modifiers.contains(.command))
        } else {
            XCTFail("Expected key command")
        }
    }

    // MARK: - Coordinate Accuracy with Letterboxing

    func testAbsoluteTapMapsToCorrectDisplayCoordinatesWithPillarbox() {
        // 1920×1080 display in 390×844 view → pillarbox (bars top/bottom)
        let interpreter = makeInterpreter(mode: .absolute)
        let fitted = interpreter.mapper.fittedContentRect

        // Tap at 25% from left, 50% from top of content area
        let viewPoint = DesktopPoint(
            x: fitted.origin.x + fitted.size.width * 0.25,
            y: fitted.origin.y + fitted.size.height * 0.5
        )
        let result = interpreter.tap(at: viewPoint)

        XCTAssertNotNil(result)
        if case .pointerButton(let cmd) = result {
            XCTAssertEqual(cmd.location!.x, 480, accuracy: 1) // 25% of 1920
            XCTAssertEqual(cmd.location!.y, 540, accuracy: 1) // 50% of 1080
        } else {
            XCTFail("Expected pointerButton command")
        }
    }

    func testAbsoluteTapMapsToCorrectDisplayCoordinatesWithLetterbox() {
        // 1080×1920 display in 390×844 view → letterbox (bars left/right)
        let display = DisplayDescriptor(
            id: "tall",
            name: "Tall Display",
            frame: DesktopRect(
                origin: .zero,
                size: DesktopSize(width: 1080, height: 1920)
            ),
            pixelSize: DesktopSize(width: 2160, height: 3840),
            scaleFactor: 2,
            isPrimary: true
        )
        let mapper = ViewportCoordinateMapper(
            display: display,
            viewSize: DesktopSize(width: 390, height: 844),
            interactionMode: .absolute
        )
        let interpreter = GestureInterpreter(displayID: "tall", mapper: mapper)

        let fitted = mapper.fittedContentRect
        // Tap at center of content
        let viewPoint = DesktopPoint(
            x: fitted.origin.x + fitted.size.width * 0.5,
            y: fitted.origin.y + fitted.size.height * 0.5
        )
        let result = interpreter.tap(at: viewPoint)

        XCTAssertNotNil(result)
        if case .pointerButton(let cmd) = result {
            XCTAssertEqual(cmd.location!.x, 540, accuracy: 1) // 50% of 1080
            XCTAssertEqual(cmd.location!.y, 960, accuracy: 1) // 50% of 1920
        } else {
            XCTFail("Expected pointerButton command")
        }
    }
}
