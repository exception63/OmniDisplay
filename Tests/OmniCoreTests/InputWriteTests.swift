import XCTest
import OmniDDC
@testable import OmniCore

final class InputWriteTests: XCTestCase {
    func request() -> Request {
        let d = Display.samples(3), snap = Snapshot(boot: "boot", displays: Display.samples(3))
        var r = Request(operation: .inputSource, before: snap, office: snap, keep: d[0].id, confirmedPhysical: true, simulation: false, target: d[1].id)
        r.inputPortMappings = [InputPortMapping(target:d[1].id,boot:"boot",route:7,code:0x11,label:"Mac HDMI"),InputPortMapping(target:d[1].id,boot:"boot",route:7,code:0x0F,label:"Windows DP")]
        r.inputBefore = 0x11; r.inputAfter = 0x0F; r.inputPortsConfirmed = true; r.inputFromPort = "Mac HDMI"; r.inputToPort = "Windows DP"; return r
    }
    func probe(_ r: Request, value: UInt16 = 0x11) -> InputProbe {
        InputProbe(target: r.target!, state: .readable, current: value, detail: "fixture", route: 7)
    }
    func testCanonicalGetIncludesSourceAddress() {
        var bytes=[UInt8](repeating:0,count:4)
        XCTAssertEqual(ODInputGetPacket(true,&bytes),4)
        XCTAssertEqual(bytes,[0x82,0x01,0x60,0xDC])
        XCTAssertEqual(bytes.reduce(UInt8(0x6e ^ 0x51), ^),0)
        ODInputGetPacket(false,&bytes);XCTAssertEqual(bytes,[0x82,0x01,0x60,0x8D])
    }
    func testExactInputSetPacketAndChecksum() {
        var bytes = [UInt8](repeating: 0, count: 6)
        XCTAssertEqual(ODInputSetPacket(0x11, &bytes),6)
        XCTAssertEqual(bytes,[0x84,0x03,0x60,0,0x11,0xC9])
        ODInputSetPacket(0x0F, &bytes); XCTAssertEqual(bytes,[0x84,0x03,0x60,0,0x0F,0xD7])
        ODInputSetPacket(0x1234, &bytes); XCTAssertEqual(bytes[3],0x12); XCTAssertEqual(bytes[4],0x34)
        XCTAssertEqual(bytes.reduce(UInt8(0x6e ^ 0x51), ^),0)
    }
    func testNativeGateRejectsBeforeAnyHardwareOrPointerAccess() {
        var detail = [CChar](repeating: 0, count: 128)
        XCTAssertEqual(ODSetInput(0, "invalid", 17, 0, 0, "invalid", false, 0, &detail, detail.count),6)
        XCTAssertTrue(String(cString: detail).contains("许可"))
    }
    func testBackendAndWorkerCannotBypassGateUsingSimulationFlag() {
        var r = request(); r.simulation = true
        XCTAssertThrowsError(try CoreGraphicsBackend().changeInput(r, restoring: false))
        XCTAssertThrowsError(try InputAttempt.worker(directory: URL(fileURLWithPath:"/no-such-transaction"),restoring:true))
    }
    func testLivePlanRequiresPortAcknowledgmentAndNonMainTarget() {
        var r = request(); XCTAssertNoThrow(try InputChangePlan(request:r))
        r.inputPortsConfirmed = false; XCTAssertThrowsError(try InputChangePlan(request:r))
        r = request(); r.target = r.keep; r.keep = r.before.displays[1].id; XCTAssertThrowsError(try InputChangePlan(request:r))
        r = request(); r.inputToPort = " "; XCTAssertThrowsError(try InputChangePlan(request:r))
    }
    func testTopologyBootAndSnapshotExpiryAreCheckedBeforeWriting() throws {
        let r = request()
        XCTAssertEqual(try InputWriteChecks.target(request:r,current:r.before.displays,boot:"boot",restoring:false).id,r.target)
        var current = r.before.displays; current[2].x += 1
        XCTAssertThrowsError(try InputWriteChecks.target(request:r,current:current,boot:"boot",restoring:false))
        XCTAssertThrowsError(try InputWriteChecks.target(request:r,current:r.before.displays,boot:"newboot",restoring:false))
        XCTAssertThrowsError(try InputWriteChecks.target(request:r,current:r.before.displays,boot:"boot",restoring:false,now:r.before.date.addingTimeInterval(61)))
    }
    func testReadFailureStaleRouteOrChangedInputNeverAuthorizesSet() throws {
        let r=request(), d=r.before.displays[1]
        XCTAssertTrue(try InputWriteChecks.requiresWrite(request:r,target:d,probe:probe(r),restoring:false))
        var p=probe(r); p.state = .readFailed
        XCTAssertThrowsError(try InputWriteChecks.requiresWrite(request:r,target:d,probe:p,restoring:false))
        p=probe(r);p.route=nil;XCTAssertThrowsError(try InputWriteChecks.requiresWrite(request:r,target:d,probe:p,restoring:false))
        p=probe(r);p.date=Date().addingTimeInterval(-6);XCTAssertThrowsError(try InputWriteChecks.requiresWrite(request:r,target:d,probe:p,restoring:false))
        p=probe(r,value:0x12);XCTAssertThrowsError(try InputWriteChecks.requiresWrite(request:r,target:d,probe:p,restoring:false))
        p=probe(r);p.simulation=true;XCTAssertThrowsError(try InputWriteChecks.requiresWrite(request:r,target:d,probe:p,restoring:false))
    }
    func testRecoveryPreservesNewPeersAndManualInputSelection() throws {
        let r=request(), current=Display.samples(4), d=current[1]
        XCTAssertNoThrow(try InputWriteChecks.target(request:r,current:current,boot:"boot",restoring:true))
        XCTAssertTrue(try InputWriteChecks.requiresWrite(request:r,target:d,probe:probe(r,value:0x0F),restoring:true))
        XCTAssertFalse(try InputWriteChecks.requiresWrite(request:r,target:d,probe:probe(r),restoring:true))
        XCTAssertThrowsError(try InputWriteChecks.requiresWrite(request:r,target:d,probe:probe(r,value:0x12),restoring:true))
        XCTAssertThrowsError(try InputWriteChecks.target(request:r,current:current.filter { $0.id != r.target },boot:"boot",restoring:true))
    }
    func testBoundedWorkerSuccessFailureTimeoutAndCancellation() throws {
        XCTAssertNoThrow(try BoundedChild.run(executable:URL(fileURLWithPath:"/usr/bin/true"),arguments:[],timeout:1))
        XCTAssertThrowsError(try BoundedChild.run(executable:URL(fileURLWithPath:"/usr/bin/false"),arguments:[],timeout:1))
        let start=Date()
        XCTAssertThrowsError(try BoundedChild.run(executable:URL(fileURLWithPath:"/bin/sleep"),arguments:["2"],timeout:0.1))
        XCTAssertLessThan(Date().timeIntervalSince(start),1)
        XCTAssertThrowsError(try BoundedChild.run(executable:URL(fileURLWithPath:"/bin/sleep"),arguments:["2"],timeout:1,cancelled:{true}))
    }
}
