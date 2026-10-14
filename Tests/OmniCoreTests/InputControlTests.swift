import XCTest
@testable import OmniCore

final class InputControlTests: XCTestCase {
    func reply(value: UInt16 = 0x11, result: UInt8 = 0) -> [UInt8] {
        var bytes: [UInt8] = [0x6e,0x88,0x02,result,0x60,0,0,0,UInt8(value >> 8),UInt8(value & 255)]
        bytes.append(bytes.reduce(0x50, ^)); bytes.append(0); return bytes
    }
    func testGetVCPValidAndUnsupportedReplies() throws {
        XCTAssertEqual(try DDCReply.parse(reply()), .current(0x11))
        XCTAssertEqual(try DDCReply.parse(reply(value: 0x0101)), .current(0x0101))
        XCTAssertEqual(try DDCReply.parse(reply(value: 0, result: 1)), .unsupported)
    }
    func testCorruptTruncatedWrongVCPAndZeroAreNotCapabilities() {
        var corrupt = reply(); corrupt[8] ^= 1
        XCTAssertThrowsError(try DDCReply.parse(corrupt))
        XCTAssertThrowsError(try DDCReply.parse(Array(reply().prefix(10))))
        var wrong = reply(); wrong[4] = 0x10; wrong[10] = wrong.prefix(10).reduce(0x50, ^)
        XCTAssertThrowsError(try DDCReply.parse(wrong))
        XCTAssertThrowsError(try DDCReply.parse(reply(value: 0)))
        XCTAssertThrowsError(try DDCReply.parse(reply(result: 2)))
    }
    func testLiveInputWritesRemainLocked() {
        XCTAssertThrowsError(try InputControl.validateWrite(simulation: false))
        XCTAssertNoThrow(try InputControl.validateWrite(simulation: true))
    }
    func request() -> Request {
        let displays = Display.samples(4), snapshot = Snapshot(boot: "simulation", displays: Display.samples(4))
        var request = Request(operation: .inputSource, before: snapshot, office: snapshot, keep: displays[0].id, confirmedPhysical: true, simulation: true, target: displays[1].id)
        request.inputBefore = 0x11; request.inputAfter = 0x0F; return request
    }
    func testInputPlanRequiresDistinctRetainedPhysicalAndCurrentValue() throws {
        var r = request(); XCTAssertEqual(try InputChangePlan(request: r).next, 0x0F)
        r.confirmedPhysical = false; XCTAssertThrowsError(try InputChangePlan(request: r))
        r = request(); r.keep = r.target!; XCTAssertThrowsError(try InputChangePlan(request: r))
        r = request(); r.inputBefore = nil; XCTAssertThrowsError(try InputChangePlan(request: r))
        r = request(); r.inputAfter = r.inputBefore; XCTAssertThrowsError(try InputChangePlan(request: r))
        r = request(); r.simulation = false; XCTAssertThrowsError(try InputChangePlan(request: r))
    }
    func testRecoveryPreservesNewScreenAndChangedPeers() throws {
        let before = Display.samples(3); var current = Display.samples(4)
        current[1].active = false; current[0].x = -920
        let result = try TargetRecovery.simulated(before: before, current: current, target: before[1].id)
        XCTAssertEqual(result[1], before[1]); XCTAssertEqual(result[0], current[0]); XCTAssertEqual(result[3], current[3])
    }
    func testRecoveryDoesNotStealMainAndRejectsDuplicateUUID() throws {
        let before = Display.samples(3); var current = before
        current[0].active = false; current[0].main = false; current[1].main = true
        let result = try TargetRecovery.simulated(before: before, current: current, target: before[0].id)
        XCTAssertTrue(result[0].active); XCTAssertFalse(result[0].main); XCTAssertTrue(result[1].main)
        XCTAssertThrowsError(try TargetRecovery.simulated(before: before, current: current + [current[0]], target: before[0].id))
    }
    func candidate(_ d: Display, id: UInt32? = nil, uuid: String? = nil) -> RecoveryCandidate {
        RecoveryCandidate(displayID: id ?? d.displayID, uuid: uuid, vendor: d.vendor, model: d.model, serial: d.serial)
    }
    func testRecoveryFindsUUIDAfterNumericIDChanges() {
        let displays = Display.samples(2), snapshot = Snapshot(boot:"boot",displays:Display.samples(2))
        let candidates = [candidate(displays[0], uuid: displays[1].id), candidate(displays[0], id: 9, uuid: displays[0].id)]
        XCTAssertEqual(RecoveryIdentity.resolve(saved: displays[0], snapshot: snapshot, boot: "boot", candidates: candidates),9)
    }
    func testRecoveryRejectsAmbiguousLiveFingerprintOrDifferentUUID() {
        let d = Display.samples(1)[0], snapshot = Snapshot(boot:"boot",displays:Display.samples(1))
        XCTAssertEqual(RecoveryIdentity.resolve(saved:d,snapshot:snapshot,boot:"boot",candidates:[candidate(d)]),d.displayID)
        XCTAssertNil(RecoveryIdentity.resolve(saved:d,snapshot:snapshot,boot:"boot",candidates:[candidate(d), candidate(d,id:9)]))
        XCTAssertNil(RecoveryIdentity.resolve(saved:d,snapshot:snapshot,boot:"boot",candidates:[candidate(d,uuid:UUID().uuidString)]))
        XCTAssertNil(RecoveryIdentity.resolve(saved:d,snapshot:snapshot,boot:"newboot",candidates:[candidate(d,uuid:d.id)]))
    }
}
