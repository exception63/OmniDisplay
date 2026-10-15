import Foundation
import AppKit
import Darwin

public struct ModeWork: Codable {
    public var step: ModeStep?
    public var rescue: String?
    public var restoring: Bool
    public var rollbackFrom: [Display]?
    public var index: Int
}
public struct ModeStepFailure: Codable {
    public enum Kind: String, Codable { case postCommitSettleDeadline }
    public var nonce: String
    public var message: String
    public var kind: Kind?
    public var stepIndex: Int?
}
public enum ModeEngine {
    public static func run(request:Request,directory:URL,status:(Receipt)throws->Void) throws {
        let plan=try ModePlan.make(request)
        // The independent owner receives sleep/wake even if the UI was killed.
        // Simulation does not attach to the user's desktop or power session.
        let center = request.simulation ? nil : NSWorkspace.shared.notificationCenter
        let observers = center.map { center in
            [NSWorkspace.willSleepNotification,NSWorkspace.didWakeNotification].map { name in
                center.addObserver(forName:name,object:nil,queue:nil) { _ in try? Files.marker("cancel",in:directory) }
            }
        } ?? []
        defer { if let center { observers.forEach(center.removeObserver) } }
        let simulated=directory.appendingPathComponent("simulated-displays.json")
        if request.simulation { try Files.write(request.before.displays,to:simulated) }
        func exists(_ key:String)->Bool { FileManager.default.fileExists(atPath:directory.appendingPathComponent(key).path) }
        func read() throws -> [Display] { request.simulation ? try Files.read([Display].self,from:simulated) : try FreshDisplayObserver.read() }
        var sequence=0
        func execute(_ work:ModeWork) throws {
            if request.simulation {
                let traceURL=directory.appendingPathComponent("simulated-mode-work.json")
                var trace=(try? Files.read([ModeWork].self,from:traceURL)) ?? []
                trace.append(work);try Files.write(trace,to:traceURL)
                let live=try read()
                if let step=work.step {
                    guard TemporaryLayout.matches(step.before,live) else { throw OmniError.message("模拟模式并发变化。") }
                    if exists(work.restoring ? "simulation-fail-rollback" : "simulation-fail-step-\(work.index)") { throw OmniError.message("模拟注入步骤失败。") }
                    if request.operation == .rotate, !work.restoring, exists("simulation-rotation-intermediate") {
                        var intermediate=step.before
                        if let i=intermediate.firstIndex(where:{$0.id==request.target}), let rotated=step.after.first(where:{$0.id==request.target}) {
                            let original=intermediate[i];intermediate[i]=rotated;intermediate[i].x=original.x;intermediate[i].y=original.y
                        }
                        try Files.write(intermediate,to:simulated)
                        throw OmniError.message("模拟旋转完成但排列前失败。")
                    }
                    try Files.write(step.after,to:simulated)
                    if step.action == .arrange, exists(work.restoring ? "simulation-postcommit-rollback" : "simulation-postcommit-apply") {
                        throw ModePostCommitDeadline()
                    }
                } else if let target=work.rescue {
                    if exists("simulation-fail-rollback") { throw OmniError.message("模拟回滚失败。") }
                    if !live.contains(where:{$0.id==target}), var saved=(request.operation == .officeMode ? request.office : request.before).displays.first(where:{$0.id==target}) { saved.main=false;try Files.write(live+[saved],to:simulated) }
                }
                HelperEventLoop.wait(0.05);return
            }
            let file="mode-work-\(sequence).json";sequence+=1
            try Files.write(work,to:directory.appendingPathComponent(file))
            do {
                try BoundedChild.run(executable:URL(fileURLWithPath:CommandLine.arguments[0]),arguments:["--mode-step",directory.path,file],timeout:10,cancelled:{ !work.restoring && exists("cancel") })
            } catch {
                if let failure = try? Files.read(ModeStepFailure.self, from: directory.appendingPathComponent(file + ".result.json")), failure.nonce == request.nonce {
                    if failure.kind == .postCommitSettleDeadline, failure.stepIndex == work.index, work.step?.action == .arrange {
                        throw ModePostCommitDeadline()
                    }
                    throw OmniError.message(failure.message)
                }
                throw error
            }
        }
        func finishAfterDeadline(expected: [Display], reason: String) {
            let audit = try? TransactionAudit(directory: directory, nonce: request.nonce, phase: "restore", role: "owner")
            audit?.record("finalVerificationStarted", AuditDetail("已提交排列的原步骤核验超时；仅重新读取，不再写入。"))
            try? status(Receipt(.restoring, reason + " 原步骤核验超时；正在只读核对最终排列，不再调整屏幕。"))
            do {
                var samples = 0
                _ = try ModeFinalVerification.wait(expected: expected, office: request.office.displays, boot: request.before.boot,
                    mayProceed: { request.simulation || (CoreGraphicsBackend.bootID == request.before.boot && RecoveryEngine.operationIsRunning(parent: directory.deletingLastPathComponent())) },
                    read: { remaining in
                        samples += 1
                        if request.simulation {
                            try Files.write(samples, to: directory.appendingPathComponent("simulated-final-read-count.json"))
                            if exists("simulation-final-unstable") { HelperEventLoop.wait(min(0.1, remaining)); throw ObservationNotSettled() }
                            var live = try read()
                            if exists("simulation-final-layout") { live[0].y += 17 }
                            if exists("simulation-final-identity") { live[0].serial += 1 }
                            return Snapshot(boot: exists("simulation-final-boot") ? "other-boot" : request.before.boot, displays: live)
                        }
                        let live = try FreshDisplayObserver.read(cancelled: { CoreGraphicsBackend.bootID != request.before.boot }, journal: audit, timeout: remaining)
                        return Snapshot(boot: CoreGraphicsBackend.bootID, displays: live)
                    }, audit: { audit?.record("finalVerificationSample", $0) })
                audit?.record("finalVerificationSucceeded", AuditDetail("两次新的独立读数核对完成。"))
                try status(Receipt(.restored, reason + " 原步骤核验超时；随后只读双重核验确认完整目标排列已恢复。未追加显示写入。"))
            } catch {
                audit?.record("finalVerificationFailed", AuditDetail(error.localizedDescription))
                try? status(Receipt(.failed, reason + " 排列已提交，但未完成最终核验：" + error.localizedDescription + " 已停止调整；请先核对当前画面，有异常再用实体OSD/单独视频线恢复。"))
            }
        }
        func preserveOffice(_ reason: String, completeMissing: Bool) {
            try? status(Receipt(.restoring, reason + " 办公室恢复只连接屏幕，不退回单屏。"))
            var failures: [String] = []
            if completeMissing {
                for d in request.office.displays {
                    do {
                        let current = try read()
                        if current.contains(where: { $0.id == d.id }) { continue }
                        try? status(Receipt(.restoring, "补连 \(d.name)；已连接屏幕保持启用。"))
                        try execute(ModeWork(step: nil, rescue: d.id, restoring: true, rollbackFrom: nil, index: 0))
                    } catch { failures.append(d.name + "：" + error.localizedDescription) }
                }
            }
            do {
                let current = try read()
                let missing = request.office.displays.filter { saved in !current.contains { $0.id == saved.id } }
                let complete = TemporaryLayout.matches(request.office.displays, current)
                let detail = missing.isEmpty ? "管理屏幕均已连接；原排列尚未完全核验。" : "仍未连接：" + missing.map(\.name).joined(separator: "、") + "。"
                try status(Receipt(complete ? .restored : .failed, complete ? reason + " 办公室完整排列已核验，已连接屏幕保持启用。" : reason + " 部分恢复：" + detail + "已连接屏幕保持启用，不会再次断开。请核对画面；未覆盖未知布局。" + failures.joined(separator: "；")))
            } catch { try? status(Receipt(.failed, reason + " 已停止进一步排列，未关闭已连接屏幕。当前状态未能读取，请用实体OSD/单独视频线检查。")) }
        }
        func rollback(_ reason:String) {
            if request.operation == .officeMode { preserveOffice(reason, completeMissing: !exists("cancel")); return }
            try? status(Receipt(.restoring,reason+" 正在恢复本次切换前状态。"))
            do {
                let current=try read()
                if request.operation == .rotate ? RotationPlan.recognizes(current,request:request,desired:plan.desired) : plan.recognizes(current,entry:request.before.displays) {
                    let rollback = request.operation == .rotate ? ModePlan(steps: TemporaryLayout.matches(current,request.before.displays) ? [] : [ModeStep(action:.arrange,target:request.target,before:current,after:request.before.displays)], desired:request.before.displays) : try ModePlan.transition(from:current,to:request.before.displays,office:request.office.displays)
                    for (i,step) in rollback.steps.enumerated() {
                        do { try execute(ModeWork(step:step,rescue:nil,restoring:true,rollbackFrom:current,index:i)) }
                        catch is ModePostCommitDeadline where i == rollback.steps.count-1 && step.action == .arrange && TemporaryLayout.matches(request.before.displays, step.after) {
                            finishAfterDeadline(expected: request.before.displays, reason: reason); return
                        }
                    }
                } else {
                    // Unknown manual/hotplug geometry: never replay or disable it.
                    // Enable missing entry screens only, then report partial recovery.
                    for d in request.before.displays where !current.contains(where:{$0.id==d.id}) {
                        try execute(ModeWork(step:nil,rescue:d.id,restoring:true,rollbackFrom:nil,index:0))
                    }
                }
                let complete=TemporaryLayout.matches(request.before.displays,try read())
                try status(Receipt(complete ? .restored : .failed, complete ? reason+" 已核对恢复本次入口状态。" : reason+" 部分恢复：已尝试启用入口屏幕；现场变化未覆盖，请检查实体屏。"))
            } catch { try? status(Receipt(.failed,reason+" 恢复尚未核验："+error.localizedDescription+" 请先核对当前画面，有异常再用实体OSD/单独视频线恢复。")) }
        }
        do {
            guard TemporaryLayout.matches(request.before.displays,try read()) else { throw OmniError.message("模式入口已变化，未执行计划。") }
            if plan.steps.isEmpty { try status(Receipt(.confirmed,"当前硬件已符合所选模式，未重复写入。"));return }
            try status(Receipt(.applying,"正在串行切换模式；完整办公室基线已保留。"))
            let applyEnd=ProcessInfo.processInfo.systemUptime+90, applyDate=Date().addingTimeInterval(90)
            for (i,step) in plan.steps.enumerated() {
                guard !exists("cancel"), ProcessInfo.processInfo.systemUptime < applyEnd, Date() < applyDate else { throw OmniError.message("模式切换取消或过期。") }
                let targetName = request.office.displays.first { $0.id == step.target }?.name ?? "完整办公室排列"
                try status(Receipt(.applying,"模式步骤 \(i+1)/\(plan.steps.count)：\(step.action == .enable ? "连接" : step.action == .disable ? "断开" : "恢复排列") · \(targetName)；目标 \(step.after.count)/\(request.office.displays.count) 屏活动"))
                do { try execute(ModeWork(step:step,rescue:nil,restoring:false,rollbackFrom:nil,index:i)) }
                catch is ModePostCommitDeadline where request.operation == .rotate {
                    // A new bounded pair after the committed step; still requires user confirmation.
                    _ = try ModeFinalVerification.wait(expected:plan.desired,office:request.office.displays,boot:request.before.boot,
                        mayProceed:{ !exists("cancel") },read:{ remaining in
                            if request.simulation {
                                if exists("simulation-final-unstable") { throw ObservationNotSettled() }
                                var live = try read()
                                if exists("simulation-final-layout") { live[0].y += 17 }
                                if exists("simulation-final-identity") { live[0].serial += 1 }
                                return Snapshot(boot:exists("simulation-final-boot") ? "other-boot" : request.before.boot,displays:live)
                            }
                            return Snapshot(boot:CoreGraphicsBackend.bootID,displays:try FreshDisplayObserver.read(cancelled:{exists("cancel")},timeout:remaining))
                        })
                }
                catch is ModePostCommitDeadline where request.operation == .officeMode && i == plan.steps.count-1 && step.action == .arrange && TemporaryLayout.matches(request.office.displays, step.after) {
                    finishAfterDeadline(expected: request.office.displays, reason: "办公室恢复。"); return
                }
                guard TemporaryLayout.matches(step.after,try read()) else { throw OmniError.message("模式步骤核验失败。") }
                try Files.write(Snapshot(boot:request.before.boot,displays:try read()),to:directory.appendingPathComponent("mode-checkpoint.json"))
            }
            let deadline=Date().addingTimeInterval(request.timeout),end=ProcessInfo.processInfo.systemUptime+request.timeout
            try status(Receipt(.awaitingConfirmation,request.operation == .officeMode ? "办公室已核验；请检查全部屏幕。未确认或取消都不会关闭已连接屏幕。" : "模式已核验；请确认保留屏画面，未确认恢复本次入口状态。",deadline:deadline))
            while true {
                if exists("cancel") || Date()>=deadline || ProcessInfo.processInfo.systemUptime>=end { rollback("已取消或确认倒计时结束。");return }
                guard TemporaryLayout.matches(plan.desired,try read()) else { throw OmniError.message("确认期间屏幕状态变化。") }
                if exists("confirm") {
                    if request.operation == .rotate {
                        // Baseline failures must not unexpectedly undo a user-confirmed visible rotation.
                        do { try RotationBaselineCommit.commit(request:request,desired:plan.desired,directory:directory) }
                        catch { try status(Receipt(.failed,"方向已保留，但基线未更新："+error.localizedDescription));return }
                    }
                    try status(Receipt(.confirmed,request.operation == .rotate ? "方向已保留，办公室排列已更新。" : "模式已由用户确认；办公室完整基线仍保留。"));return
                }
                HelperEventLoop.wait(0.1)
            }
        } catch { rollback(error.localizedDescription) }
    }
    public static func worker(directory:URL,file:String) throws {
        guard file.hasPrefix("mode-work-"), file.hasSuffix(".json"), !file.contains("/"), !file.contains("..") else { throw OmniError.message("模式步骤路径无效。") }
        do { try performWorker(directory: directory, file: file) }
        catch {
            let work = try? Files.read(ModeWork.self, from: directory.appendingPathComponent(file))
            try? Files.write(ModeStepFailure(nonce: directory.lastPathComponent, message: error.localizedDescription,
                kind: error is ModePostCommitDeadline ? .postCommitSettleDeadline : nil, stepIndex: work?.index), to: directory.appendingPathComponent(file + ".result.json"))
            let restoring = work?.restoring == true
            if let audit = try? TransactionAudit(directory: directory, nonce: directory.lastPathComponent, phase: restoring ? "restore" : "apply", role: "worker") {
                audit.record("modeStepFailed", AuditDetail(error.localizedDescription, ["file": file]))
            }
            throw error
        }
    }
    private static func performWorker(directory:URL,file:String) throws {
        guard file.hasPrefix("mode-work-"), file.hasSuffix(".json"), !file.contains("/"), !file.contains("..") else { throw OmniError.message("模式步骤路径无效。") }
        let request=try Files.read(Request.self,from:directory.appendingPathComponent("request.json"))
        let work=try Files.read(ModeWork.self,from:directory.appendingPathComponent(file))
        try LiveTestConsent.validate(request,restoring:work.restoring)
        let plan=try ModePlan.make(request)
        let phase=try Files.read(Receipt.self,from:directory.appendingPathComponent("receipt.json")).phase
        guard !request.simulation, directory.lastPathComponent==request.nonce, request.before.boot==CoreGraphicsBackend.bootID,
              RecoveryEngine.operationIsRunning(parent:directory.deletingLastPathComponent()),
              FileManager.default.fileExists(atPath:directory.appendingPathComponent("execute").path),
              phase == (work.restoring ? .restoring : .applying) else { throw OmniError.message("模式步骤缺少独立helper握手。") }
        let fd=open(directory.appendingPathComponent(file+".claim").path,O_CREAT|O_EXCL|O_WRONLY,S_IRUSR|S_IWUSR)
        guard fd>=0 else { throw OmniError.message("模式步骤已执行。") };close(fd)
        let end=ProcessInfo.processInfo.systemUptime+8
        let proceed={ ProcessInfo.processInfo.systemUptime < end && RecoveryEngine.operationIsRunning(parent:directory.deletingLastPathComponent()) && (work.restoring || !FileManager.default.fileExists(atPath:directory.appendingPathComponent("cancel").path)) }
        let diagnostics:TransactionAudit?
        if work.restoring { diagnostics=try? TransactionAudit(directory:directory,nonce:request.nonce,phase:"restore",role:"worker") }
        else { diagnostics=try TransactionAudit(directory:directory,nonce:request.nonce,phase:"apply",role:"worker") }
        diagnostics?.record("modeStepStarted",work)
        defer { diagnostics?.record("modeStepFinished",work) }
        let backend=CoreGraphicsBackend(freshRead:{try FreshDisplayObserver.read(cancelled:{!proceed()},journal:diagnostics)},diagnostics:diagnostics)
        if let rescue=work.rescue {
            guard work.restoring, work.step==nil, (request.operation == .officeMode ? request.office : request.before).displays.contains(where:{$0.id==rescue}) else { throw OmniError.message("救援范围无效。") }
            _ = backend.reconnectOnly(request.office,target:rescue);return
        }
        guard let step=work.step, work.index>=0 else { throw OmniError.message("模式步骤缺失。") }
        let allowed:[ModeStep]
        if work.restoring {
            guard request.operation != .officeMode else { throw OmniError.message("办公室恢复不允许回滚禁用计划。") }
            guard let from=work.rollbackFrom, (request.operation == .rotate ? RotationPlan.recognizes(from,request:request,desired:plan.desired) : plan.recognizes(from,entry:request.before.displays)) else { throw OmniError.message("回滚入口不属于本次事务。") }
            allowed = request.operation == .rotate ? [ModeStep(action:.arrange,target:request.target,before:from,after:request.before.displays)] : try ModePlan.transition(from:from,to:request.before.displays,office:request.office.displays).steps
        } else { allowed=plan.steps }
        guard work.index < allowed.count, allowed[work.index]==step else { throw OmniError.message("模式步骤不属于用户确认计划。") }
        _ = try backend.applyModeStep(step,request:request,restoring:work.restoring,mayProceed:proceed)
    }
}
