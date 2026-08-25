import CoreGraphics
import SharedModels
import SharedUtilities
import XCTest

final class SessionControlBarLayoutTests: XCTestCase {
    func testBottomInsetAddsDockOverlapAndComfortMargins() {
        let visible = CGRect(x: 0, y: 78, width: 1440, height: 922)
        let window = CGRect(x: 100, y: 0, width: 1200, height: 900)

        let inset = SessionControlBarLayout.bottomInset(
            windowFrame: window,
            visibleFrame: visible
        )

        XCTAssertEqual(inset, SessionControlBarMetrics.comfortInset + 78 + SessionControlBarMetrics.dockGap)
    }

    func testBottomInsetIsZeroOverlapWhenWindowSitsAboveDock() {
        let visible = CGRect(x: 0, y: 78, width: 1440, height: 922)
        let window = CGRect(x: 100, y: 120, width: 1200, height: 800)

        let inset = SessionControlBarLayout.bottomInset(
            windowFrame: window,
            visibleFrame: visible
        )

        XCTAssertEqual(inset, SessionControlBarMetrics.comfortInset + SessionControlBarMetrics.dockGap)
    }

    func testLayoutModeSelection() {
        XCTAssertEqual(SessionControlBarLayout.layoutMode(availableWidth: 900), .wide)
        XCTAssertEqual(SessionControlBarLayout.layoutMode(availableWidth: 520), .compact)
        XCTAssertEqual(SessionControlBarLayout.layoutMode(availableWidth: 360), .iconOnly)
    }

    func testChromeExclusionHeightIncludesExpandedContent() {
        let collapsed = SessionControlBarLayout.chromeExclusionHeight(
            bottomInset: 26,
            isExpanded: false,
            expandedContentHeight: 120
        )
        XCTAssertEqual(collapsed, 26 + SessionControlBarMetrics.pillHeight)

        let expanded = SessionControlBarLayout.chromeExclusionHeight(
            bottomInset: 26,
            isExpanded: true,
            expandedContentHeight: 120
        )
        XCTAssertEqual(
            expanded,
            26 + SessionControlBarMetrics.pillHeight + 120 + SessionControlBarMetrics.expandedSectionSpacing
        )
    }

    func testDisplayModeMenuExposesFitDisplayAsFirstClassOption() {
        let titles = DisplayMappingEngine.DisplayMode.allCases.map(\.title)
        XCTAssertTrue(titles.contains("Fit Display"))
        XCTAssertTrue(titles.contains("Fill Screen"))
        XCTAssertTrue(titles.contains("Actual Size"))
        XCTAssertEqual(DisplayMappingEngine.DisplayMode.fitDisplay.title, "Fit Display")
    }

    func testControlPrimaryClickTranslatesToSecondaryClick() {
        XCTAssertEqual(RemotePrimaryClickTranslation.button(controlPressed: false), MouseButton.left)
        XCTAssertEqual(RemotePrimaryClickTranslation.button(controlPressed: true), MouseButton.right)
    }
}
