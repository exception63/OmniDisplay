import Foundation

public struct ModeStep: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable { case enable, disable, arrange }
    public var action: Action
    public var target: String?
    public var before: [Display]
    public var after: [Display]
}
public struct ModePlan: Sendable {
    public let steps: [ModeStep]
    public let desired: [Display]
    public static func isMode(_ operation: Operation) -> Bool { [.remoteMode,.officeMode,.rotate].contains(operation) }
    public static func identities(_ current: [Display], within office: [Display]) -> Bool {
        !current.isEmpty && Set(current.map(\.id)).count == current.count && Set(current.map(\.displayID)).count == current.count &&
        current.filter(\.main).count == 1 && current.allSatisfy { d in
            d.active && !d.mirrored && office.contains { $0.id == d.id && $0.vendor == d.vendor && $0.model == d.model && $0.serial == d.serial && $0.builtin == d.builtin }
        }
    }
    public static func make(_ request: Request) throws -> ModePlan {
        if request.operation == .rotate { return try RotationPlan.make(request) }
        let office=request.office.displays, entry=request.before.displays
        guard isMode(request.operation), request.before.version == 1, request.office.version == 1,
              request.before.boot == request.office.boot, request.before.boot != "unknown", request.confirmedPhysical,
              request.target == request.keep, office.count <= 24, !office.isEmpty,
              Set(office.map(\.id)).count == office.count, office.filter(\.main).count == 1,
              office.allSatisfy({ UUID(uuidString:$0.id) != nil && $0.active && !$0.mirrored && $0.width > 0 && $0.height > 0 && $0.width <= 131072 && $0.height <= 131072 && $0.refresh.isFinite && [0.0,90,180,270].contains($0.rotation) }),
              TemporaryLayout.validArrangement(office), identities(entry,within:office), office.contains(where:{$0.id==request.keep}) else { throw OmniError.message("模式基线、入口状态或保留屏身份不明确。") }
        if request.operation == .officeMode { return try transition(from:entry,to:office,office:office) }
        guard !entry.contains(where:{$0.builtin && $0.id != request.keep}),
              office.filter({$0.id != request.keep}).allSatisfy({ d in d.vendor != 0 && d.model != 0 && office.filter{$0.vendor==d.vendor && $0.model==d.model && $0.serial==d.serial}.count == 1 }) else { throw OmniError.message("远程模式不能关闭内置屏或恢复身份不唯一的屏幕。") }
        var keep=office.first{$0.id==request.keep}!;keep.x=0;keep.y=0;keep.main=true
        return try transition(from:entry,to:[keep],office:office)
    }
    private static func compact(_ values: [Display], primary: String, office: [Display]) throws -> [Display] {
        let sorted=values.sorted { a,b in
            let x=office.first{$0.id==a.id}!,y=office.first{$0.id==b.id}!
            return x.x == y.x ? (x.y == y.y ? x.id < y.id : x.y < y.y) : x.x < y.x
        }
        guard let index=sorted.firstIndex(where:{$0.id==primary}) else { throw OmniError.message("保留主屏缺失。") }
        var x = -sorted.prefix(index).reduce(Int64(0)) { $0+Int64($1.width) }
        return try sorted.map { original in
            var d=original;guard let origin=Int32(exactly:x) else { throw OmniError.message("屏幕排列溢出。") }
            d.x=origin;d.y=0;d.main=d.id==primary;d.active=true;x+=Int64(d.width);return d
        }
    }
    /// Enables all required screens before any disable. Only planned managed extras
    /// are disabled; unknown/new hardware never appears in a transition.
    public static func transition(from entry: [Display], to desired: [Display], office: [Display]) throws -> ModePlan {
        guard identities(entry,within:office), identities(desired,within:office), let primary=desired.first(where:\.main) else { throw OmniError.message("模式入口或目标身份无效。") }
        var state=entry, steps:[ModeStep]=[]
        func add(_ action: ModeStep.Action,_ target:String?,_ next:[Display]) {
            steps.append(ModeStep(action:action,target:target,before:state,after:next));state=next
        }
        for saved in desired.sorted(by:{$0.id < $1.id}) where !state.contains(where:{$0.id==saved.id}) {
            var enabled=saved;enabled.main=false
            let next=try compact(state+[enabled],primary:state.first(where:\.main)!.id,office:office)
            add(.enable,saved.id,next)
        }
        if state.first(where:\.main)?.id != primary.id {
            let anchor=state.first{$0.id==primary.id}!
            let translated=try state.map { d -> Display in
                var next=d
                guard let x=Int32(exactly:Int64(d.x)-Int64(anchor.x)),let y=Int32(exactly:Int64(d.y)-Int64(anchor.y)) else { throw OmniError.message("主屏切换位置溢出。") }
                next.x=x;next.y=y;next.main=d.id==primary.id;return next
            }
            add(.arrange,nil,translated)
        }
        let wanted=Set(desired.map(\.id))
        while state.contains(where:{!wanted.contains($0.id)}) {
            var choice:(String,[Display])?
            for d in state.sorted(by:{$0.id < $1.id}) where !wanted.contains(d.id) && !d.main && !d.builtin {
                if let next=try? TemporaryLayout.plan(state,removing:d.id) { choice=(d.id,next);break }
            }
            guard let choice else { throw OmniError.message("不能安全规划该多屏过渡；未开始切换。") }
            add(.disable,choice.0,choice.1)
        }
        if !TemporaryLayout.matches(desired,state) { add(.arrange,nil,desired) }
        return ModePlan(steps:steps,desired:desired)
    }
    public func recognizes(_ current:[Display], entry:[Display]) -> Bool {
        TemporaryLayout.matches(entry,current) || steps.contains { TemporaryLayout.matches($0.after,current) }
    }
    public static func status(current:[Display], office:Snapshot?) -> String {
        guard let office, identities(current,within:office.displays) else { return "部分状态 · 请核对屏幕" }
        if TemporaryLayout.matches(office.displays,current) { return "办公室 · 完整排列已核对" }
        if current.count == 1, let d=current.first, var expected=office.displays.first(where:{$0.id==d.id}) {
            expected.x=0;expected.y=0;expected.main=true
            if TemporaryLayout.matches([expected],current) { return "远程 · 仅 \(d.name)" }
        }
        return "部分状态 · \(current.count)/\(office.displays.count) 屏活动"
    }
    public static func failureSummary(current: [Display], office: Snapshot?, boot: String, fresh: Bool) -> String {
        if fresh, let office, office.boot == boot, boot != "unknown", TemporaryLayout.matches(office.displays, current) {
            return "最近读取符合办公室完整排列；上次事务未完成核验，历史结果仍保留。"
        }
        return "上次事务未完成核验；请核对当前画面，历史结果不代表当前连接状态。"
    }
}
