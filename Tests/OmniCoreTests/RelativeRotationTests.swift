import XCTest
@testable import OmniCore

final class RelativeRotationTests: XCTestCase {
    func testAllTwelveDirectionMappingsForStationaryPanelImage() throws {
        let expected = [[90,270,180],[180,0,270],[270,90,0],[0,180,90]]
        for (i,start) in [0.0,90,180,270].enumerated() {
            for (j,action) in RelativeRotation.allCases.enumerated() { XCTAssertEqual(try action.target(from:start),expected[i][j]) }
        }
    }
    func testFourSameDirectionTurnsReturnEveryStart() throws {
        for start in [0.0,90,180,270] { for action in [RelativeRotation.clockwise,.counterclockwise] {
            var angle=start
            for _ in 0..<4 { angle=Double(try action.target(from:angle)) }
            XCTAssertEqual(angle,start)
        } }
    }
    func testOppositeTurnsAndTwoFlipsCancel() throws {
        for start in [0.0,90,180,270] {
            XCTAssertEqual(try RelativeRotation.counterclockwise.target(from:Double(RelativeRotation.clockwise.target(from:start))),Int(start))
            XCTAssertEqual(try RelativeRotation.clockwise.target(from:Double(RelativeRotation.counterclockwise.target(from:start))),Int(start))
            XCTAssertEqual(try RelativeRotation.flip.target(from:Double(RelativeRotation.flip.target(from:start))),Int(start))
        }
    }
    func testInvalidOrIntermediateAngleNeverDefaultsToZero() {
        for angle in [Double.nan,.infinity,-90,45,360] { XCTAssertThrowsError(try RelativeRotation.clockwise.target(from:angle)) }
    }
    func testEachClickReadsExternalChangesAndPlansFromNewOrientation() throws {
        let target=Display.samples(1)[0].id
        var live=Snapshot(boot:"simulation",displays:Display.samples(1));var reads=0
        func read() -> Snapshot { reads += 1;return live }
        let first=try RelativeRotation.clockwise.prepare(target:target,baseline:nil,simulation:true,read:read)
        XCTAssertEqual(first.rotationDegrees,270)
        live.displays=try RotationPlan.layout(live.displays,target:target,degrees:270) // external system edit
        let second=try RelativeRotation.clockwise.prepare(target:target,baseline:nil,simulation:true,read:read)
        XCTAssertEqual(second.before.displays[0].rotation,270);XCTAssertEqual(second.rotationDegrees,180);XCTAssertEqual(reads,2)
    }
    func testFreshReadFailureNeverBuildsRequestFromCache() {
        XCTAssertThrowsError(try RelativeRotation.flip.prepare(target:Display.samples(1)[0].id,baseline:nil,simulation:true,read:{throw ObservationNotSettled()}))
    }
    func testConfirmationRejectsChangedAngleTopologyIdentityOrBoot() throws {
        let snapshot=Snapshot(boot:"simulation",displays:Display.samples(2))
        let request=try RelativeRotation.flip.prepare(target:snapshot.displays[1].id,baseline:nil,simulation:true,read:{snapshot})
        XCTAssertNoThrow(try RelativeRotation.validateConfirmation(request,current:snapshot))
        var changed=snapshot;changed.displays[1].rotation=90;XCTAssertThrowsError(try RelativeRotation.validateConfirmation(request,current:changed))
        changed=snapshot;changed.boot="other";XCTAssertThrowsError(try RelativeRotation.validateConfirmation(request,current:changed))
        changed=snapshot;changed.displays[1].serial+=1;XCTAssertThrowsError(try RelativeRotation.validateConfirmation(request,current:changed))
        changed=snapshot;changed.displays[0].x=20;XCTAssertThrowsError(try RelativeRotation.validateConfirmation(request,current:changed))
    }
    func testDirectionMatrixMatchesInversePhysicalPanelRotation() throws {
        // On a fixed panel with y down, image-up (0,-1) turns right for CW.
        // CG angle compensates physical panel rotation, hence image uses -delta.
        for action in [RelativeRotation.clockwise,.counterclockwise] {
            let cg=Double(try action.target(from:0)) * .pi/180
            let imageX = -sin(cg)
            XCTAssertEqual(imageX,action == .clockwise ? 1 : -1,accuracy:0.00001)
        }
    }
}
