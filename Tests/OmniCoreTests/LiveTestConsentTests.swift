import XCTest
@testable import OmniCore

final class LiveTestConsentTests: XCTestCase {
    func request() -> Request {
        let d=Display.samples(4), s=Snapshot(boot:"boot",displays:Display.samples(4))
        return Request(operation:.disconnect,before:s,office:s,keep:d[0].id,confirmedPhysical:true,simulation:false,target:d[1].id)
    }
    func testNoConsentByDefaultAndExactRequestBinding() throws {
        var r=request(); XCTAssertThrowsError(try LiveTestConsent.validate(r))
        r.liveConsent=try LiveTestConsent.grant(request:r,confirmedTarget:r.target!,riskAcknowledged:true)
        XCTAssertNoThrow(try LiveTestConsent.validate(r))
        var changed=r; changed.target=r.before.displays[2].id; XCTAssertThrowsError(try LiveTestConsent.validate(changed))
        changed=r;changed.keep=r.before.displays[3].id;XCTAssertThrowsError(try LiveTestConsent.validate(changed))
        changed=r;changed.before.displays[1].x+=10;XCTAssertThrowsError(try LiveTestConsent.validate(changed))
        changed=r;changed.operation = .inputSource;XCTAssertThrowsError(try LiveTestConsent.validate(changed))
    }
    func testConfirmedTargetAndPhysicalAcknowledgmentRequired() {
        var r=request()
        XCTAssertThrowsError(try LiveTestConsent.grant(request:r,confirmedTarget:"wrong",riskAcknowledged:true))
        XCTAssertThrowsError(try LiveTestConsent.grant(request:r,confirmedTarget:r.target!,riskAcknowledged:false))
        r.confirmedPhysical=false;XCTAssertThrowsError(try LiveTestConsent.grant(request:r,confirmedTarget:r.target!,riskAcknowledged:true))
    }
    func testExpiredApplyCannotReplayAndRecoverySurvivesSleep() throws {
        var r=request();let now=Date()
        r.liveConsent=try LiveTestConsent.grant(request:r,confirmedTarget:r.target!,riskAcknowledged:true,now:now)
        XCTAssertThrowsError(try LiveTestConsent.validate(r,now:now.addingTimeInterval(91)))
        XCTAssertNoThrow(try LiveTestConsent.validate(r,restoring:true,now:now.addingTimeInterval(91)))
        XCTAssertNoThrow(try LiveTestConsent.validate(r,restoring:true,now:now.addingTimeInterval(3600)))
    }
    func testLiveDisconnectRejectsMainLastScreenMirrorAndAmbiguousRecovery() throws {
        func signed(_ r: Request) throws -> Request { var x=r;x.liveConsent=try LiveTestConsent.grant(request:x,confirmedTarget:x.target!,riskAcknowledged:true);return x }
        var r=try signed(request());XCTAssertNoThrow(try DisconnectWriteChecks.validate(r,current:r.before.displays,boot:"boot"))
        r=request();r.target=r.keep;r.keep=r.before.displays[1].id;r=try signed(r)
        XCTAssertThrowsError(try DisconnectWriteChecks.validate(r,current:r.before.displays,boot:"boot"))
        r=request();r.before.displays=[r.before.displays[1]];r=try signed(r)
        XCTAssertThrowsError(try DisconnectWriteChecks.validate(r,current:r.before.displays,boot:"boot"))
        r=request();r.before.displays[2].mirrored=true;r=try signed(r)
        XCTAssertThrowsError(try DisconnectWriteChecks.validate(r,current:r.before.displays,boot:"boot"))
        r=request();r.before.displays[2].serial=r.before.displays[1].serial;r=try signed(r)
        XCTAssertThrowsError(try DisconnectWriteChecks.validate(r,current:r.before.displays,boot:"boot"))
        r=try signed(request());var current=r.before.displays;current[1].displayID=99
        XCTAssertThrowsError(try DisconnectWriteChecks.validate(r,current:current,boot:"boot"))
    }
    func testJSONRoundTripPreservesDigest() throws {
        var r=request();r.liveConsent=try LiveTestConsent.grant(request:r,confirmedTarget:r.target!,riskAcknowledged:true)
        let decoded=try JSONDecoder().decode(Request.self,from:JSONEncoder().encode(r))
        XCTAssertNoThrow(try LiveTestConsent.validate(decoded))
    }
    func testLegacyRemoteAndSimulationCannotCreateLivePermit() {
        var r=request();r.operation = .remote
        XCTAssertThrowsError(try LiveTestConsent.grant(request:r,confirmedTarget:r.target!,riskAcknowledged:true))
        r=request();r.simulation=true
        XCTAssertThrowsError(try LiveTestConsent.grant(request:r,confirmedTarget:r.target!,riskAcknowledged:true))
    }
}
