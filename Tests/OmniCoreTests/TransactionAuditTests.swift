import XCTest
@testable import OmniCore

final class TransactionAuditTests: XCTestCase {
    func directory() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    func records(_ file: URL) throws -> [[String: Any]] {
        try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
    }
    func testRestoreAndNewWritersCannotOverwriteApplyEvidence() throws {
        let d = try directory(); defer { try? FileManager.default.removeItem(at: d) }
        let apply = try TransactionAudit(directory: d, nonce: d.lastPathComponent, phase: "apply", role: "worker")
        XCTAssertTrue(apply.record("sample", Display.samples(4)))
        let bytes = try Data(contentsOf: apply.file)
        for phase in ["apply", "restore", "confirmation"] {
            let writer = try TransactionAudit(directory: d, nonce: d.lastPathComponent, phase: phase, role: "worker")
            XCTAssertNotEqual(apply.file, writer.file); XCTAssertTrue(writer.record("result", AuditDetail("other writer")))
        }
        XCTAssertEqual(try Data(contentsOf: apply.file), bytes)
        XCTAssertTrue(apply.record("result", AuditDetail("failed")))
        XCTAssertTrue(try Data(contentsOf: apply.file).starts(with: bytes))
        let values = try records(apply.file)
        XCTAssertEqual(values.count, 2); XCTAssertEqual(values[1]["sequence"] as? Int, 2)
        XCTAssertEqual(values[0]["phase"] as? String, "apply")
        XCTAssertEqual(values[0]["nonce"] as? String, d.lastPathComponent)
    }
    func testFailureDoesNotTruncateEarlierLines() throws {
        let d = try directory(); defer { try? FileManager.default.removeItem(at: d) }
        let writer = try TransactionAudit(directory: d, nonce: d.lastPathComponent, phase: "restore", role: "observer")
        XCTAssertTrue(writer.record("first", AuditDetail("retained")))
        let data = try Data(contentsOf: writer.file)
        XCTAssertFalse(writer.record("bad", Double.nan)); XCTAssertNotNil(writer.failure)
        XCTAssertEqual(try Data(contentsOf: writer.file), data)
    }
    func testAllChangedDisplayFieldsArePreservedIncludingMissingAndDuplicateIDs() {
        let original = Display.samples(2); var changed = original
        changed[0].x += 30; changed[0].rotation = 270; changed[0].displayID = 100; changed[0].refresh = 59.9
        let delta = DisplayDifferences.between(original, changed)
        XCTAssertEqual(Set(delta.map(\.field)), Set(["x", "rotation", "displayID", "refresh"]))
        XCTAssertTrue(DisplayDifferences.between(original, [original[0]]).contains { $0.id == original[1].id && $0.field == "identityCount" })
        XCTAssertTrue(DisplayDifferences.between(original, [original[0], original[0]]).contains { $0.id == original[0].id && $0.field == "identityCount" })
    }
    func testFailedObservationTransportIsAuditedWithoutFallback() throws {
        let d = try directory(); defer { try? FileManager.default.removeItem(at: d) }
        let writer = try TransactionAudit(directory: d, nonce: d.lastPathComponent, phase: "apply", role: "worker")
        XCTAssertThrowsError(try FreshDisplayObserver.read(executable: URL(fileURLWithPath: "/usr/bin/false"), journal: writer))
        let kinds = try records(writer.file).compactMap { $0["event"] as? String }
        XCTAssertEqual(kinds, ["freshReadStarted", "observerLaunched", "observerExited", "freshReadFailed"])
    }
}

final class ObservationTraceTests: XCTestCase {
    func testCollectorKeepsEveryRawSampleAndEpochDifference() throws {
        var time = 0.0, calls = 0, epoch: UInt64 = 0, trace: [ObserverSample] = []
        let displays = Display.samples(2)
        let result = try DisplayObservationCollector.collect(nonce: "test", pid: 99, boot: "simulation", started: 0,
            read: { calls += 1; time += 0.01; if calls == 2 { epoch += 1 }; return displays },
            state: { (epoch, false) }, now: { time }, pause: { time += $0 }, audit: { trace.append($0) })
        XCTAssertEqual(result.displays, displays); XCTAssertEqual(trace.count, 4)
        XCTAssertEqual(trace[1].generationBefore, 0); XCTAssertEqual(trace[1].generationAfter, 1)
        XCTAssertTrue(trace.allSatisfy { $0.displays == displays && $0.deadline == 0.7 })
        XCTAssertEqual(trace.last?.outcome, "stable")
    }
    func testCollectorRejectsCorrectButLateRawRead() {
        var time = 0.0, trace: [ObserverSample] = []
        XCTAssertThrowsError(try DisplayObservationCollector.collect(nonce: "test", pid: 99, boot: "simulation", started: 0,
            read: { time += 0.4; return Display.samples(2) }, state: { (0, false) }, now: { time }, pause: { time += $0 }, audit: { trace.append($0) }))
        XCTAssertEqual(trace.count, 2); XCTAssertEqual(trace.last?.outcome, "deadlineExceeded")
    }
    func testCollectorPersistsPendingEpochUntilTimeout() {
        var time = 0.0, trace: [ObserverSample] = []
        XCTAssertThrowsError(try DisplayObservationCollector.collect(nonce: "test", pid: 99, boot: "simulation", started: 0,
            read: { time += 0.01; return Display.samples(2) }, state: { (12, true) }, now: { time }, pause: { time += $0 }, audit: { trace.append($0) }))
        XCTAssertGreaterThan(trace.count, 10); XCTAssertTrue(trace.allSatisfy { $0.pendingBefore && $0.pendingAfter })
    }
    func testCollectorReadFailureIsNotHidden() {
        var trace: [ObserverSample] = []
        XCTAssertThrowsError(try DisplayObservationCollector.collect(nonce: "test", pid: 99, boot: "simulation", started: 0,
            read: { throw OmniError.message("fixture read failure") }, state: { (0, false) }, now: { 0 }, pause: { _ in }, audit: { trace.append($0) }))
        XCTAssertEqual(trace.count, 1); XCTAssertEqual(trace[0].error, "fixture read failure"); XCTAssertNil(trace[0].displays)
    }
}
