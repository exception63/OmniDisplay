import XCTest
@testable import OmniCore

final class HelperEventLoopTests: XCTestCase {
    private func fixture(_ body: String) throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("helper-loop-test-" + UUID().uuidString)
        try ("#!/bin/sh\n" + body + "\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }
    func testTimersNotificationsAndMainQueueProgressWhileChildRuns() throws {
        XCTAssertTrue(Thread.isMainThread)
        let file = try fixture("exec /bin/sleep 0.20")
        defer { try? FileManager.default.removeItem(at: file) }
        let note = Notification.Name("OmniDisplay.HelperEventLoopTest")
        var ticks = 0, notified = false, mainQueueRan = false, notificationWasMain = false
        let token = NotificationCenter.default.addObserver(forName: note, object: nil, queue: .main) { _ in
            notified = true; notificationWasMain = Thread.isMainThread
        }
        defer { NotificationCenter.default.removeObserver(token) }
        let timer = Timer(timeInterval: 0.02, repeats: true) { _ in
            ticks += 1
            NotificationCenter.default.post(name: note, object: nil)
        }
        RunLoop.main.add(timer, forMode: .default); defer { timer.invalidate() }
        DispatchQueue.main.async { mainQueueRan = true }
        try BoundedChild.run(executable: file, arguments: [], timeout: 1)
        XCTAssertGreaterThanOrEqual(ticks, 3)
        XCTAssertTrue(notified); XCTAssertTrue(notificationWasMain); XCTAssertTrue(mainQueueRan)
    }
    func testMainThreadTimerCanCancelChildDuringWait() throws {
        let file = try fixture("exec /bin/sleep 5")
        defer { try? FileManager.default.removeItem(at: file) }
        var cancelled = false
        let timer = Timer(timeInterval: 0.04, repeats: false) { _ in cancelled = true }
        RunLoop.main.add(timer, forMode: .default); defer { timer.invalidate() }
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try BoundedChild.run(executable:file, arguments:[], timeout:1, cancelled:{cancelled}))
        XCTAssertTrue(cancelled)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime-start, 0.4)
    }
    func testFreshObserverTransportAlsoServicesMainEventsWhileWaiting() throws {
        let file = try fixture("exec /bin/sleep 5")
        defer { try? FileManager.default.removeItem(at: file) }
        var cancelled = false
        let timer = Timer(timeInterval: 0.04, repeats: false) { _ in cancelled = true }
        RunLoop.main.add(timer, forMode: .default); defer { timer.invalidate() }
        XCTAssertThrowsError(try FreshDisplayObserver.read(executable: file, cancelled: { cancelled }))
        XCTAssertTrue(cancelled)
    }
    func testRotationWaitReceivesTimerDrivenNewStateWithoutHardware() throws {
        var sample = Display.samples(2)
        let timer = Timer(timeInterval: 0.03, repeats: false) { _ in sample[1].rotation = 270 }
        RunLoop.main.add(timer, forMode: .default); defer { timer.invalidate() }
        let result = try RotationWait.wait(target: sample[1].id, degrees:270, timeout:1, read:{sample})
        XCTAssertEqual(result[1].rotation,270)
    }
    func testRecoveryOwnerStateMachineProcessesExecuteAndCancelTimers() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("helper-owner-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        let displays = Display.samples(2), snapshot = Snapshot(boot:"simulation", displays:Display.samples(2))
        let request = Request(operation:.disconnect, before:snapshot, office:snapshot, keep:displays[0].id,
                              confirmedPhysical:true, simulation:true, timeout:1, target:displays[1].id)
        let directory = parent.appendingPathComponent(request.nonce)
        try FileManager.default.createDirectory(at:directory, withIntermediateDirectories:true)
        try Files.write(request, to:directory.appendingPathComponent("request.json"))
        var sawReady = false, sawConfirmation = false
        let timer = Timer(timeInterval:0.02, repeats:true) { _ in
            guard let receipt = try? Files.read(Receipt.self, from:directory.appendingPathComponent("receipt.json")) else { return }
            if receipt.phase == .ready { sawReady = true; try? Files.marker("execute",in:directory) }
            if receipt.phase == .awaitingConfirmation { sawConfirmation = true; try? Files.marker("cancel",in:directory) }
        }
        RunLoop.main.add(timer, forMode:.default); defer { timer.invalidate() }
        let start = ProcessInfo.processInfo.systemUptime
        try RecoveryEngine.run(directory:directory)
        XCTAssertTrue(sawReady); XCTAssertTrue(sawConfirmation)
        XCTAssertEqual(try Files.read(Receipt.self,from:directory.appendingPathComponent("receipt.json")).phase, .restored)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime-start,1)
    }
}
