import Foundation
import Darwin

/// One short-lived child process owns both mutation and rollback. No launch daemon or privileges.
public enum RecoveryEngine {
    /// Used only to diagnose orphaned receipts; never starts a recovery operation.
    public static func operationIsRunning(parent: URL) -> Bool {
        let fd = open(parent.appendingPathComponent("operation.lock").path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 { return true }
        flock(fd, LOCK_UN)
        return false
    }
    public static func run(directory: URL) throws {
        let request = try Files.read(Request.self, from: directory.appendingPathComponent("request.json"))
        guard request.version == 1, request.before.version == 1, request.office.version == 1,
              UUID(uuidString: request.nonce) != nil,
              request.timeout.isFinite, request.timeout >= (request.simulation ? 0.2 : 30), request.timeout <= 60 else {
            throw OmniError.message("恢复请求格式或超时时间无效。")
        }
        if request.operation == .remote { try LiveSwitchPolicy.validate(simulation: request.simulation) }
        if (request.operation == .disconnect || ModePlan.isMode(request.operation)) && !request.simulation { try LiveTestConsent.validate(request) }
        if request.operation == .inputSource { try InputControl.validateWrite(simulation: request.simulation, request: request) }
        let lockURL = directory.deletingLastPathComponent().appendingPathComponent("operation.lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw OmniError.message("不能创建操作锁。") }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC) // I/O worker must not inherit the recovery owner’s lock.
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw OmniError.message("另一项显示操作尚未结束。") }
        defer { flock(fd, LOCK_UN) }
        if !request.simulation && [.disconnect, .inputSource, .remoteMode, .officeMode, .rotate].contains(request.operation) {
            let claim = open(directory.appendingPathComponent("live-transaction.claim").path, O_CREAT | O_EXCL | O_WRONLY, S_IRUSR | S_IWUSR)
            guard claim >= 0 else { throw OmniError.message("这次真机测试已使用，拒绝重放。请重新确认新的单次测试。") }; close(claim)
        }
        var currentAudit: TransactionAudit?
        var phaseAudits: [String: TransactionAudit] = [:]
        func auditFor(_ phase: String) -> TransactionAudit? {
            if let existing = phaseAudits[phase] { return existing }
            do {
                let value = try TransactionAudit(directory: directory, nonce: request.nonce, phase: phase, role: "owner")
                phaseAudits[phase] = value; return value
            } catch { fputs("Owner audit unavailable: \(error.localizedDescription)\n", stderr); return nil }
        }
        currentAudit = auditFor("apply")
        currentAudit?.record("ownerStarted", request)
        defer { currentAudit?.record("ownerFinished", AuditDetail("operation lock is released on return")) }
        let backend = request.simulation ? nil : CoreGraphicsBackend(freshRead: request.operation == .disconnect ? {
            try FreshDisplayObserver.read(journal: currentAudit)
        } : nil)
        var history: [RecoveryEvent] = []
        func status(_ receipt: Receipt) throws {
            let phase = receipt.phase == .failed ? (currentAudit?.phase ?? "apply") : [.restoring, .restored].contains(receipt.phase) ? "restore" : [.awaitingConfirmation, .confirmed].contains(receipt.phase) ? "confirmation" : "apply"
            currentAudit = auditFor(phase)
            currentAudit?.record("ownerPhase", receipt)
            history.append(RecoveryEvent(receipt: receipt))
            // Preserve the triggering phase/reason when receipt.json advances.
            // Diagnostic persistence must not prevent physical recovery.
            try? Files.write(history, to: directory.appendingPathComponent("events.json"))
            try Files.write(receipt, to: directory.appendingPathComponent("receipt.json"))
        }
        func exists(_ marker: String) -> Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent(marker).path) }
        func recover(_ snapshot: Snapshot, reason: String) throws {
            // Recovery must still run if receipt persistence itself fails (e.g. disk full).
            try? status(Receipt(.restoring, reason))
            let warnings = backend?.restore(snapshot) ?? []
            if request.simulation { try Files.write(snapshot, to: directory.appendingPathComponent("simulated-restored.json")) }
            try status(Receipt(warnings.isEmpty ? .restored : .failed, warnings.isEmpty ? "\(reason) 已完成恢复。" : "\(reason) 已尝试恢复，需检查：\(warnings.joined(separator: "；"))"))
        }
        try status(Receipt(.ready, "独立恢复进程已就绪。"))
        let armExpiry = Date().addingTimeInterval(10)
        let armUptime = ProcessInfo.processInfo.systemUptime + 10
        while !exists("execute") {
            if exists("cancel") || Date() >= armExpiry || ProcessInfo.processInfo.systemUptime >= armUptime { try status(Receipt(.restored, "已取消，未修改显示设置。")); return }
            HelperEventLoop.wait(0.1)
        }
        if exists("cancel") { try status(Receipt(.restored, "已取消，未修改显示设置。")); return }
        if ModePlan.isMode(request.operation) { try ModeEngine.run(request:request,directory:directory,status:status);return }
        if request.operation == .inputSource {
            let plan = try InputChangePlan(request: request)
            if !request.simulation {
                let deadline = Date().addingTimeInterval(request.timeout)
                let expiry = ProcessInfo.processInfo.systemUptime + request.timeout
                func restoreInput(_ reason: String) {
                    try? status(Receipt(.restoring, reason + " 正在尝试恢复原输入。"))
                    do {
                        let result = try InputAttempt.run(directory: directory, restoring: true)
                        try? status(Receipt(result.verified ? .restored : .failed, result.verified ? reason + " " + result.message + " 请现场核对画面。" : reason + " 已发送恢复请求但未能读回。请用目标屏幕实体菜单选回 Mac 原输入。"))
                    } catch { try? status(Receipt(.failed, "\(reason) 原输入恢复未确认：\(error.localizedDescription) 请用目标屏幕实体菜单选回 Mac 原输入，不要重复切源。")) }
                }
                do {
                    try status(Receipt(.applying, "正在发送目标屏幕输入源请求；未确认将尝试恢复。", deadline: deadline))
                    let result = try InputAttempt.run(directory: directory, restoring: false, cancelled: { exists("cancel") || Date() >= deadline })
                    try status(Receipt(.awaitingConfirmation, result.message, deadline: deadline))
                    var nextTopologyCheck = Date.distantPast
                    while true {
                        if exists("cancel") || Date() >= deadline || ProcessInfo.processInfo.systemUptime >= expiry { restoreInput("已取消或倒计时结束。"); return }
                        if Date() >= nextTopologyCheck, let backend {
                            let current = try backend.list()
                            guard LayoutGuard.peersUnchanged(before: request.before.displays, current: current, target: plan.target),
                                  current.contains(where: { $0.id == request.keep && $0.active }),
                                  !current.contains(where: { $0.active && $0.mirrored }) else { throw OmniError.message("等待确认期间保留屏或其他屏幕拓扑变化。") }
                            nextTopologyCheck = Date().addingTimeInterval(0.5)
                        }
                        if exists("confirm") { try status(Receipt(.confirmed, "用户已确认目标画面；原输入与恢复记录已保留。")); return }
                        HelperEventLoop.wait(0.1)
                    }
                } catch { restoreInput("切源未完成：\(error.localizedDescription)") }
                return
            }
            let stateURL = directory.appendingPathComponent("simulated-inputs.json")
            var inputs: [String: UInt16] = [plan.target: plan.next]
            try Files.write(inputs, to: stateURL)
            let deadline = Date().addingTimeInterval(request.timeout)
            let expiry = ProcessInfo.processInfo.systemUptime + request.timeout
            try status(Receipt(.awaitingConfirmation, "模拟切源完成；超时或取消将恢复该屏原输入。", deadline: deadline))
            while true {
                if exists("cancel") || Date() >= deadline || ProcessInfo.processInfo.systemUptime >= expiry {
                    inputs = (try? Files.read([String: UInt16].self, from: stateURL)) ?? inputs
                    inputs[plan.target] = plan.previous
                    try Files.write(inputs, to: stateURL)
                    try status(Receipt(.restored, "已恢复目标屏幕原输入（模拟）。")); return
                }
                if exists("confirm") { try status(Receipt(.confirmed, "模拟输入源切换已确认。")); return }
                HelperEventLoop.wait(0.1)
            }
        }
        if request.operation == .connect || request.operation == .disconnect {
            if request.operation == .disconnect && !request.confirmedPhysical { throw OmniError.message("未确认实体保留屏幕，拒绝断开。") }
            guard let target = request.target else { throw OmniError.message("缺少目标屏幕。") }
            if let session = request.layoutSession {
                try session.validate(boot: request.simulation ? "simulation" : CoreGraphicsBackend.bootID)
                guard session.target == target else { throw OmniError.message("排列记录与操作目标不一致。") }
                if request.operation == .disconnect, session.original.displays != request.before.displays { throw OmniError.message("完整快照与断开请求不一致。") }
            }
            let plan = try SingleDisplayPlan.make(action: request.operation, target: target, displays: request.before.displays, retainedPhysical: request.keep)
            if request.operation == .connect {
                try status(Receipt(.applying, "正在连接目标屏幕…"))
                let warnings = backend?.connect(target, from: request.before, preserveLayout: request.preserveLayout ?? true, session: request.layoutSession) ?? []
                if request.simulation {
                    if let session = request.layoutSession {
                        guard session.peersMayRestore(request.before.displays.filter(\.active)) else { throw OmniError.message("模拟连接前排列已变化。") }
                        try Files.write(session.simulatedRestore(request.before.displays), to: directory.appendingPathComponent("simulated-displays.json"))
                    } else { try Files.write(plan.simulatedResult(), to: directory.appendingPathComponent("simulated-displays.json")) }
                }
                try status(Receipt(warnings.isEmpty ? .restored : .failed, warnings.isEmpty ? "目标屏幕已连接，已核对屏幕排列；应用窗口不搬回。" : warnings.joined(separator: "；")))
                return
            }
            if !request.simulation {
                let applyDeadline = Date().addingTimeInterval(10)
                func reconnect(_ reason: String) {
                    try? status(Receipt(.restoring, reason + " 正在回连目标屏幕。"))
                    do {
                        let result = try InputAttempt.run(directory: directory, restoring: true)
                        try? status(Receipt(result.verified ? .restored : .failed, reason + " " + result.message))
                    } catch { try? status(Receipt(.failed, "\(reason) 目标恢复未确认：\(error.localizedDescription) 请仅拔插目标屏幕视频线，不要重复断开。")) }
                }
                do {
                    try status(Receipt(.applying, "独立恢复进程已就绪，正在断开并核对保留屏排列。"))
                    let result = try InputAttempt.run(directory: directory, restoring: false, cancelled: { exists("cancel") || Date() >= applyDeadline })
                    guard result.verified else { throw OmniError.message(result.message) }
                    let deadline = Date().addingTimeInterval(request.timeout)
                    let expiry = ProcessInfo.processInfo.systemUptime + request.timeout
                    try status(Receipt(.awaitingConfirmation, "目标已断开。45秒内未确认将尝试回连；请核对保留屏。", deadline: deadline))
                    var watch = DisconnectWatch()
                    while true {
                        if exists("cancel") || Date() >= deadline || ProcessInfo.processInfo.systemUptime >= expiry { reconnect("取消或倒计时结束。"); return }
                        guard let retained = request.before.displays.first(where: { $0.id == request.keep }),
                              CoreGraphicsBackend.uuid(retained.displayID) == retained.id,
                              backend?.isActive(retained.displayID) == true else { throw OmniError.message("保留实体屏身份或活动状态丢失。") }
                        let current = try? backend?.list()
                        let settled = try watch.observe(current,request:request,uptime:ProcessInfo.processInfo.systemUptime)
                        if !settled, let current { try? Files.write(Snapshot(boot:CoreGraphicsBackend.bootID,displays:current),to:directory.appendingPathComponent("topology-at-recovery.json")) }
                        if settled && exists("confirm") { try status(Receipt(.confirmed, "用户已确认单屏断开；可在该屏菜单点击连接。")); return }
                        HelperEventLoop.wait(0.1)
                    }
                } catch { reconnect(error.localizedDescription) }
                return
            }
            // Simulation follows the same target-only cancel/timeout semantics.
            let deadline = Date().addingTimeInterval(request.timeout)
            let expiry = ProcessInfo.processInfo.systemUptime + request.timeout
            try Files.write(request.layoutSession?.simulatedDisconnected() ?? plan.simulatedResult(), to: directory.appendingPathComponent("simulated-displays.json"))
            try status(Receipt(.awaitingConfirmation, "模拟断开完成；未确认则只重新连接这块屏幕。", deadline: deadline))
            while true {
                let stateURL = directory.appendingPathComponent("simulated-displays.json")
                let state = try Files.read([Display].self, from: stateURL)
                let changed = request.layoutSession.map { !$0.matchesTemporary(state.filter(\.active)) } ?? false
                if changed || exists("cancel") || Date() >= deadline || ProcessInfo.processInfo.systemUptime >= expiry {
                    let stateURL = directory.appendingPathComponent("simulated-displays.json")
                    let current = try Files.read([Display].self, from: stateURL)
                    let recovered = try request.layoutSession?.simulatedRestore(current) ?? TargetRecovery.simulated(before: request.before.displays, current: current, target: target)
                    try Files.write(recovered, to: stateURL)
                    let complete = request.layoutSession?.matchesOriginal(recovered.filter(\.active)) ?? true
                    try status(Receipt(complete ? .restored : .failed, complete ? "已取消模拟断开，已恢复完整原排列。" : "已启用模拟目标；其他屏幕有并发变化，未覆盖排列。")); return
                }
                if exists("confirm") { try status(Receipt(.confirmed, "模拟断开已确认。")); return }
                HelperEventLoop.wait(0.1)
            }
        }
        if request.operation == .restore {
            try recover(request.office, reason: "恢复办公配置。")
            return
        }
        guard request.confirmedPhysical else { throw OmniError.message("未确认实体保留屏幕，拒绝操作。") }
        let plan = try RemotePlan.make(displays: request.before.displays, keep: request.keep)
        try plan.validate(current: request.before.displays)
        let deadline = Date().addingTimeInterval(request.timeout)
        try status(Receipt(.applying, "正在切换；未确认将尝试恢复。", deadline: deadline))
        do {
            try backend?.applyRemote(request)
            if request.simulation { try Files.write(plan, to: directory.appendingPathComponent("simulated-applied.json")) }
            if let backend {
                // Give WindowServer a short bounded settling period; mismatches cause rollback.
                var matched = false
                for _ in 0..<10 {
                    let live = try backend.list()
                    if live.filter(\.active).map(\.id) == [request.keep] { matched = true; break }
                    HelperEventLoop.wait(0.2)
                }
                guard matched else { throw OmniError.message("切换后的实际屏幕与预览不符。") }
            }
            try status(Receipt(.awaitingConfirmation, "请确认仍可看见并控制保留屏幕。", deadline: deadline))
            var lastTopologyCheck = Date.distantPast
            while true {
                // Cancellation and expired deadlines always beat confirmation.
                if exists("cancel") || Date() >= deadline {
                    try recover(request.before, reason: exists("cancel") ? "已取消切换。" : "倒计时结束。")
                    return
                }
                if let backend, Date().timeIntervalSince(lastTopologyCheck) > 0.5 {
                    let live = try backend.list()
                    guard live.filter(\.active).map(\.id) == [request.keep] else { throw OmniError.message("确认期间发生热插拔或活动屏幕变化。") }
                    lastTopologyCheck = Date()
                }
                if exists("confirm") { try status(Receipt(.confirmed, "远程单屏模式已确认。办公快照仍保留。")); return }
                HelperEventLoop.wait(0.1)
            }
        } catch {
            try recover(request.before, reason: "切换未完成：\(error.localizedDescription)")
        }
    }
}
