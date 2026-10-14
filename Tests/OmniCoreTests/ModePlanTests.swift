import XCTest
@testable import OmniCore

final class ModePlanTests:XCTestCase {
    func request(_ count:Int=4,keep:Int=0,operation:OmniCore.Operation = .remoteMode,entry:[Display]?=nil)->Request {
        let d=Display.samples(count),office=Snapshot(boot:"simulation",displays:d)
        return Request(operation:operation,before:Snapshot(boot:"simulation",displays:entry ?? d),office:office,keep:d[keep].id,confirmedPhysical:true,simulation:true,timeout:1,target:d[keep].id)
    }
    func assertSafe(_ plan:ModePlan) {
        for step in plan.steps {
            XCTAssertFalse(step.before.isEmpty);XCTAssertFalse(step.after.isEmpty)
            XCTAssertEqual(step.after.filter(\.main).count,1)
            if step.action == .disable {
                XCTAssertFalse(step.before.first{$0.id==step.target}!.main)
                XCTAssertFalse(step.before.first{$0.id==step.target}!.builtin)
                XCTAssertGreaterThan(step.before.count,1)
            }
        }
    }
    func testDefaultRemoteRetainsPrimaryAndOfficeSnapshot() throws {
        let r=request(),p=try ModePlan.make(r)
        XCTAssertEqual(p.desired.map(\.id),[r.keep]);XCTAssertEqual(r.office.displays.count,4)
        XCTAssertEqual(p.steps.filter{$0.action == .disable}.count,3);assertSafe(p)
    }
    func testRemoteAToBEnablesBThenPromotesBeforeDisablingA() throws {
        let first=request(),a=try ModePlan.make(first).desired
        let r=request(keep:2,entry:a),p=try ModePlan.make(r)
        XCTAssertEqual(p.steps.first?.action,.enable)
        XCTAssertEqual(p.steps.first?.target,r.keep)
        let disable=try XCTUnwrap(p.steps.firstIndex{$0.action == .disable})
        XCTAssertTrue(p.steps[..<disable].contains{$0.after.first(where:\.main)?.id == r.keep})
        XCTAssertEqual(p.desired.first?.id,r.keep);assertSafe(p)
    }
    func testRemoteAToBCancelRollsBackAOnly() throws {
        let a=try ModePlan.make(request()).desired,r=request(keep:2,entry:a),p=try ModePlan.make(r)
        let rollback=try ModePlan.transition(from:p.desired,to:r.before.displays,office:r.office.displays)
        XCTAssertEqual(rollback.desired,a);XCTAssertEqual(rollback.steps.first?.action,.enable)
        XCTAssertEqual(rollback.desired.count,1);assertSafe(rollback)
    }
    func testOfficeFromRemoteRestoresEntireSavedLayout() throws {
        var r=request(operation:.officeMode)
        r.before.displays=try ModePlan.make(request(keep:2)).desired
        let p=try ModePlan.make(r)
        XCTAssertEqual(p.desired,r.office.displays);XCTAssertFalse(p.steps.contains{$0.action == .disable});assertSafe(p)
    }
    func testOfficeCancelRestoresEntryRatherThanOffice() throws {
        var r=request(operation:.officeMode);r.before.displays=try ModePlan.make(request(keep:1)).desired
        let p=try ModePlan.make(r),rollback=try ModePlan.transition(from:p.desired,to:r.before.displays,office:r.office.displays)
        XCTAssertEqual(rollback.desired,r.before.displays);assertSafe(rollback)
    }
    func testRepeatedRequestsAreNoOp() throws {
        var r=request();r.before.displays=try ModePlan.make(r).desired
        XCTAssertTrue(try ModePlan.make(r).steps.isEmpty)
        XCTAssertTrue(try ModePlan.make(request(operation:.officeMode)).steps.isEmpty)
    }
    func testPortraitAndNegativeOriginsRestore() throws {
        var r=request();var d=r.office.displays
        d[1].width=1080;d[1].height=1920;d[1].rotation=270;d[1].pixelWidth=2160;d[1].pixelHeight=3840
        d[1].y = -535; d[2].x=3000;d[2].y = -104
        d[3].x = -1080;d[3].y = -461;d[3].width=1080;d[3].height=1920;d[3].rotation=270;d[3].pixelWidth=2160;d[3].pixelHeight=3840
        r.office.displays=d;r.before.displays=d
        let p=try ModePlan.make(r);assertSafe(p)
        let back=try ModePlan.transition(from:p.desired,to:d,office:d)
        XCTAssertEqual(back.desired,d);assertSafe(back)
    }
    func testUnknownNewScreenAndMissingRetainedReject() throws {
        var r=request();r.before.displays.append(Display.samples(5)[4]);XCTAssertThrowsError(try ModePlan.make(r))
        r=request();r.keep="absent";r.target=r.keep;XCTAssertThrowsError(try ModePlan.make(r))
    }
    func testMirrorBuiltinFingerprintAndBootReject() {
        var r=request();r.office.displays[1].mirrored=true;XCTAssertThrowsError(try ModePlan.make(r))
        r=request();r.before.displays[1].builtin=true;r.office.displays[1].builtin=true;XCTAssertThrowsError(try ModePlan.make(r))
        r=request();r.office.displays[1].serial=0;r.before.displays=r.office.displays;XCTAssertThrowsError(try ModePlan.make(r))
        r=request();r.office.boot="other";XCTAssertThrowsError(try ModePlan.make(r))
    }
    func testUnknownRollbackStateNotRecognized() throws {
        let r=request(),p=try ModePlan.make(r)
        var manual=p.steps[0].after;manual[0].y+=30
        XCTAssertFalse(p.recognizes(manual,entry:r.before.displays))
        XCTAssertTrue(p.recognizes(p.desired,entry:r.before.displays))
    }
    func testHardwareStatusUsesActualSetAndGeometry() throws {
        let r=request(),p=try ModePlan.make(r)
        XCTAssertTrue(ModePlan.status(current:r.before.displays,office:r.office).hasPrefix("办公室"))
        XCTAssertTrue(ModePlan.status(current:p.desired,office:r.office).hasPrefix("远程"))
        XCTAssertTrue(ModePlan.status(current:p.steps[0].after,office:r.office).hasPrefix("部分状态"))
        var moved=r.before.displays;moved[1].y+=10
        XCTAssertTrue(ModePlan.status(current:moved,office:r.office).hasPrefix("部分状态"))
    }
    func testConsentBindsModeBaselineEntryKeepAndOperation() throws {
        var r=request();r.simulation=false
        r.liveConsent=try LiveTestConsent.grant(request:r,confirmedTarget:r.keep,riskAcknowledged:true)
        XCTAssertNoThrow(try LiveTestConsent.validate(r))
        var bad=r;bad.office.displays[1].x+=1;XCTAssertThrowsError(try LiveTestConsent.validate(bad))
        bad=r;bad.keep=r.office.displays[1].id;XCTAssertThrowsError(try LiveTestConsent.validate(bad))
        bad=r;bad.operation = .officeMode;XCTAssertThrowsError(try LiveTestConsent.validate(bad))
    }
    func testOneScreenAndManyScreenPlansNeverReachZero() throws {
        for n in [1,2,4,8,24] { let p=try ModePlan.make(request(n));assertSafe(p);XCTAssertEqual(p.desired.count,1) }
    }
}
