import XCTest
import UIKit
@testable import Vamp_Stream

/// Only a live stream rotates — the connect screen and app pickers are portrait designs. Opening a
/// stream also *suggests* the orientation matching the Mac window; a suggestion for a near-square
/// window would fight the user for no benefit.
final class VampStreamOrientationTests: XCTestCase {

    func testOnlyAStreamMayRotate() {
        XCTAssertEqual(StreamOrientation.supportedOrientations(isStreaming: false), .portrait)
        let streaming = StreamOrientation.supportedOrientations(isStreaming: true)
        XCTAssertTrue(streaming.contains(.landscapeLeft))
        XCTAssertTrue(streaming.contains(.landscapeRight))
        XCTAssertTrue(streaming.contains(.portrait))
        XCTAssertFalse(streaming.contains(.portraitUpsideDown))
    }

    func testWideWindowSuggestsLandscape() {
        XCTAssertEqual(StreamOrientation.preferredOrientation(aspect: 16.0 / 9.0), .landscapeRight)
        XCTAssertEqual(StreamOrientation.preferredOrientation(aspect: 1.09), .landscapeRight)
    }

    func testTallWindowSuggestsPortrait() {
        XCTAssertEqual(StreamOrientation.preferredOrientation(aspect: 9.0 / 19.5), .portrait)
        XCTAssertEqual(StreamOrientation.preferredOrientation(aspect: 0.92), .portrait)
    }

    func testNearSquareAndInvalidAspectsSuggestNothing() {
        XCTAssertNil(StreamOrientation.preferredOrientation(aspect: 1))
        XCTAssertNil(StreamOrientation.preferredOrientation(aspect: 0.95))
        XCTAssertNil(StreamOrientation.preferredOrientation(aspect: 1.05))
        // A collapsed window can report 0 or NaN.
        XCTAssertNil(StreamOrientation.preferredOrientation(aspect: 0))
        XCTAssertNil(StreamOrientation.preferredOrientation(aspect: .nan))
    }
}
