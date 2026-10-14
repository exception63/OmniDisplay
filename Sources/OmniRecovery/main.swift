import Foundation
import OmniCore

let arguments = CommandLine.arguments
// CLI entry points execute on the main thread, without NSApplication.run().
// Every multi-step wait in the owner/worker uses HelperEventLoop to service
// this thread's CFRunLoop. Private calls keep their existing thread affinity;
// their brief synchronous bodies are not moved to an unverified background queue.
if arguments.count == 2 && arguments[1] == "--inspect-fresh" {
    do {
        var result: DisplayObservation?
        _ = try FreshDisplayObserver.read(audit: { result = $0 })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(result), as: UTF8.self))
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else if [3, 5].contains(arguments.count) && arguments[1] == "--observe-displays" {
    var journal: TransactionAudit?
    do {
        if arguments.count == 5 {
            let directory = URL(fileURLWithPath: arguments[3])
            do { journal = try TransactionAudit(directory: directory, nonce: directory.lastPathComponent, phase: arguments[4], role: "observer") }
            catch { fputs("Observer audit unavailable: \(error.localizedDescription)\n", stderr) }
        }
        let report = try FreshDisplayObserver.collect(nonce: arguments[2], journal: journal)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(report), as: UTF8.self))
    } catch { journal?.record("observerFailed", AuditDetail(error.localizedDescription)); fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else if arguments.contains("--inspect") {
    do {
        let backend = CoreGraphicsBackend()
        struct Report: Codable { let system: String; let boot: String; let privateAPIAvailable: Bool; let displays: [Display] }
        let report = Report(system: ProcessInfo.processInfo.operatingSystemVersionString, boot: CoreGraphicsBackend.bootID, privateAPIAvailable: backend.canDisconnect, displays: try backend.list())
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(report), as: UTF8.self))
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else if arguments.count == 3 && arguments[1] == "--diagnose-input" {
    do {
        let displays = try CoreGraphicsBackend().list()
        guard let display = displays.first(where: { $0.id == arguments[2].uppercased() }) else { throw OmniError.message("未找到活动目标 UUID。") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(InputReadDiagnostic.run(display)), as: UTF8.self))
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else if arguments.count == 3 && arguments[1] == "--probe-input" {
    do {
        let displays = try CoreGraphicsBackend().list()
        guard let display = displays.first(where: { $0.id == arguments[2].uppercased() }) else { throw OmniError.message("未找到活动目标 UUID。") }
        let report = InputControl.probe(display)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(report), as: UTF8.self))
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else if arguments.count == 4 && arguments[1] == "--mode-step" {
    do { try ModeEngine.worker(directory:URL(fileURLWithPath:arguments[2]),file:arguments[3]) }
    catch { fputs("\(error.localizedDescription)\n",stderr);exit(1) }
} else if arguments.count == 4 && arguments[1] == "--input-attempt" && ["apply", "restore"].contains(arguments[3]) {
    do { try InputAttempt.worker(directory: URL(fileURLWithPath: arguments[2]), restoring: arguments[3] == "restore") }
    catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else if arguments.count == 3 && arguments[1] == "--reconnect-only" {
    do {
        let snapshot = try Files.read(Snapshot.self, from: URL(fileURLWithPath: arguments[2]))
        let backend = CoreGraphicsBackend()
        print("BEFORE", try backend.list().map { "\($0.name):\($0.displayID):\($0.active)" })
        for line in backend.reconnectOnly(snapshot) { print(line) }
        HelperEventLoop.wait(1)
        print("AFTER", try backend.list().map { "\($0.name):\($0.displayID):\($0.active)" })
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else if arguments.count == 3 && arguments[1] == "--transaction" {
    let dir = URL(fileURLWithPath: arguments[2], isDirectory: true)
    do { try RecoveryEngine.run(directory: dir) }
    catch {
        try? Files.write(Receipt(.failed, error.localizedDescription), to: dir.appendingPathComponent("receipt.json"))
        fputs("\(error.localizedDescription)\n", stderr); exit(1)
    }
} else {
    print("OmniRecovery --inspect | --transaction <app-created-request-directory>")
}
