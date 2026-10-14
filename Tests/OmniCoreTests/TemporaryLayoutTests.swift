import XCTest
@testable import OmniCore

final class TemporaryLayoutTests: XCTestCase {
    func session(_ displays: [Display], target: Int = 1) throws -> LayoutSession {
        try .make(original: Snapshot(boot: "simulation", displays: displays), target: displays[target].id)
    }
    func portraitMiddle() -> [Display] {
        var d = Display.samples(4)
        d[1].x=1920; d[1].y = -535; d[1].width=1080; d[1].height=1920
        d[1].pixelWidth=2160; d[1].pixelHeight=3840; d[1].rotation=270
        d[2].x=3000; d[2].y = -104
        d[3].x = -1080; d[3].y = -461; d[3].width=1080; d[3].height=1920
        d[3].pixelWidth=2160; d[3].pixelHeight=3840; d[3].rotation=270
        return d
    }
    func testMiddleClosesGapKeepingPrimaryAndOrder() throws {
        let d=Display.samples(4), s=try session(d)
        XCTAssertEqual(s.temporary.displays.map(\.x), [0,1920,3840])
        XCTAssertEqual(s.temporary.displays.first, d.first)
        XCTAssertEqual(s.original.displays,d)
    }
    func testPortraitMiddleAnonymousReplay() throws {
        let d=portraitMiddle(), s=try session(d)
        XCTAssertEqual(s.temporary.displays.map(\.x),[0,1920,-1080])
        XCTAssertEqual(s.temporary.displays.map(\.y),[0,-104,-461])
        XCTAssertEqual(s.temporary.displays.map(\.rotation),[0,0,270])
        XCTAssertEqual(s.original.displays,d)
        try s.validate(boot:"simulation")
    }
    func testEdgeDoesNotMovePeers() throws {
        let d=Display.samples(4), s=try session(d,target:3)
        XCTAssertEqual(s.temporary.displays,Array(d.prefix(3)))
    }
    func testVerticalMiddleClosesVerticalGap() throws {
        var d=Display.samples(3)
        for i in d.indices { d[i].x=0; d[i].y=Int32(i*1080) }
        XCTAssertEqual(try session(d).temporary.displays.map(\.y),[0,1080])
    }
    func testLShapedSurvivingComponentMovesRigidly() throws {
        var d=Display.samples(4)
        d[3].x=3840; d[3].y=1080
        let s=try session(d)
        XCTAssertEqual(s.temporary.displays.map(\.x),[0,1920,1920])
        XCTAssertEqual(s.temporary.displays.map(\.y),[0,0,1080])
    }
    func testUnsupportedDiagonalTopologyFailsClosed() {
        var d=Display.samples(3)
        d[2].x=1920; d[2].y=1080
        XCTAssertThrowsError(try session(d)) // Closing this corner needs prohibited diagonal/ordering changes.
    }
    func testMainBuiltinMirrorOverlapAndCornerOnlyRejected() {
        let d=Display.samples(3)
        XCTAssertThrowsError(try session(d,target:0))
        var bad=d; bad[1].builtin=true; XCTAssertThrowsError(try session(bad))
        bad=d; bad[2].mirrored=true; XCTAssertThrowsError(try session(bad))
        bad=d; bad[2].x=2000; XCTAssertThrowsError(try session(bad))
        bad=d; bad[2].y=1080; XCTAssertThrowsError(try session(bad))
        bad=d; bad[2].id=bad[1].id; XCTAssertThrowsError(try session(bad))
    }
    func testSessionRoundTripAndTamperingRejected() throws {
        let s=try session(portraitMiddle())
        let decoded=try JSONDecoder().decode(LayoutSession.self,from:JSONEncoder().encode(s))
        try decoded.validate(boot:"simulation")
        XCTAssertThrowsError(try decoded.validate(boot:"new-boot"))
        var bad=s; bad.temporary.displays[1].x+=1
        XCTAssertThrowsError(try bad.validate(boot:"simulation"))
    }
    func testReconnectRestoresFullSnapshotNotCompactedBaseline() throws {
        let s=try session(portraitMiddle()), disconnected=s.simulatedDisconnected()
        let restored=try s.simulatedRestore(disconnected)
        XCTAssertTrue(s.matchesOriginal(restored))
        XCTAssertEqual(restored,s.original.displays)
        XCTAssertEqual(restored[2].x,3000)
    }
    func testCancelRecoveryUsesOriginalAndPreservesConcurrentNewDisplay() throws {
        let s=try session(portraitMiddle())
        var current=s.simulatedDisconnected()
        var added=Display.samples(5)[4]; added.x=10000; current.append(added)
        let restored=try s.simulatedRestore(current)
        XCTAssertTrue(restored.contains(added)); XCTAssertTrue(restored.contains{$0.id==s.target && $0.active})
        XCTAssertEqual(restored.first{$0.id==s.temporary.displays[1].id}?.x,1920)
        XCTAssertThrowsError(try s.validateRestore(restored))
    }
    func testManualPeerMoveCannotBeOverwritten() throws {
        let s=try session(portraitMiddle())
        var current=s.simulatedDisconnected(); current[1].x+=12
        XCTAssertFalse(s.peersMayRestore(current.filter(\.active)))
        let restored=try s.simulatedRestore(current)
        XCTAssertEqual(restored.first{$0.id==current[1].id}?.x,current[1].x)
        XCTAssertThrowsError(try s.validateRestore(restored))
    }
    func testRestoreRejectsPrimaryRotationIdentityAndMissingPeerChanges() throws {
        let s=try session(portraitMiddle()), enabled=try TargetRecovery.simulated(before:s.original.displays,current:s.simulatedDisconnected(),target:s.target)
        XCTAssertNoThrow(try s.validateRestore(enabled))
        var bad=enabled; bad[0].main=false; bad[1].main=true; XCTAssertThrowsError(try s.validateRestore(bad))
        bad=enabled; bad[1].rotation=90; XCTAssertThrowsError(try s.validateRestore(bad))
        bad=enabled; bad[1].serial+=1; XCTAssertThrowsError(try s.validateRestore(bad))
        XCTAssertThrowsError(try s.validateRestore(Array(enabled.dropLast())))
    }
    func testFinalValidationRejectsArbitraryGlobalDriftAndCASChanges() throws {
        let s=try session(portraitMiddle())
        var request=Request(operation:.disconnect,before:s.original,office:s.original,keep:s.original.displays[0].id,confirmedPhysical:true,simulation:true,target:s.target)
        request.layoutSession=s
        XCTAssertTrue(DisconnectTopology.matches(request,current:s.temporary.displays))
        let shifted=s.temporary.displays.map { d in var x=d; x.x+=1; return x }
        XCTAssertFalse(DisconnectTopology.matches(request,current:shifted))
        XCTAssertThrowsError(try DisconnectTopology.reconciliationTargets(request,observed:s.temporary.displays,current:shifted))
    }
    func testDeterministicAcrossEnumerationOrder() throws {
        let d=portraitMiddle(), expected=try session(d).temporary.displays.sorted{$0.id<$1.id}
        XCTAssertEqual(try TemporaryLayout.plan(Array(d.reversed()),removing:d[1].id).sorted{$0.id<$1.id},expected)
    }
}
