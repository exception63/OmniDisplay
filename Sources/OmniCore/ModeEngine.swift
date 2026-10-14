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
public enum ModeEngine {
    public static func run(request:Request,directory:URL,status:(Receipt)throws->Void) throws {
        let plan=try ModePlan.make(request)
        // The independent owner receives sleep/wake even if the UI was killed.
        let center=NSWorkspace.shared.notificationCenter
        let observers=[NSWorkspace.willSleepNotification,NSWorkspace.didWakeNotification].map { name in
            center.addObserver(forName:name,object:nil,queue:nil) { _ in try? Files.marker("cancel",in:directory) }
        }
        defer { observers.forEach(center.removeObserver) }
        let simulated=directory.appendingPathComponent("simulated-displays.json")
        if request.simulation { try Files.write(request.before.displays,to:simulated) }
        func exists(_ key:String)->Bool { FileManager.default.fileExists(atPath:directory.appendingPathComponent(key).path) }
        func read() throws -> [Display] { request.simulation ? try Files.read([Display].self,from:simulated) : try FreshDisplayObserver.read() }
        var sequence=0
        func execute(_ work:ModeWork) throws {
            if request.simulation {
                let live=try read()
                if let step=work.step {
                    guard TemporaryLayout.matches(step.before,live) else { throw OmniError.message("模拟模式并发变化。") }
                    if exists(work.restoring ? "simulation-fail-rollback" : "simulation-fail-step-\(work.index)") { throw OmniError.message("模拟注入步骤失败。") }
                    try Files.write(step.after,to:simulated)
                } else if let target=work.rescue {
                    if exists("simulation-fail-rollback") { throw OmniError.message("模拟回滚失败。") }
                    if !live.contains(where:{$0.id==target}), var saved=request.before.displays.first(where:{$0.id==target}) { saved.main=false;try Files.write(live+[saved],to:simulated) }
                }
                HelperEventLoop.wait(0.05);return
            }
            let file="mode-work-\(sequence).json";sequence+=1
            try Files.write(work,to:directory.appendingPathComponent(file))
            try BoundedChild.run(executable:URL(fileURLWithPath:CommandLine.arguments[0]),arguments:["--mode-step",directory.path,file],timeout:10,cancelled:{ !work.restoring && exists("cancel") })
        }
        func rollback(_ reason:String) {
            try? status(Receipt(.restoring,reason+" 正在恢复本次切换前状态。"))
            do {
                let current=try read()
                if plan.recognizes(current,entry:request.before.displays) {
                    let rollback=try ModePlan.transition(from:current,to:request.before.displays,office:request.office.displays)
                    for (i,step) in rollback.steps.enumerated() { try execute(ModeWork(step:step,rescue:nil,restoring:true,rollbackFrom:current,index:i)) }
                } else {
                    // Unknown manual/hotplug geometry: never replay or disable it.
                    // Enable missing entry screens only, then report partial recovery.
                    for d in request.before.displays where !current.contains(where:{$0.id==d.id}) {
                        try execute(ModeWork(step:nil,rescue:d.id,restoring:true,rollbackFrom:nil,index:0))
                    }
                }
                let complete=TemporaryLayout.matches(request.before.displays,try read())
                try status(Receipt(complete ? .restored : .failed, complete ? reason+" 已核对恢复本次入口状态。" : reason+" 部分恢复：已尝试启用入口屏幕；现场变化未覆盖，请检查实体屏。"))
            } catch { try? status(Receipt(.failed,reason+" 恢复未完成："+error.localizedDescription+" 请用实体OSD/单独视频线恢复。")) }
        }
        do {
            guard TemporaryLayout.matches(request.before.displays,try read()) else { throw OmniError.message("模式入口已变化，未执行计划。") }
            if plan.steps.isEmpty { try status(Receipt(.confirmed,"当前硬件已符合所选模式，未重复写入。"));return }
            try status(Receipt(.applying,"正在串行切换模式；完整办公室基线已保留。"))
            let applyEnd=ProcessInfo.processInfo.systemUptime+90, applyDate=Date().addingTimeInterval(90)
            for (i,step) in plan.steps.enumerated() {
                guard !exists("cancel"), ProcessInfo.processInfo.systemUptime < applyEnd, Date() < applyDate else { throw OmniError.message("模式切换取消或过期。") }
                try status(Receipt(.applying,"模式步骤 \(i+1)/\(plan.steps.count)：\(step.action == .enable ? "连接" : step.action == .disable ? "断开" : "恢复排列")"))
                try execute(ModeWork(step:step,rescue:nil,restoring:false,rollbackFrom:nil,index:i))
                guard TemporaryLayout.matches(step.after,try read()) else { throw OmniError.message("模式步骤核验失败。") }
                try Files.write(Snapshot(boot:request.before.boot,displays:try read()),to:directory.appendingPathComponent("mode-checkpoint.json"))
            }
            let deadline=Date().addingTimeInterval(request.timeout),end=ProcessInfo.processInfo.systemUptime+request.timeout
            try status(Receipt(.awaitingConfirmation,"模式已核验；请确认保留屏画面，未确认恢复本次入口状态。",deadline:deadline))
            while true {
                if exists("cancel") || Date()>=deadline || ProcessInfo.processInfo.systemUptime>=end { rollback("已取消或确认倒计时结束。");return }
                guard TemporaryLayout.matches(plan.desired,try read()) else { throw OmniError.message("确认期间屏幕状态变化。") }
                if exists("confirm") { try status(Receipt(.confirmed,"模式已由用户确认；办公室完整基线仍保留。"));return }
                HelperEventLoop.wait(0.1)
            }
        } catch { rollback(error.localizedDescription) }
    }
    public static func worker(directory:URL,file:String) throws {
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
            guard work.restoring, work.step==nil, request.before.displays.contains(where:{$0.id==rescue}) else { throw OmniError.message("救援范围无效。") }
            _ = backend.reconnectOnly(request.office,target:rescue);return
        }
        guard let step=work.step, work.index>=0 else { throw OmniError.message("模式步骤缺失。") }
        let allowed:[ModeStep]
        if work.restoring {
            guard let from=work.rollbackFrom, plan.recognizes(from,entry:request.before.displays) else { throw OmniError.message("回滚入口不属于本次事务。") }
            allowed=try ModePlan.transition(from:from,to:request.before.displays,office:request.office.displays).steps
        } else { allowed=plan.steps }
        guard work.index < allowed.count, allowed[work.index]==step else { throw OmniError.message("模式步骤不属于用户确认计划。") }
        _ = try backend.applyModeStep(step,request:request,restoring:work.restoring,mayProceed:proceed)
    }
}
