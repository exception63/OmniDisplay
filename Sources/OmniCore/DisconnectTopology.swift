import Foundation

/// Only active peers matter after a disconnect. An absent target is expected;
/// neither its missing UUID nor a display's localized name is a topology change.
public enum DisconnectTopology {
    public static func peers(_ request: Request) -> [Display] { request.layoutSession?.temporary.displays ?? request.before.displays.filter { $0.active && $0.id != request.target } }
    public static func validateIdentities(_ request: Request, current: [Display]) throws {
        let expected = peers(request)
        guard !current.isEmpty, Set(current.map(\.id)).count == current.count,
              Set(current.map(\.displayID)).count == current.count,
              current.allSatisfy({ $0.active && !$0.mirrored && UUID(uuidString: $0.id) != nil }),
              Set(current.map(\.id)) == Set(expected.map(\.id)),
              current.contains(where: { $0.id == request.keep }),
              current.filter(\.main).count == 1 else { throw OmniError.message("活动屏幕身份、保留屏或镜像状态不符，停止协调。") }
        for saved in expected {
            guard let live = current.first(where: { $0.id == saved.id }),
                  live.vendor == saved.vendor, live.model == saved.model, live.serial == saved.serial,
                  live.builtin == saved.builtin else { throw OmniError.message("活动屏幕硬件身份变化，停止协调。") }
        }
    }
    /// Plan is bound to a full, stable observed set. Never plan a new/offline screen.
    public static func reconciliationTargets(_ request: Request, observed: [Display], current: [Display]) throws -> [Display] {
        try validateIdentities(request,current:observed)
        try validateIdentities(request,current:current)
        guard sameObservation(observed,current) else { throw OmniError.message("协调计划后出现并发调整。") }
        return peers(request).map { saved in
            var desired=saved
            desired.displayID=current.first(where: { $0.id == saved.id })!.displayID
            return desired
        }
    }
    public static func matches(_ request: Request, current: [Display]) -> Bool {
        if let session = request.layoutSession { return session.matchesTemporary(current) }
        guard (try? validateIdentities(request, current: current)) != nil,
              let anchor = peers(request).first(where: \.main),
              let origin = current.first(where: { $0.id == anchor.id }) else { return false }
        return peers(request).allSatisfy { saved in
            guard let live = current.first(where: { $0.id == saved.id }) else { return false }
            return live.main == saved.main && abs(live.rotation - saved.rotation) < 0.1 &&
                live.width == saved.width && live.height == saved.height &&
                live.pixelWidth == saved.pixelWidth && live.pixelHeight == saved.pixelHeight &&
                abs(live.refresh - saved.refresh) < 0.5 &&
                Int64(live.x) - Int64(origin.x) == Int64(saved.x) - Int64(anchor.x) &&
                Int64(live.y) - Int64(origin.y) == Int64(saved.y) - Int64(anchor.y)
        }
    }
    /// Exact observed geometry/IDs for compare-before-write; only names may vary.
    public static func sameObservation(_ lhs: [Display], _ rhs: [Display]) -> Bool {
        func normalized(_ values: [Display]) -> [Display] {
            values.map { d in var value=d; value.name=""; return value }.sorted { $0.id < $1.id }
        }
        return normalized(lhs) == normalized(rhs)
    }
}

/// Brief enumeration/layout transitions may settle, but cannot authorize a confirm.
/// Missing retained screen, new hardware, mirror or identity mismatch fail at once.
public struct DisconnectWatch {
    private var unsettledSince: TimeInterval?
    public init() {}
    public mutating func observe(_ current: [Display]?, request: Request, uptime: TimeInterval) throws -> Bool {
        if let current {
            let expected = DisconnectTopology.peers(request)
            guard current.contains(where: { $0.id == request.keep && $0.active }),
                  !current.contains(where: { $0.id == request.target && $0.active }),
                  Set(current.map(\.id)).isSubset(of: Set(expected.map(\.id))),
                  Set(current.map(\.id)).count == current.count,
                  Set(current.map(\.displayID)).count == current.count,
                  current.allSatisfy({ $0.active && !$0.mirrored && UUID(uuidString: $0.id) != nil }) else {
                throw OmniError.message("保留屏丢失、目标重新活动，或出现新屏/镜像/身份歧义。")
            }
            for live in current {
                guard let saved=expected.first(where: { $0.id == live.id }), saved.vendor == live.vendor,
                      saved.model == live.model, saved.serial == live.serial, saved.builtin == live.builtin else {
                    throw OmniError.message("活动屏硬件身份变化。")
                }
            }
            if DisconnectTopology.matches(request, current: current) { unsettledSince=nil; return true }
        }
        if unsettledSince == nil { unsettledSince=uptime }
        guard uptime - unsettledSince! < 1.2 else { throw OmniError.message("活动屏幕枚举或相对排列在1.2秒内未稳定，尝试回连目标。") }
        return false
    }
}

/// Wait for the requested physical angle, not merely for an unchanged wrong value.
/// Read/clock/pause are injectable so delayed completions can be replayed without I/O.
public struct RotationSettleDeadline: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}
public enum RotationWait {
    public static func wait(target: String, degrees: Double, timeout: Double,
                            read: () throws -> [Display],
                            now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                            pause: (TimeInterval) -> Void = { HelperEventLoop.wait($0) }) throws -> [Display] {
        guard timeout > 0, timeout <= 3, timeout.isFinite else { throw OmniError.message("旋转等待期限无效。") }
        let deadline=now()+timeout
        var previous: [Display]?, observed: Display?
        while now() < deadline {
            let current=try read()
            guard let targetDisplay=current.first(where: { $0.id == target && $0.active }) else { throw OmniError.message("旋转核验时目标身份已丢失。") }
            observed=targetDisplay
            // A subprocess read can consume the remaining budget. Its late
            // response must not turn an expired wait into success.
            if now() >= deadline { break }
            if abs(targetDisplay.rotation-degrees) < 0.1,
               let previous, DisconnectTopology.sameObservation(previous,current) { return current }
            previous=current
            pause(min(0.1,max(0,deadline-now())))
        }
        throw RotationSettleDeadline(message:"\(observed?.name ?? target)：旋转请求后\(timeout)秒仍未核实\(Int(degrees))°（最近读数\(observed.map { String($0.rotation) } ?? "未知")°），停止协调。")
    }
}
