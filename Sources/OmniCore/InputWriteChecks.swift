import Foundation

/// Pure validation: intentionally separate from the immutable live-write gate.
/// Tests can exercise every refusal without contacting a physical display.
public enum InputWriteChecks {
    public static func target(request: Request, current: [Display], boot: String, restoring: Bool, now: Date = Date()) throws -> Display {
        let plan = try InputChangePlan(request: request)
        guard !request.simulation, request.before.boot == boot, boot != "unknown",
              UUID(uuidString: request.nonce) != nil,
              Set(current.map(\.id)).count == current.count,
              let target = current.first(where: { $0.id == plan.target }), target.active, !target.main, !target.builtin,
              current.contains(where: { $0.id == request.keep && $0.active }),
              !current.contains(where: { $0.active && $0.mirrored }) else { throw OmniError.message("目标、保留屏、系统会话或镜像状态变化，拒绝切源。") }
        if !restoring {
            let age = now.timeIntervalSince(request.before.date)
            guard age >= -2, age <= 60,
                  current.sorted(by: { $0.id < $1.id }) == request.before.displays.filter(\.active).sorted(by: { $0.id < $1.id }) else { throw OmniError.message("切源预览过期或拓扑变化，请重新预览。") }
        }
        return target
    }
    /// Return false only when recovery is already complete. A manual third input
    /// is never overwritten; unknown replies are not permission to send a Set.
    public static func requiresWrite(request: Request, target: Display, probe: InputProbe, restoring: Bool, now: Date = Date()) throws -> Bool {
        let plan = try InputChangePlan(request: request)
        guard probe.target == target.id, !probe.simulation, probe.state == .readable,
              let value = probe.current, let route = probe.route, route > 0,
              request.inputPortMappings?.filter({ $0.code == plan.previous || $0.code == plan.next }).allSatisfy({ $0.target == target.id && $0.route == route }) == true,
              now.timeIntervalSince(probe.date) >= -2, now.timeIntervalSince(probe.date) <= 5 else { throw OmniError.message("缺少新鲜且有效的目标输入读数/硬件路由，未发送切源命令。") }
        if restoring && value == plan.previous { return false }
        guard value == (restoring ? plan.next : plan.previous) else { throw OmniError.message("输入已被手动改变或与预览不符，不覆盖当前输入。") }
        return true
    }
}

public struct InputWriteResult: Codable {
    public var submitted: Bool
    public var verified: Bool
    public var message: String
    public init(submitted: Bool, verified: Bool, message: String) { self.submitted = submitted; self.verified = verified; self.message = message }
}
