import XCTest
@testable import OmniCore

final class DisconnectStabilizerTests: XCTestCase {
    func fixture() throws -> Request {
        try Files.read(Request.self, from: Bundle.module.url(forResource: "disconnect-replay-before", withExtension: "json", subdirectory: "Fixtures")!)
    }
    func testConstructedSlowFailureThenTwoFreshReadsFitsUnchangedBudget() throws {
        // Constructed values, not recovered missing samples from a field test.
        // Old loop: .80 failed + .15 sleep + .12 good + .15 sleep = 1.22,
        // exits with one good sample. New start-to-start cadence completes at 1.07.
        let request = try fixture(), peers = DisconnectTopology.peers(try fixture())
        var time = 0.0, reads = 0, events: [StabilitySample] = []
        let result = try DisconnectStabilizer.wait(request: request, matching: false, read: {
            reads += 1; time += reads == 1 ? 0.80 : 0.12
            if reads == 1 { throw OmniError.message("constructed observer timeout") }; return peers
        }, safe: {}, now: { time }, pause: { time += $0 }, audit: { events.append($0) })
        XCTAssertEqual(result, peers); XCTAssertEqual(reads, 3); XCTAssertEqual(time, 1.07, accuracy: 0.0001)
        XCTAssertEqual(events.map(\.outcome), ["readFailed", "needsSecondObservation", "stableOriginalLayout"])
        XCTAssertEqual(events.last?.consecutive, 2)
        XCTAssertTrue(events.allSatisfy { $0.deadline == 1.2 })
    }
    func testStableReflowEntersReconciliationAfterGraceWithoutMatchingOriginal() throws {
        let request = try fixture(); var peers = DisconnectTopology.peers(request)
        peers[0].x += 100
        var time = 0.0
        let result = try DisconnectStabilizer.wait(request: request, matching: false, read: { time += 0.10; return peers }, safe: {}, now: { time }, pause: { time += $0 })
        XCTAssertEqual(result, peers); XCTAssertFalse(DisconnectTopology.matches(request, current: result)); XCTAssertEqual(time, 1.2, accuracy: 0.0001)
        XCTAssertNoThrow(try DisconnectTopology.reconciliationTargets(request, observed: result, current: result))
    }
    func testFinalStageRejectsStableWrongLayout() throws {
        let request = try fixture(); var peers = DisconnectTopology.peers(request); peers[0].x += 100
        var time = 0.0
        XCTAssertThrowsError(try DisconnectStabilizer.wait(request: request, matching: true, read: { time += 0.1; return peers }, safe: {}, now: { time }, pause: { time += $0 }))
    }
    func testLateSecondCorrectSampleRejected() throws {
        let request = try fixture(), peers = DisconnectTopology.peers(try fixture())
        var time = 0.0, events: [StabilitySample] = []
        XCTAssertThrowsError(try DisconnectStabilizer.wait(request: request, matching: false, read: { time += 0.65; return peers }, safe: {}, now: { time }, pause: { time += $0 }, audit: { events.append($0) }))
        XCTAssertEqual(events.last?.outcome, "deadlineExceeded")
    }
    func testReadFailureResetsQuorumAndRecordsActualError() throws {
        let request = try fixture(), peers = DisconnectTopology.peers(try fixture())
        var time = 0.0, reads = 0, events: [StabilitySample] = []
        _ = try DisconnectStabilizer.wait(request: request, matching: true, read: {
            reads += 1; time += 0.1
            if reads == 2 { throw OmniError.message("lost child") }; return peers
        }, safe: {}, now: { time }, pause: { time += $0 }, audit: { events.append($0) })
        XCTAssertEqual(reads, 4); XCTAssertEqual(events[1].consecutive, 0); XCTAssertEqual(events[1].error, "lost child")
    }
    func testUnsafeIdentityMirrorRetainedLossAndNewScreenStillReject() throws {
        let request = try fixture(), peers = DisconnectTopology.peers(try fixture())
        var mirror = peers; mirror[0].mirrored = true
        var identity = peers; identity[0].serial += 1
        let missing = peers.filter { $0.id != request.keep }
        var newScreen = peers; var added = Display.samples(1)[0]; added.id = UUID().uuidString; added.displayID = 555; newScreen.append(added)
        for current in [mirror, identity, missing, newScreen] {
            var time = 0.0
            XCTAssertThrowsError(try DisconnectStabilizer.wait(request: request, matching: false, read: { time += 0.1; return current }, safe: {}, now: { time }, pause: { time += $0 }))
        }
    }
    func testCancellationAfterReadCannotAuthorizeReconciliation() throws {
        let request = try fixture(); let peers = DisconnectTopology.peers(request)
        var time = 0.0, cancelled = false
        XCTAssertThrowsError(try DisconnectStabilizer.wait(request: request, matching: false, read: { time += 0.1; cancelled = true; return peers }, safe: { if cancelled { throw OmniError.message("cancelled") } }, now: { time }, pause: { time += $0 }))
    }
    func testDifferentObserverMetadataDoesNotEnterTopologyComparison() throws {
        let peers = DisconnectTopology.peers(try fixture())
        let a = DisplayObservation(nonce: "a", pid: 123450, boot: "b", started: 1, completed: 1.1, generation: 3, displays: peers)
        let b = DisplayObservation(nonce: "b", pid: 123451, boot: "b", started: 2, completed: 2.1, generation: 999, displays: peers)
        let av = try a.validate(nonce: "a", childPID: 123450, boot: "b", launched: 1, now: 1.2)
        let bv = try b.validate(nonce: "b", childPID: 123451, boot: "b", launched: 2, now: 2.2)
        XCTAssertTrue(DisconnectTopology.sameObservation(av, bv))
    }
}
