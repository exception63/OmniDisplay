import Foundation

public enum DisconnectWriteChecks {
    public static func validate(_ request: Request, current: [Display], boot: String) throws -> (target: Display, retained: Display) {
        try LiveTestConsent.validate(request)
        guard request.operation == .disconnect, request.confirmedPhysical, request.before.boot == boot, boot != "unknown", let targetID = request.target else { throw OmniError.message("断开请求、保留实体屏或系统会话无效。") }
        _ = try SingleDisplayPlan.make(action: .disconnect, target: targetID, displays: current, retainedPhysical: request.keep)
        guard current.sorted(by: { $0.id < $1.id }) == request.before.displays.filter(\.active).sorted(by: { $0.id < $1.id }),
              let target = current.first(where: { $0.id == targetID && !$0.main && !$0.builtin }),
              let retained = current.first(where: { $0.id == request.keep && $0.active }),
              UUID(uuidString: target.id) != nil, UUID(uuidString: retained.id) != nil,
              target.vendor != 0, target.model != 0,
              request.before.displays.filter({ $0.vendor == target.vendor && $0.model == target.model && $0.serial == target.serial }).count == 1 else { throw OmniError.message("主屏/内置屏受保护，或拓扑/恢复身份不唯一，拒绝断开。") }
        return (target,retained)
    }
}
