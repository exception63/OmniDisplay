import XCTest
@testable import OmniDisplay

final class ConfirmationPlacementTests: XCTestCase {
    func testAnchorsToOriginalActiveMainEvenWhenMouseScreenDiffers() {
        XCTAssertEqual(ConfirmationPlacement.screenIndex(ids: ["target", "primary", "peer"], preferred: ["primary", "peer"], mainID: "target"), 1)
    }
    func testMissingMainFallsBackToRetainedThenCurrentMain() {
        XCTAssertEqual(ConfirmationPlacement.screenIndex(ids: ["peer", "newMain"], preferred: ["oldMain", "peer"], mainID: "newMain"), 0)
        XCTAssertEqual(ConfirmationPlacement.screenIndex(ids: ["peer", "newMain"], preferred: ["oldMain", "gone"], mainID: "newMain"), 1)
        XCTAssertNil(ConfirmationPlacement.screenIndex(ids: [], preferred: ["oldMain"], mainID: "newMain"))
    }
    func testNegativeOriginsPortraitAndSmallDisplaysStayInsideVisibleFrame() {
        for visible in [CGRect(x: 0, y: 25, width: 1920, height: 1030), CGRect(x: -1080, y: -461, width: 1080, height: 1890), CGRect(x: 3000, y: -104, width: 480, height: 300)] {
            let frame = ConfirmationPlacement.frame(size: CGSize(width: 540, height: 342), visible: visible)
            XCTAssertTrue(visible.contains(frame))
            XCTAssertEqual(frame.midX, visible.midX)
            XCTAssertEqual(frame.midY, visible.midY)
        }
    }
}
