import XCTest
@testable import OmniCore

final class StabilityBoundaryTests: XCTestCase {
    func fixture() -> (Request, [Display]) {
        var screens = Display.samples(4)
        screens[2].rotation = 270; screens[2].width = 1080; screens[2].height = 1920
        screens[3].rotation = 270; screens[3].width = 1080; screens[3].height = 1920
        let snapshot = Snapshot(boot: "synthetic", displays: screens)
        let request = Request(operation: .disconnect, before: snapshot, office: snapshot, keep: screens[0].id,
                              confirmedPhysical: true, simulation: true, target: screens[2].id)
        var peers = DisconnectTopology.peers(request)
        for i in peers.indices {
            peers[i].x = i == 0 ? 1920 : i == 1 ? -1920 : 0; peers[i].y = 0
            peers[i].width = 1920; peers[i].height = 1080; peers[i].rotation = 0
            peers[i].pixelWidth = 3840; peers[i].pixelHeight = 2160; peers[i].main = i == 2
        }
        return (request, peers)
    }
    func testAnonymizedFieldTimelineHoldsSixSamplesWithoutSeventhRead() throws {
        let (request, peers) = fixture()
        // Relative completion times from the failure audit; all identities are synthetic.
        let ends = [0.34087225, 0.42634658, 0.59548608, 0.72512217, 0.87854454, 1.09597475, 1.23514558]
        var clock = 0.0, reads = 0, events: [StabilitySample] = []
        let result = try DisconnectStabilizer.wait(request: request, matching: false, read: {
            clock = ends[reads]; reads += 1; return peers
        }, safe: {}, now: { clock }, pause: { clock += $0 }, audit: { events.append($0) })
        XCTAssertEqual(result, peers); XCTAssertEqual(reads, 6); XCTAssertEqual(clock, 1.2, accuracy: 0.000001)
        XCTAssertEqual(events.filter { $0.outcome == "layoutDiffers" }.map(\.consecutive), [1,2,3,4,5,6])
        XCTAssertEqual(events.last?.outcome, "graceComplete")
        XCTAssertNoThrow(try DisconnectTopology.reconciliationTargets(request, observed: result, current: peers))
    }
    func testExactDeadlineAndLateSecondVoteAreRejectedButTimelyVoteAccepted() throws {
        let (request, _) = fixture(), peers = DisconnectTopology.peers(fixture().0)
        for end in [1.199, 1.2, 1.201] {
            var clock = 0.0, reads = 0
            let run = { try DisconnectStabilizer.wait(request: request, matching: true, read: {
                reads += 1; clock = reads == 1 ? 0.1 : end; return peers
            }, safe: {}, now: { clock }, pause: { clock += $0 }) }
            if end < 1.2 { XCTAssertEqual(try run(), peers) } else { XCTAssertThrowsError(try run()) }
        }
    }
    func testSlowInFlightReadCannotFallBackToEarlierQuorum() {
        let (request, peers) = fixture()
        var clock = 0.0, events: [StabilitySample] = []
        XCTAssertThrowsError(try DisconnectStabilizer.wait(request: request, matching: false, read: {
            clock += 0.41; return peers
        }, safe: {}, now: { clock }, pause: { clock += $0 }, audit: { events.append($0) }))
        XCTAssertEqual(events.last?.outcome, "deadlineExceeded")
        XCTAssertEqual(events.last?.consecutive, 2) // preserve diagnostics, not authority
    }
    func testConflictingLastSampleCannotReuseEarlierQuorum() {
        let (request, peers) = fixture(); var moved = peers; moved[1].x += 20
        var clock = 0.0, reads = 0, events: [StabilitySample] = []
        let ends = [0.4, 0.8, 1.1, 1.21]
        XCTAssertThrowsError(try DisconnectStabilizer.wait(request: request, matching: false, read: {
            clock = ends[reads]; reads += 1; return reads >= 3 ? moved : peers
        }, safe: {}, now: { clock }, pause: { clock += $0 }, audit: { events.append($0) }))
        XCTAssertEqual(events[2].consecutive, 1)
        XCTAssertFalse(events.contains { $0.outcome == "graceComplete" })
    }
    func testReadFailureAfterQuorumInvalidatesEarlierEvidence() {
        let (request, peers) = fixture(); var clock = 0.0, reads = 0, events: [StabilitySample] = []
        XCTAssertThrowsError(try DisconnectStabilizer.wait(request: request, matching: false, read: {
            reads += 1; clock += 0.4
            if reads >= 3 { throw OmniError.message("observer invalidated") }; return peers
        }, safe: {}, now: { clock }, pause: { clock += $0 }, audit: { events.append($0) }))
        XCTAssertFalse(events.contains { $0.outcome == "graceComplete" })
    }
    func testReconfigurationCallbackDuringReadRequiresNewPair() throws {
        let (request, _) = fixture(); let peers = DisconnectTopology.peers(request)
        let epoch = DisplayObservationEpoch(); var clock = 0.0, reads = 0, events: [StabilitySample] = []
        _ = try DisconnectStabilizer.wait(request: request, matching: true, read: {
            reads += 1; clock += 0.1
            if reads == 2 { epoch.invalidate() }; return peers
        }, safe: {}, state: { epoch.state() }, now: { clock }, pause: { clock += $0 }, audit: { events.append($0) })
        XCTAssertEqual(reads, 4); XCTAssertEqual(events[1].outcome, "observationInvalidated")
        XCTAssertEqual(events[2].consecutive, 1)
        XCTAssertNotEqual(events[1].generationBefore, events[1].generationAfter)
    }
    func testCallbackBetweenReadsCannotCombineEpochs() throws {
        let (request, _) = fixture(); let peers = DisconnectTopology.peers(request)
        let epoch = DisplayObservationEpoch(); var clock = 0.0, reads = 0, invalidated = false
        _ = try DisconnectStabilizer.wait(request: request, matching: true, read: {
            reads += 1; clock += 0.1; return peers
        }, safe: {}, state: { epoch.state() }, now: { clock }, pause: {
            clock += $0; if !invalidated { epoch.invalidate(); invalidated = true }
        })
        XCTAssertEqual(reads, 3)
    }
    func testCallbackOrPendingChangeDuringGraceRejectsEvenIdenticalGeometry() {
        for pending in [false, true] {
            let (request, peers) = fixture(); let epoch = DisplayObservationEpoch()
            var clock = 0.0, holding = false
            XCTAssertThrowsError(try DisconnectStabilizer.wait(request: request, matching: false, read: {
                clock += 0.1; return peers
            }, safe: {}, state: { epoch.state() }, now: { clock }, pause: {
                clock += $0
                if holding { if pending { epoch.changed(display: 1, beginning: true) } else { epoch.invalidate() } }
            }, audit: { if $0.outcome == "holdingReflowEvidence" { holding = true } }))
            XCTAssertTrue(holding)
        }
    }
    func testCancellationDuringGraceCannotReturnEvidence() {
        let (request, peers) = fixture(); var clock = 0.0, holding = false, cancelled = false
        XCTAssertThrowsError(try DisconnectStabilizer.wait(request: request, matching: false, read: {
            clock += 0.1; return peers
        }, safe: { if cancelled { throw OmniError.message("cancelled") } }, now: { clock }, pause: {
            clock += $0; if holding { cancelled = true }
        }, audit: { if $0.outcome == "holdingReflowEvidence" { holding = true } }))
        XCTAssertTrue(cancelled)
    }
    func testOversleptGraceCannotUseStaleEvidence() {
        let (request, peers) = fixture(); var clock = 0.0, holding = false, events: [StabilitySample] = []
        XCTAssertThrowsError(try DisconnectStabilizer.wait(request: request, matching: false, read: {
            clock += 0.1; return peers
        }, safe: {}, now: { clock }, pause: { clock += holding ? 0.4 : $0 }, audit: {
            events.append($0); if $0.outcome == "holdingReflowEvidence" { holding = true }
        }))
        XCTAssertEqual(events.last?.outcome, "staleEvidence")
    }
    func testLateUnsafeOrConflictingReadNeverAuthorizesEarlierEvidence() {
        let (request, peers) = fixture()
        var moved = peers; moved[1].x += 1
        var impostor = peers; impostor[1].serial += 1
        let missing = peers.filter { $0.id != request.keep }
        var added = peers; var extra = Display.samples(5)[4]; extra.main = false; added.append(extra)
        for changed in [moved, impostor, missing, added] {
            var clock = 0.0, reads = 0
            XCTAssertThrowsError(try DisconnectStabilizer.wait(request: request, matching: false, read: {
                reads += 1; clock = reads == 1 ? 0.4 : reads == 2 ? 0.8 : 1.21
                return reads == 3 ? changed : peers
            }, safe: {}, now: { clock }, pause: { clock += $0 }))
        }
    }
    func testTimelyIdentityOrNewScreenChangeAfterQuorumStillRejects() {
        let (request, peers) = fixture()
        var impostor = peers; impostor[1].serial += 1
        let missing = peers.filter { $0.id != request.keep }
        var added = peers; var extra = Display.samples(5)[4]; extra.main = false; added.append(extra)
        for changed in [impostor, missing, added] {
            var clock = 0.0, reads = 0
            XCTAssertThrowsError(try DisconnectStabilizer.wait(request: request, matching: false, read: {
                reads += 1; clock += 0.35; return reads == 3 ? changed : peers
            }, safe: {}, now: { clock }, pause: { clock += $0 }))
        }
    }
    func testGraceResultStillRequiresFreshCASForNewMovedOrLostScreens() throws {
        let (request, peers) = fixture(); var clock = 0.0
        let observed = try DisconnectStabilizer.wait(request: request, matching: false, read: {
            clock += 0.1; return peers
        }, safe: {}, now: { clock }, pause: { clock += $0 })
        var moved = peers; moved[1].x += 1
        var added = peers; var extra = Display.samples(5)[4]; extra.main = false; added.append(extra)
        for changed in [moved, added, peers.filter { $0.id != request.keep }] {
            XCTAssertThrowsError(try DisconnectTopology.reconciliationTargets(request, observed: observed, current: changed))
        }
    }

    func testDelayedReceiptCannotMakeOldObserverSampleFresh() {
        let (request, peers) = fixture(); var clock = 0.0, sampledAt = 0.0
        XCTAssertThrowsError(try DisconnectStabilizer.wait(request: request, matching: false, read: {
            sampledAt = clock + 0.01; clock += 0.3; return peers
        }, safe: {}, observationTime: { sampledAt }, now: { clock }, pause: { clock += $0 }))
    }
    func testGraceAgeUsesObserverTimestampInsteadOfReceiptTime() {
        let (request, peers) = fixture(); var clock = 0.0, sampledAt = 0.0, reads = 0
        // Two valid but old-at-boundary observations cannot be held through grace;
        // the next in-flight read is late and must reject, not reuse the old pair.
        XCTAssertThrowsError(try DisconnectStabilizer.wait(request: request, matching: false, read: {
            reads += 1
            if reads == 1 { clock = 0.9; sampledAt = 0.89 }
            else if reads == 2 { sampledAt = 1.04; clock = 1.09 }
            else { sampledAt = clock + 0.01; clock = 1.25 }
            return peers
        }, safe: {}, observationTime: { sampledAt }, now: { clock }, pause: { clock += $0 }))
        XCTAssertEqual(reads, 3)
    }
}
