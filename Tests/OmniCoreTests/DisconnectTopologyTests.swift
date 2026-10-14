import XCTest
@testable import OmniCore

final class DisconnectTopologyTests: XCTestCase {
    func fixture() throws -> Request {
        let file=Bundle.module.url(forResource:"disconnect-before",withExtension:"json",subdirectory:"Fixtures")!
        return try Files.read(Request.self,from:file)
    }
    func testAbsentTargetNamesAndCoordinateRebaseAreNotDisconnectFailures() throws {
        let request=try fixture()
        var peers=DisconnectTopology.peers(request)
        XCTAssertTrue(DisconnectTopology.matches(request,current:peers)) // no target UUID required
        for i in peers.indices { peers[i].name="显示器"; peers[i].x+=600; peers[i].y-=100; peers[i].displayID+=20 }
        XCTAssertTrue(DisconnectTopology.matches(request,current:peers))
        peers[0].x+=1
        XCTAssertFalse(DisconnectTopology.matches(request,current:peers)) // only uniform translation is allowed
    }
    func testReplayObservedWindowServerReflowRequiresReconciliation() throws {
        let request=try fixture(), original=request.before
        var reflow=DisconnectTopology.peers(request)
        // Sanitized replay preserves observed origins and dimensions. Rotation=0
        // is a conservative test scenario, not a measured CG rotation sample.
        for i in reflow.indices {
            reflow[i].x = reflow[i].displayID == 1001 ? 3840 : reflow[i].displayID == 1003 ? 1920 : 0
            reflow[i].y=0; reflow[i].width=1920;reflow[i].height=1080
            reflow[i].pixelWidth=3840;reflow[i].pixelHeight=2160;reflow[i].rotation=0
            reflow[i].main = reflow[i].displayID == 1004
        }
        XCTAssertNoThrow(try DisconnectTopology.validateIdentities(request,current:reflow))
        XCTAssertFalse(DisconnectTopology.matches(request,current:reflow))
        let plan=try DisconnectTopology.reconciliationTargets(request,observed:reflow,current:reflow)
        XCTAssertEqual(Set(plan.map(\.id)),Set(reflow.map(\.id)))
        XCTAssertFalse(plan.contains(where: { $0.id == request.target }))
        XCTAssertTrue(plan.allSatisfy(\.active)) // never disable a peer
        XCTAssertTrue(DisconnectTopology.matches(request,current:plan))
        XCTAssertEqual(request.before,original) // temporary layout must never become baseline
        var watch=DisconnectWatch()
        XCTAssertFalse(try watch.observe(reflow,request:request,uptime:0))
        XCTAssertTrue(try watch.observe(plan,request:request,uptime:0.8))
        for time in [1.0,10.0,44.0] { XCTAssertTrue(try watch.observe(plan,request:request,uptime:time)) }
    }
    func testConcurrentEditOrNewScreenCannotGetAReconciliationPlan() throws {
        let request=try fixture(), peers=DisconnectTopology.peers(request)
        var moved=peers;moved[0].x+=30
        XCTAssertThrowsError(try DisconnectTopology.reconciliationTargets(request,observed:peers,current:moved))
        var extra=peers;var d=peers[0];d.id=UUID().uuidString;d.displayID=99;d.main=false;extra.append(d)
        XCTAssertThrowsError(try DisconnectTopology.reconciliationTargets(request,observed:peers,current:extra))
        var impostor=peers;impostor[0].serial+=1
        XCTAssertThrowsError(try DisconnectTopology.reconciliationTargets(request,observed:impostor,current:impostor))
    }
    func testTransientEnumerationCannotConfirmButMaySettleWithinBound() throws {
        let request=try fixture(), peers=DisconnectTopology.peers(request)
        var watch=DisconnectWatch()
        XCTAssertFalse(try watch.observe(nil,request:request,uptime:0))
        XCTAssertFalse(try watch.observe(peers.filter { $0.id == request.keep },request:request,uptime:0.5))
        XCTAssertTrue(try watch.observe(peers,request:request,uptime:1))
        XCTAssertFalse(try watch.observe(nil,request:request,uptime:2))
        XCTAssertThrowsError(try watch.observe(nil,request:request,uptime:3.3))
    }
    func testRetainedLossTargetReactivationMirrorAndNewIdentityFailImmediately() throws {
        let request=try fixture(), peers=DisconnectTopology.peers(request)
        var mirror=peers;mirror[0].mirrored=true
        var duplicate=peers;duplicate[1].displayID=duplicate[0].displayID
        var unknown=peers;unknown[0].id="unknown"
        for current in [peers.filter{$0.id != request.keep},request.before.displays,mirror,duplicate,unknown] {
            var watch=DisconnectWatch()
            XCTAssertThrowsError(try watch.observe(current,request:request,uptime:0))
        }
    }
    func testRotationModeAndMainRoleChangesRemainProtected() throws {
        let request=try fixture(), peers=DisconnectTopology.peers(request)
        var rotation=peers;rotation[1].rotation=0
        var mode=peers;mode[1].pixelWidth+=1
        var main=peers;main[0].main=false;main[1].main=true
        for current in [rotation,mode,main] {
            XCTAssertFalse(DisconnectTopology.matches(request,current:current))
            var watch=DisconnectWatch()
            XCTAssertFalse(try watch.observe(current,request:request,uptime:0))
            XCTAssertThrowsError(try watch.observe(current,request:request,uptime:1.3))
        }
    }
}
