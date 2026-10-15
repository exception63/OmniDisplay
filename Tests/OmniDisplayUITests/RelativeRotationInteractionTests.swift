import XCTest
import OmniCore
@testable import OmniDisplay

final class RelativeRotationInteractionTests: XCTestCase {
    @MainActor func model() throws -> AppModel {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let config=try AppLaunch.resolve(arguments:[],bundleID:"example.rotation.simulation",simulationBundle:true,support:dir)
        return AppModel(configuration:config)
    }
    @MainActor func testDoubleClickAndCancellationDiscardPendingRead() async throws {
        let m=try model();let target=m.displays[1].id
        var continuation: CheckedContinuation<Snapshot,Error>?
        m.rotationSnapshotReader={ try await withCheckedThrowingContinuation { continuation=$0 } }
        m.prepareRelativeRotation(target,action:.clockwise)
        XCTAssertTrue(m.rotationReading)
        m.prepareRelativeRotation(target,action:.flip)
        XCTAssertEqual(m.rotationAction,.clockwise)
        while continuation == nil { await Task.yield() }
        m.cancelRotationPreview()
        continuation?.resume(returning:Snapshot(boot:"simulation",displays:m.displays))
        for _ in 0..<5 { await Task.yield() }
        XCTAssertNil(m.rotationPreview);XCTAssertFalse(m.rotationReading);XCTAssertFalse(m.busy)
    }
    @MainActor func testExternalRotationAfterPreviewRejectsConfirmationWithoutLaunching() async throws {
        let m=try model();let target=m.displays[1].id
        m.prepareRelativeRotation(target,action:.clockwise)
        for _ in 0..<100 where m.rotationPreview == nil { await Task.yield() }
        let preview=try XCTUnwrap(m.rotationPreview)
        XCTAssertNil(m.modePreview);XCTAssertNil(m.actionDisplay)
        m.displays=try RotationPlan.layout(m.displays,target:target,degrees:90)
        m.executeRelativeRotation(preview,confirmed:true)
        for _ in 0..<100 where m.rotationReading { await Task.yield() }
        XCTAssertFalse(m.busy);XCTAssertNil(m.transactionRequest);XCTAssertNil(m.rotationPreview);XCTAssertNotNil(m.error)
    }
    @MainActor func testUnconfirmedInlinePreviewCannotLaunch() async throws {
        let m=try model();let target=m.displays[1].id
        m.prepareRelativeRotation(target,action:.flip)
        for _ in 0..<100 where m.rotationPreview == nil { await Task.yield() }
        let preview=try XCTUnwrap(m.rotationPreview)
        m.executeRelativeRotation(preview,confirmed:false)
        XCTAssertFalse(m.busy);XCTAssertNil(m.transactionRequest)
        XCTAssertNotNil(m.rotationPreview);XCTAssertTrue(m.interactionBlocked)
        m.cancelRotationPreview()
    }
}
