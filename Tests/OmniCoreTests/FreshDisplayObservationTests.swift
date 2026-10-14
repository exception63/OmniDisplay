import XCTest
import Darwin
@testable import OmniCore

final class FreshDisplayObservationTests: XCTestCase {
    private let child: Int32 = 1234567
    private func receipt() -> DisplayObservation {
        DisplayObservation(nonce: "new-read", pid: child, boot: "boot", started: 10.01,
                           completed: 10.08, generation: 0, displays: Display.samples(4))
    }
    private func validate(_ value: DisplayObservation, now: Double = 10.1) throws -> [Display] {
        try value.validate(nonce: "new-read", childPID: child, boot: "boot", launched: 10, now: now)
    }
    func testFreshReceiptAcceptsCompleteSample() throws {
        XCTAssertEqual(try validate(receipt()), Display.samples(4))
    }
    func testRepeatedOldCacheCannotMasqueradeAsNewObservation() {
        var old = receipt(); old.started = 9; old.completed = 9.9
        for _ in 0..<2 { XCTAssertThrowsError(try validate(old)) }
        old = receipt(); old.nonce = "previous-read"
        XCTAssertThrowsError(try validate(old))
    }
    func testRejectsWrongProcessBootLateAndImpossibleTimes() {
        var value = receipt(); value.pid = getpid()
        XCTAssertThrowsError(try validate(value))
        value = receipt(); value.boot = "another-boot"
        XCTAssertThrowsError(try validate(value))
        XCTAssertThrowsError(try validate(receipt(), now: 11.6))
        value = receipt(); value.completed = 10.2
        XCTAssertThrowsError(try validate(value))
        value = receipt(); value.started = .nan
        XCTAssertThrowsError(try validate(value))
    }
    func testIncompleteOrDuplicateIdentityRejected() {
        var value = receipt(); value.displays = []
        XCTAssertThrowsError(try validate(value))
        value = receipt(); value.displays[1].displayID = value.displays[0].displayID
        XCTAssertThrowsError(try validate(value))
        value = receipt(); value.displays[1].id = value.displays[0].id
        XCTAssertThrowsError(try validate(value))
    }
    func testBeginPendingAndLateEndRequireTwoNewSamples() {
        let epoch = DisplayObservationEpoch(); var stability = DisplayObservationStability()
        let sample = Display.samples(4)
        func observe() -> Bool { let s = epoch.state(); return stability.observe(sample, before:s, after:s) }
        XCTAssertFalse(observe())
        epoch.changed(display: 1, beginning: true)
        XCTAssertFalse(observe()); XCTAssertFalse(observe())
        epoch.changed(display: 2, beginning: true)
        epoch.changed(display: 1, beginning: false)
        XCTAssertFalse(observe()) // display 2 has not completed
        epoch.changed(display: 2, beginning: false)
        XCTAssertFalse(observe()); XCTAssertTrue(observe())
    }
    func testNotificationDuringSampleAndAppNoticeInvalidatePair() {
        let epoch = DisplayObservationEpoch(); var stability = DisplayObservationStability()
        let sample = Display.samples(2), before = epoch.state()
        epoch.invalidate()
        XCTAssertFalse(stability.observe(sample, before:before, after:epoch.state()))
        let current = epoch.state()
        XCTAssertFalse(stability.observe(sample, before:current, after:current))
        XCTAssertTrue(stability.observe(sample, before:current, after:current))
        epoch.changed(display: 1, beginning: false) // unmatched/late callback still invalidates
        let next = epoch.state()
        XCTAssertFalse(stability.observe(sample, before:next, after:next))
    }
    func testFreshSourceIsUsedAndFailureNeverFallsBackToLocalCGCache() throws {
        var samples = Display.samples(4), calls = 0
        let backend = CoreGraphicsBackend(freshRead: {
            calls += 1
            if calls == 3 { throw OmniError.message("observer died") }
            return samples
        })
        XCTAssertEqual(try backend.list()[1].rotation, 0)
        samples[1].rotation = 270
        XCTAssertEqual(try backend.list()[1].rotation, 270)
        XCTAssertThrowsError(try backend.list())
        XCTAssertEqual(calls, 3)
    }
    func testLateCorrectReadDoesNotExtendRotationDeadline() {
        var time = 0.0; var sample = Display.samples(2); sample[1].rotation = 270
        XCTAssertThrowsError(try RotationWait.wait(target: sample[1].id, degrees:270, timeout:2.5,
            read: { time += 1.4; return sample }, now:{time}, pause:{time += $0}))
    }
    func testObserverPumpServicesTimerInsteadOfSleepingThroughEvent() {
        var fired = false
        let timer = Timer(timeInterval: 0.01, repeats: false) { _ in fired = true }
        RunLoop.current.add(timer, forMode: .default)
        FreshDisplayObserver.pumpEvents(for: 0.04)
        timer.invalidate()
        XCTAssertTrue(fired)
    }
    private func fixture(_ contents: String) throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("observer-test-" + UUID().uuidString)
        try ("#!/bin/sh\n" + contents + "\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }
    func testObserverDeathAndMalformedOutputRejectWithoutCacheFallback() throws {
        for source in ["exit 7", "echo not-json"] {
            let file = try fixture(source); defer { try? FileManager.default.removeItem(at: file) }
            XCTAssertThrowsError(try FreshDisplayObserver.read(executable: file))
        }
    }
    func testFinalReadBudgetCapsTransportAndRejectsInvalidBudget() throws {
        let file = try fixture("exec /bin/sleep 5")
        defer { try? FileManager.default.removeItem(at: file) }
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try FreshDisplayObserver.read(executable: file, timeout: 0.06))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.5)
        for budget in [0.0, -1, Double.infinity, Double.nan, 1.3] {
            XCTAssertThrowsError(try FreshDisplayObserver.read(executable: file, timeout: budget))
        }
    }
    func testObserverProcessTimeoutAndCancellationAreBounded() throws {
        let file = try fixture("exec /bin/sleep 5")
        defer { try? FileManager.default.removeItem(at: file) }
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try FreshDisplayObserver.read(executable: file))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
        let cancelStart = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try FreshDisplayObserver.read(executable: file, cancelled: {
            ProcessInfo.processInfo.systemUptime - cancelStart > 0.04
        }))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - cancelStart, 0.5)
    }
}
