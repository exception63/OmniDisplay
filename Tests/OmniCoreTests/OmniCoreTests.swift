import XCTest
@testable import OmniCore

final class OmniCoreTests: XCTestCase {
    func testOneScreenNeverDisablesLastScreen() {
        let screens = Display.samples(1)
        XCTAssertThrowsError(try RemotePlan.make(displays: screens, keep: screens[0].id))
    }
    func testEmptyTopologyRejected() { XCTAssertThrowsError(try RemotePlan.make(displays: [], keep: "missing")) }
    func testDynamicTopologies() throws {
        for count in [2, 4, 8, 16, 24] {
            let screens = Display.samples(count)
            for retained in screens {
                let plan = try RemotePlan.make(displays: screens, keep: retained.id)
                XCTAssertEqual(plan.disable.count, count-1)
                XCTAssertFalse(plan.disable.contains(retained.id))
                XCTAssertNoThrow(try plan.validate(current: screens))
            }
        }
    }
    func testSameModelDistinctUUIDs() throws {
        let screens = Display.samples(4)
        XCTAssertEqual(Set(screens.dropFirst().map(\.name)).count, 1)
        let plan = try RemotePlan.make(displays: screens, keep: screens[2].id)
        XCTAssertEqual(Set(plan.disable).count, 3)
        XCTAssertFalse(plan.disable.contains(screens[2].id))
    }
    func testDuplicateIdentityRejected() {
        var screens = Display.samples(2); screens[1].id = screens[0].id
        XCTAssertThrowsError(try RemotePlan.make(displays: screens, keep: screens[0].id))
    }
    func testOfflineRetainedRejected() {
        var screens = Display.samples(4); screens[2].active = false
        XCTAssertThrowsError(try RemotePlan.make(displays: screens, keep: screens[2].id))
    }
    func testUnknownRetainedRejected() { XCTAssertThrowsError(try RemotePlan.make(displays: Display.samples(4), keep: "unknown")) }
    func testMirrorRejected() {
        var screens = Display.samples(4); screens[2].mirrored = true
        XCTAssertThrowsError(try RemotePlan.make(displays: screens, keep: screens[0].id))
    }
    func testHotplugInvalidatesPreview() throws {
        let screens = Display.samples(4); let plan = try RemotePlan.make(displays: screens, keep: screens[0].id)
        XCTAssertThrowsError(try plan.validate(current: Array(screens.dropLast())) )
        XCTAssertThrowsError(try plan.validate(current: Display.samples(5)))
    }
    func testLayoutAndIDChangeInvalidatePreview() throws {
        let screens = Display.samples(4); let plan = try RemotePlan.make(displays: screens, keep: screens[0].id)
        var modified = screens; modified[0].x = 88
        XCTAssertThrowsError(try plan.validate(current: modified))
        modified = screens; modified[0].displayID = 999
        XCTAssertThrowsError(try plan.validate(current: modified))
    }
    func testInactiveScreensAreNotDisabled() throws {
        var screens = Display.samples(4); screens[2].active = false
        let plan = try RemotePlan.make(displays: screens, keep: screens[0].id)
        XCTAssertEqual(plan.disable.count, 2)
    }
    func testSnapshotRoundTrip() throws {
        let snapshot = Snapshot(boot: "boot-1", displays: Display.samples(8))
        let decoded = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(snapshot, decoded)
    }
    func testCorruptSnapshotIsNotSilentlyAccepted() { XCTAssertThrowsError(try JSONDecoder().decode(Snapshot.self, from: Data("{}".utf8))) }
    func testTerminalPhases() {
        for phase in [Phase.ready, .applying, .awaitingConfirmation, .restoring] { XCTAssertFalse(phase.terminal) }
        for phase in [Phase.confirmed, .restored, .failed] { XCTAssertTrue(phase.terminal) }
    }
}

final class RecoveryRegressionTests: XCTestCase {
    func fixture() -> Snapshot {
        var displays = Display.samples(4)
        for i in displays.indices { displays[i].model = UInt32(100+i) }
        return Snapshot(boot: "same-boot", displays: displays)
    }
    func testOfflineNilUUIDCanRecoverWithUniqueLiveFingerprint() {
        let s = fixture(); let d = s.displays[1]
        XCTAssertTrue(RecoveryIdentity.canReconnect(saved: d, snapshot: s, boot: s.boot, currentUUID: nil, vendor: d.vendor, model: d.model, serial: d.serial))
    }
    func testWrongBootRejectsEvenMatchingFingerprint() {
        let s = fixture(); let d = s.displays[1]
        XCTAssertFalse(RecoveryIdentity.canReconnect(saved: d, snapshot: s, boot: "other-boot", currentUUID: nil, vendor: d.vendor, model: d.model, serial: d.serial))
    }
    func testWrongUUIDDoesNotFallBackToHardware() {
        let s = fixture(); let d = s.displays[1]
        XCTAssertFalse(RecoveryIdentity.canReconnect(saved: d, snapshot: s, boot: s.boot, currentUUID: "different-display", vendor: d.vendor, model: d.model, serial: d.serial))
    }
    func testReusedIDWithDifferentHardwareRejected() {
        let s = fixture(); let d = s.displays[1]
        XCTAssertFalse(RecoveryIdentity.canReconnect(saved: d, snapshot: s, boot: s.boot, currentUUID: nil, vendor: d.vendor, model: d.model+1, serial: d.serial))
    }
    func testIdenticalSeriallessPanelsRejectAmbiguousFallback() {
        var s = fixture(); s.displays[0].serial = 0; s.displays[1].serial = 0; s.displays[1].model = s.displays[0].model
        let d = s.displays[0]
        XCTAssertFalse(RecoveryIdentity.canReconnect(saved: d, snapshot: s, boot: s.boot, currentUUID: nil, vendor: d.vendor, model: d.model, serial: 0))
    }
    func testMissingHardwareRejected() {
        let s = fixture(); let d = s.displays[1]
        XCTAssertFalse(RecoveryIdentity.canReconnect(saved: d, snapshot: s, boot: s.boot, currentUUID: nil, vendor: 0, model: 0, serial: 0))
    }
    func testProductionSwitchAlwaysBlockedButSimulationAllowed() {
        XCTAssertThrowsError(try LiveSwitchPolicy.validate(simulation: false))
        XCTAssertNoThrow(try LiveSwitchPolicy.validate(simulation: true))
    }
    func testBackendHasNoRealDisablePath() {
        let s = fixture()
        let request = Request(operation: .remote, before: s, office: s, keep: s.displays[0].id, confirmedPhysical: true, simulation: false)
        XCTAssertThrowsError(try CoreGraphicsBackend().applyRemote(request))
    }
}

final class SingleScreenTests: XCTestCase {
    func testDisconnectChangesOnlyTarget() throws {
        let displays = Display.samples(4)
        let plan = try SingleDisplayPlan.make(action: .disconnect, target: displays[2].id, displays: displays, retainedPhysical: displays[0].id)
        let result = plan.simulatedResult()
        XCTAssertFalse(result[2].active)
        for i in [0,1,3] { XCTAssertEqual(result[i], displays[i]) }
        XCTAssertEqual(result[2].x, displays[2].x)
    }
    func testReconnectLeavesPeerLayoutUntouched() throws {
        var displays = Display.samples(4); displays[2].active = false; displays[2].rotation = 270
        let plan = try SingleDisplayPlan.make(action: .connect, target: displays[2].id, displays: displays)
        let result = plan.simulatedResult()
        XCTAssertTrue(result[2].active); XCTAssertEqual(result[2].rotation,270)
        for i in [0,1,3] { XCTAssertEqual(result[i],displays[i]) }
    }
    func testLastActiveScreenProtectedWithOfflineRecords() {
        var d = Display.samples(4)
        for i in 1..<4 { d[i].active = false }
        XCTAssertThrowsError(try SingleDisplayPlan.make(action:.disconnect,target:d[0].id,displays:d,retainedPhysical:d[1].id))
    }
    func testRepeatedActionsRejected() {
        var d = Display.samples(2)
        XCTAssertThrowsError(try SingleDisplayPlan.make(action:.connect,target:d[1].id,displays:d))
        d[1].active=false
        XCTAssertThrowsError(try SingleDisplayPlan.make(action:.disconnect,target:d[1].id,displays:d,retainedPhysical:d[0].id))
    }
    func testHotplugInvalidatesSinglePlan() throws {
        let d = Display.samples(4)
        let p = try SingleDisplayPlan.make(action:.disconnect,target:d[2].id,displays:d,retainedPhysical:d[0].id)
        XCTAssertThrowsError(try p.validate(current:Array(d.dropLast())))
    }
    func testNeverRetainTargetAsOnlyPhysicalPanel() {
        let d = Display.samples(4)
        XCTAssertThrowsError(try SingleDisplayPlan.make(action:.disconnect,target:d[2].id,displays:d,retainedPhysical:d[2].id))
    }
    func testPeerChangeStopsLayoutReplay() {
        let d = Display.samples(4); var changed = d; changed[0].x = 50
        XCTAssertFalse(LayoutGuard.peersUnchanged(before:d,current:changed,target:d[2].id))
        changed=d; changed[2].rotation=270
        XCTAssertTrue(LayoutGuard.peersUnchanged(before:d,current:changed,target:d[2].id))
    }
    func testPeerHotplugStopsLayoutReplay() {
        let d = Display.samples(4)
        XCTAssertFalse(LayoutGuard.peersUnchanged(before:d,current:Array(d.dropLast()),target:d[1].id))
    }
}
