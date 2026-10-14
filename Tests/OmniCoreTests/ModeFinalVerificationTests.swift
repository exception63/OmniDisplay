import XCTest
@testable import OmniCore

final class ModeFinalVerificationTests: XCTestCase {
    func office() -> [Display] { ModeStabilityTests().office() }
    func testRecordedLateSecondObservationStillFailsOriginalDeadline() {
        let expected = office()
        let offsets = [0.7588, 2.0402, 2.272189, 2.516459]
        var clock = 0.0, index = 0, events: [AuditDetail] = []
        XCTAssertThrowsError(try ModeStability.wait(expected: expected, office: expected, matching: true, enabling: false,
            mayProceed: { true }, read: {
                clock = max(clock, offsets[index]); index += 1
                if index <= 2 { throw ObservationNotSettled() }
                return expected
            }, now: { clock }, pause: { clock += $0 }, audit: { events.append($0) })) { XCTAssertTrue($0 is ModeSettleDeadline) }
        XCTAssertEqual(index, 4)
        XCTAssertEqual(events.filter { $0.message == "lateSampleRejected" }.count, 1)
        XCTAssertFalse(events.contains { $0.message == "verified" })
    }
    func testNewVerificationRequiresTwoEntirelyNewReads() throws {
        let expected = office(); var clock = 2.516459, count = 0
        let result = try ModeFinalVerification.wait(expected: expected, office: expected, boot: "test-boot", mayProceed: { true }, read: { budget in
            XCTAssertLessThanOrEqual(budget, 1.2); XCTAssertGreaterThan(budget, 0)
            count += 1; clock += 0.08
            return Snapshot(boot: "test-boot", displays: expected)
        }, now: { clock }, pause: { clock += $0 })
        XCTAssertEqual(result, expected); XCTAssertEqual(count, 2)
    }
    func testUnstableSampleResetsFinalPair() throws {
        let expected = office(); var clock = 0.0, count = 0
        _ = try ModeFinalVerification.wait(expected: expected, office: expected, boot: "test-boot", mayProceed: { true }, read: { _ in
            count += 1; clock += 0.05
            if count == 2 { throw ObservationNotSettled() }
            return Snapshot(boot: "test-boot", displays: expected)
        }, now: { clock }, pause: { clock += $0 })
        XCTAssertEqual(count, 4)
    }
    func testFinalDeadlineIsBoundedAndBudgetShrinks() {
        let expected = office(); var clock = 0.0, budgets: [Double] = []
        XCTAssertThrowsError(try ModeFinalVerification.wait(expected: expected, office: expected, boot: "test-boot", mayProceed: { true }, read: { budget in
            budgets.append(budget); clock += min(0.7, budget); throw ObservationNotSettled()
        }, now: { clock }, pause: { clock += $0 })) { XCTAssertTrue($0 is ModeSettleDeadline) }
        XCTAssertLessThanOrEqual(clock, 2.6); XCTAssertLessThan(budgets.last!, 1.2)
    }
    func testFinalLateCorrectPairStillRejected() {
        let expected = office(); var clock = 0.0
        XCTAssertThrowsError(try ModeFinalVerification.wait(expected: expected, office: expected, boot: "test-boot", mayProceed: { true }, read: { _ in
            clock += 1.3; return Snapshot(boot: "test-boot", displays: expected)
        }, now: { clock }, pause: { clock += $0 })) { XCTAssertTrue($0 is ModeSettleDeadline) }
    }
    func testFinalRejectsIdentityGeometryMissingNewAndBootChangesImmediately() {
        let expected = office()
        var identity = expected; identity[1].serial += 1
        var geometry = expected; geometry[1].y += 17
        var unknown = expected; unknown[1].id = UUID().uuidString
        for (boot, live) in [("test-boot", identity), ("test-boot", geometry), ("test-boot", unknown), ("test-boot", Array(expected.prefix(3))), ("new-boot", expected)] {
            var count = 0
            XCTAssertThrowsError(try ModeFinalVerification.wait(expected: expected, office: expected, boot: "test-boot", mayProceed: { true }, read: { _ in
                count += 1; return Snapshot(boot: boot, displays: live)
            }, pause: { _ in })) { XCTAssertFalse($0 is ModeSettleDeadline) }
            XCTAssertEqual(count, 1)
        }
    }
    func testWorkerDeadlineCannotBeRelabeledAsSettleDeadline() {
        let expected = office(); var clock = 0.0, proceeding = true
        XCTAssertThrowsError(try ModeStability.wait(expected: expected, office: expected, matching: true, enabling: false,
            mayProceed: { proceeding }, read: { clock = 3; proceeding = false; throw ObservationNotSettled() },
            now: { clock }, pause: { clock += $0 })) { XCTAssertFalse($0 is ModeSettleDeadline) }
    }
    func testFinalTransportErrorDoesNotRetry() {
        let expected = office(); var count = 0
        XCTAssertThrowsError(try ModeFinalVerification.wait(expected: expected, office: expected, boot: "test-boot", mayProceed: { true }, read: { _ in
            count += 1; throw OmniError.message("invalid transport")
        }))
        XCTAssertEqual(count, 1)
    }
    func testFinalLosingOwnerOrBootGuardStopsBeforeReading() {
        let expected = office(); var count = 0
        XCTAssertThrowsError(try ModeFinalVerification.wait(expected: expected, office: expected, boot: "test-boot", mayProceed: { false }, read: { _ in
            count += 1; return Snapshot(boot: "test-boot", displays: expected)
        }))
        XCTAssertEqual(count, 0)
    }
    func testFailureReceiptKindSurvivesCodableAndOldReceiptCannotAuthorizeFinalStage() throws {
        let failure = ModeStepFailure(nonce: "test", message: "timeout", kind: .postCommitSettleDeadline, stepIndex: 3)
        let decoded = try JSONDecoder().decode(ModeStepFailure.self, from: JSONEncoder().encode(failure))
        XCTAssertEqual(decoded.kind, .postCommitSettleDeadline); XCTAssertEqual(decoded.stepIndex, 3)
        let legacy = try JSONDecoder().decode(ModeStepFailure.self, from: Data("{\"nonce\":\"test\",\"message\":\"timeout\"}".utf8))
        XCTAssertNil(legacy.kind); XCTAssertNil(legacy.stepIndex)
    }
    func testHistoricalFailurePresentationNeedsFreshSameBootExactLayout() {
        let expected = office(), snapshot = Snapshot(boot: "test-boot", displays: office())
        XCTAssertTrue(ModePlan.failureSummary(current: expected, office: snapshot, boot: "test-boot", fresh: true).contains("最近读取符合"))
        for (boot, fresh, live) in [("other", true, expected), ("test-boot", false, expected), ("test-boot", true, Array(expected.prefix(3)))] {
            let text = ModePlan.failureSummary(current: live, office: snapshot, boot: boot, fresh: fresh)
            XCTAssertFalse(text.contains("最近读取符合")); XCTAssertTrue(text.contains("历史结果"))
        }
    }
}
