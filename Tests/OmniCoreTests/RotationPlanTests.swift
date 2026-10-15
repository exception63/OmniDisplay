import XCTest
@testable import OmniCore

final class RotationPlanTests: XCTestCase {
    func request(_ screens: [Display] = Display.samples(4), target: Int = 1, degrees: Int = 90) -> Request {
        let snapshot=Snapshot(boot:"simulation",displays:screens)
        var r=Request(operation:.rotate,before:snapshot,office:snapshot,keep:screens[0].id,confirmedPhysical:true,simulation:true,target:screens[target].id)
        r.rotationDegrees=degrees;return r
    }
    func testQuarterTurnReflowsRowWithoutOverlapAndKeepsPrimaryOrder() throws {
        let r=request(), plan=try RotationPlan.make(r)
        XCTAssertEqual(plan.steps.count,1);XCTAssertEqual(plan.steps[0].action,.arrange)
        XCTAssertEqual(plan.desired[1].width,1080);XCTAssertEqual(plan.desired[1].height,1920)
        XCTAssertEqual(plan.desired[1].pixelWidth,2160);XCTAssertEqual(plan.desired[2].x,3000)
        XCTAssertTrue(TemporaryLayout.validArrangement(plan.desired));XCTAssertEqual(plan.desired[0],r.before.displays[0])
        XCTAssertTrue(plan.desired.allSatisfy(\.active))
    }
    func testPrimaryRotationAnchorsZeroAndPreservesOtherAngles() throws {
        let r=request(target:0,degrees:270), plan=try RotationPlan.make(r)
        XCTAssertEqual(plan.desired[0].x,0);XCTAssertEqual(plan.desired[0].y,0);XCTAssertTrue(plan.desired[0].main)
        XCTAssertEqual(plan.desired[1].x,1080);XCTAssertEqual(plan.desired[1].rotation,0)
    }
    func testHalfTurnDoesNotMovePeersAndSameAngleIsNoOp() throws {
        let r=request(degrees:180), plan=try RotationPlan.make(r)
        XCTAssertEqual(plan.desired[2],r.before.displays[2]);XCTAssertEqual(plan.desired[1].width,1920)
        XCTAssertTrue(try RotationPlan.make(request(degrees:0)).steps.isEmpty)
    }
    func testSingleScreenAndVerticalStack() throws {
        let single=try RotationPlan.make(request(Display.samples(1),target:0))
        XCTAssertTrue(TemporaryLayout.validArrangement(single.desired));XCTAssertEqual(single.desired.count,1)
        var stack=Display.samples(3)
        for i in stack.indices { stack[i].x=0;stack[i].y=Int32(i*1080) }
        let rotated=try RotationPlan.make(request(stack)).desired
        XCTAssertTrue(TemporaryLayout.validArrangement(rotated));XCTAssertEqual(rotated[2].y,3000)
    }
    func testAnonymousOffsetPortraitChain() throws {
        var screens=Display.samples(4)
        screens[1].x=3000;screens[1].y = -104
        screens[2].x=1920;screens[2].y = -535;screens[2].width=1080;screens[2].height=1920;screens[2].pixelWidth=2160;screens[2].pixelHeight=3840;screens[2].rotation=270
        screens[3].x = -1080;screens[3].y = -461;screens[3].width=1080;screens[3].height=1920;screens[3].pixelWidth=2160;screens[3].pixelHeight=3840;screens[3].rotation=270
        for i in screens.indices {
            let desired=try RotationPlan.make(request(screens,target:i,degrees:90)).desired
            XCTAssertTrue(TemporaryLayout.validArrangement(desired));XCTAssertEqual(desired[0].x,0)
        }
    }
    func testBadAnglesMirrorIdentityAndUnreachableGeometryFailClosed() {
        XCTAssertThrowsError(try RotationPlan.make(request(degrees:45)))
        var screens=Display.samples(2);screens[1].mirrored=true;XCTAssertThrowsError(try RotationPlan.make(request(screens)))
        screens=Display.samples(2);screens[1].id=screens[0].id;XCTAssertThrowsError(try RotationPlan.make(request(screens)))
        screens=Display.samples(2);screens[1].x=5000;XCTAssertThrowsError(try RotationPlan.make(request(screens)))
        screens=Display.samples(2);screens[1].rotation = .nan;XCTAssertThrowsError(try RotationPlan.make(request(screens)))
    }
    func testRollbackRecognizesOnlyKnownIntermediateWithoutPeerEdits() throws {
        let r=request(), desired=try RotationPlan.make(r).desired
        var interim=r.before.displays;interim[1]=desired[1]
        XCTAssertTrue(RotationPlan.recognizes(interim,request:r,desired:desired))
        interim[2].y=17;XCTAssertFalse(RotationPlan.recognizes(interim,request:r,desired:desired))
        var hotplug=desired;var extra=Display.samples(5)[4];extra.x=9000;hotplug.append(extra)
        XCTAssertFalse(RotationPlan.recognizes(hotplug,request:r,desired:desired))
    }
    func testRemoteRotationUpdatesFullOfficeWithoutPromotingSingleScreen() throws {
        let office=Snapshot(boot:"simulation",displays:Display.samples(4))
        var single=office.displays[2];single.x=0;single.main=true
        var r=request([single],target:0);r.rotationBaseline=office
        let desired=try RotationPlan.make(r).desired, updated=try RotationPlan.updatedBaseline(r,desired:desired)
        XCTAssertEqual(updated.displays.count,4);XCTAssertTrue(updated.displays[0].main)
        XCTAssertEqual(updated.displays[2].rotation,90);XCTAssertEqual(updated.displays[3].x,4920)
        var stale=office;stale.boot="other";r.rotationBaseline=stale
        XCTAssertThrowsError(try RotationPlan.make(r))
    }
    func testConsentBindsTargetAngleBaselineAndSnapshot() throws {
        var r=request();r.simulation=false;r.liveConsent=try LiveTestConsent.grant(request:r,confirmedTarget:r.target!,riskAcknowledged:true)
        XCTAssertNoThrow(try LiveTestConsent.validate(r))
        var changed=r;changed.rotationDegrees=270;XCTAssertThrowsError(try LiveTestConsent.validate(changed))
        changed=r;changed.rotationBaseline=r.before;XCTAssertThrowsError(try LiveTestConsent.validate(changed))
        changed=r;changed.before.displays[2].x+=1;XCTAssertThrowsError(try LiveTestConsent.validate(changed))
    }
    func testBackendStepGateRejectsAnotherAngleOrUnapprovedRollback() throws {
        let r=request(), plan=try RotationPlan.make(r)
        var step=plan.steps[0]
        XCTAssertNoThrow(try RotationPlan.validateStep(step,request:r,restoring:false))
        step.after[1].rotation=270
        XCTAssertThrowsError(try RotationPlan.validateStep(step,request:r,restoring:false))
        step=ModeStep(action:.arrange,target:r.target,before:plan.desired,after:r.before.displays)
        XCTAssertNoThrow(try RotationPlan.validateStep(step,request:r,restoring:true))
        step.before[0].y=13
        XCTAssertThrowsError(try RotationPlan.validateStep(step,request:r,restoring:true))
    }
    func testBaselineCommitIsAtomicCompareAndPreservesOldSnapshot() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dir=root.appendingPathComponent("Transactions/example")
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        var r=request();r.rotationBaseline=r.before
        let file=root.appendingPathComponent("demo-mode-office.json");try Files.write(r.before,to:file)
        let desired=try RotationPlan.make(r).desired
        try RotationBaselineCommit.commit(request:r,desired:desired,directory:dir)
        XCTAssertEqual(try Files.read(Snapshot.self,from:file).displays,desired)
        XCTAssertEqual(try Files.read(Snapshot.self,from:dir.appendingPathComponent("rotation-prior-baseline.json")),r.before)
        XCTAssertThrowsError(try RotationBaselineCommit.commit(request:r,desired:desired,directory:dir))
    }
}
