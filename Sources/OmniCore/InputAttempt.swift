import Foundation
import Darwin

/// Keeps the recovery owner responsive even if a private IOAV call stalls.
/// The worker can be killed independently; the parent retains the operation lock.
public enum BoundedChild {
    public static func run(executable: URL, arguments: [String], timeout: Double, cancelled: () -> Bool = { false }) throws {
        guard timeout.isFinite, timeout > 0, timeout <= 10 else { throw OmniError.message("I/O 超时时间无效。") }
        let child = Process(); child.executableURL = executable; child.arguments = arguments
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        try child.run()
        let expiry = ProcessInfo.processInfo.systemUptime + timeout
        while child.isRunning {
            if cancelled() || ProcessInfo.processInfo.systemUptime >= expiry {
                child.terminate()
                // No unbounded waitUntilExit on a driver call. SIGKILL targets only
                // this child; a kernel/WindowServer fault still cannot be guaranteed recoverable.
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
                throw OmniError.message("显示器 I/O 已取消或超时；未确认写入是否生效，需恢复核对。")
            }
            HelperEventLoop.wait(0.025)
        }
        guard child.terminationStatus == 0 else { throw OmniError.message("显示器 I/O 进程失败。") }
    }
}
public enum InputAttempt {
    public static func resultURL(_ dir: URL, restoring: Bool) -> URL { dir.appendingPathComponent(restoring ? "input-restore-result.json" : "input-apply-result.json") }
    public static func run(directory: URL, restoring: Bool, cancelled: @escaping () -> Bool = { false }) throws -> InputWriteResult {
        let request = try Files.read(Request.self, from: directory.appendingPathComponent("request.json"))
        try LiveTestConsent.validate(request, restoring: restoring)
        if restoring && !FileManager.default.fileExists(atPath: directory.appendingPathComponent("input-mutation.intent").path) {
            return InputWriteResult(submitted: false, verified: true, message: "尚未进入写入，无需恢复。")
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        do {
            try BoundedChild.run(executable: executable, arguments: ["--input-attempt", directory.path, restoring ? "restore" : "apply"], timeout: request.operation == .disconnect ? 10 : 6, cancelled: cancelled)
        } catch {
            if let result = try? Files.read(InputWriteResult.self, from: resultURL(directory, restoring: restoring)) { throw OmniError.message(result.message) }
            throw error
        }
        return try Files.read(InputWriteResult.self, from: resultURL(directory, restoring: restoring))
    }
    public static func worker(directory: URL, restoring: Bool) throws {
        // Validate the request-specific confirmation before any hardware access.
        let request = try Files.read(Request.self, from: directory.appendingPathComponent("request.json"))
        try LiveTestConsent.validate(request, restoring: restoring)
        let receipt = try Files.read(Receipt.self, from: directory.appendingPathComponent("receipt.json"))
        guard !request.simulation, [.inputSource, .disconnect].contains(request.operation), directory.lastPathComponent == request.nonce,
              request.before.boot == CoreGraphicsBackend.bootID,
              (restoring || Date().timeIntervalSince(request.before.date) < 90),
              FileManager.default.fileExists(atPath: directory.appendingPathComponent("execute").path),
              (restoring ? [.applying, .awaitingConfirmation, .restoring].contains(receipt.phase) : receipt.phase == .applying),
              RecoveryEngine.operationIsRunning(parent: directory.deletingLastPathComponent()) else { throw OmniError.message("显示器写入缺少有效 helper 会话与执行握手。") }
        let claim = directory.appendingPathComponent(restoring ? "input-restore.claim" : "input-apply.claim")
        let fd = open(claim.path, O_CREAT | O_EXCL | O_WRONLY, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw OmniError.message("本次请求已执行，拒绝重放。") }; close(fd)
        let deadline = Date().addingTimeInterval(request.operation == .disconnect ? 8 : 5)
        let diagnostics: TransactionAudit?
        do { diagnostics = try TransactionAudit(directory: directory, nonce: request.nonce, phase: restoring ? "restore" : "apply", role: "worker") }
        catch {
            if !restoring { throw error }
            fputs("恢复审计初始化失败，仍执行恢复：\(error.localizedDescription)\n", stderr)
            diagnostics = nil
        }
        diagnostics?.record("request", request)
        diagnostics?.record("workerStarted", AuditDetail("", ["deadlineUnix": String(deadline.timeIntervalSince1970), "budgetSeconds": request.operation == .disconnect ? "8" : "5"]))
        defer { diagnostics?.record("workerFinished", AuditDetail()) }
        do {
            let mayProceed = { Date() < deadline && (restoring || !FileManager.default.fileExists(atPath: directory.appendingPathComponent("cancel").path)) && RecoveryEngine.operationIsRunning(parent: directory.deletingLastPathComponent()) }
            let willMutate = { if !restoring { try Files.marker("input-mutation.intent", in: directory) } }
            let audit: (String) -> Void = { message in diagnostics?.record("writeDetail", AuditDetail(message)) }
            var sampleCompleted: Double?
            let backend = CoreGraphicsBackend(freshRead: request.operation == .disconnect ? {
                sampleCompleted = nil
                return try FreshDisplayObserver.read(cancelled: { !mayProceed() }, journal: diagnostics,
                                                     audit: { sampleCompleted = $0.completed })
            } : nil, freshObservationTime: { sampleCompleted }, diagnostics: diagnostics)
            let result: InputWriteResult
            if request.operation == .disconnect {
                result = restoring ? try backend.recoverDisconnected(request) : try backend.disconnect(request, mayProceed: mayProceed, willMutate: willMutate, audit:audit)
            } else { result = try backend.changeInput(request, restoring: restoring, mayProceed: mayProceed, willMutate: willMutate) }
            diagnostics?.record("workerResult", result)
            try Files.write(result, to: resultURL(directory, restoring: restoring))
        } catch {
            diagnostics?.record("workerError", AuditDetail(error.localizedDescription, ["mutationIntentExists": String(FileManager.default.fileExists(atPath: directory.appendingPathComponent("input-mutation.intent").path)), "submissionStatus": "unknownAfterError"]))
            try? Files.write(InputWriteResult(submitted: false, verified: false, message: error.localizedDescription), to: resultURL(directory, restoring: restoring)); throw error
        }
    }
}
