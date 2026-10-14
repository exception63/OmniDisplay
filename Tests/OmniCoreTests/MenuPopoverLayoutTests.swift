import XCTest
@testable import OmniCore

final class MenuPopoverLayoutTests: XCTestCase {
    func testAnchorChoosesItsOwnScreenIncludingNegativeOrigins() {
        let frames = [CGRect(x:0,y:0,width:1920,height:1080),
                      CGRect(x:-1080,y:-379,width:1080,height:1920),
                      CGRect(x:1920,y:-305,width:1080,height:1920)]
        for (index, frame) in frames.enumerated() {
            for x in [frame.minX+2, frame.maxX-34] {
                let anchor = CGRect(x:x,y:frame.maxY-30,width:32,height:24)
                XCTAssertEqual(MenuPopoverLayout.screenIndex(anchor:anchor,frames:frames),index)
            }
        }
        XCTAssertNil(MenuPopoverLayout.screenIndex(anchor:.zero,frames:frames))
        XCTAssertNil(MenuPopoverLayout.screenIndex(anchor:CGRect(x:9000,y:0,width:30,height:30),frames:frames))
    }
    func testContentFitsBelowAnchorOnShortAndPortraitScreens() throws {
        for frame in [CGRect(x:0,y:0,width:1920,height:1080), CGRect(x:-1080,y:-379,width:1080,height:1920), CGRect(x:3000,y:500,width:800,height:360)] {
            let anchor=CGRect(x:frame.maxX-46,y:frame.maxY-30,width:30,height:30)
            let visible=CGRect(x:frame.minX,y:frame.minY+40,width:frame.width,height:frame.height-70)
            for count in [1,2,4,8,24,100] {
                let size=try XCTUnwrap(MenuPopoverLayout.contentSize(anchor:anchor,visibleFrame:visible,displayCount:count))
                XCTAssertLessThanOrEqual(size.height+32,anchor.minY-visible.minY)
                XCTAssertLessThanOrEqual(size.width+32,visible.width)
                XCTAssertLessThanOrEqual(size.height,480)
            }
        }
    }
    func testScreenTranslationDoesNotChangeMenuSize() {
        let a=CGRect(x:1800,y:1050,width:30,height:30), v=CGRect(x:0,y:40,width:1920,height:1010)
        XCTAssertEqual(MenuPopoverLayout.contentSize(anchor:a,visibleFrame:v,displayCount:4),
                       MenuPopoverLayout.contentSize(anchor:a.offsetBy(dx:-4000,dy:-1500),visibleFrame:v.offsetBy(dx:-4000,dy:-1500),displayCount:4))
    }
    func testNoSpaceFailsInsteadOfOverflowing() {
        XCTAssertNil(MenuPopoverLayout.contentSize(anchor:CGRect(x:10,y:80,width:30,height:30),visibleFrame:CGRect(x:0,y:0,width:400,height:100),displayCount:4))
    }
}
