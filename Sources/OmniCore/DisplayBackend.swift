import Foundation
import AppKit
import CoreGraphics
import Darwin
import OmniRotation
import OmniDDC

// API shape reviewed against aspace (MIT), pinned source and license in References/aspace.
// Runtime resolution avoids a hard link to Apple's unsupported private symbol.
public protocol DisplayBackend {
    var canDisconnect: Bool { get }
    func list() throws -> [Display]
    func applyRemote(_ request: Request) throws
    func restore(_ snapshot: Snapshot) -> [String]
}

public final class CoreGraphicsBackend: DisplayBackend {
    typealias EnableFunction = @convention(c) (CGDisplayConfigRef, CGDirectDisplayID, Bool) -> CGError
    private let library: UnsafeMutableRawPointer?
    private let enable: EnableFunction?
    private let diagnostics: TransactionAudit?
    private let freshRead: (() throws -> [Display])?
    private let freshObservationTime: (() -> Double?)?
    public var canDisconnect: Bool { enable != nil }
    public var canRestoreRotation: Bool { ODRotationAvailable() }
    public init(freshRead: (() throws -> [Display])? = nil, freshObservationTime: (() -> Double?)? = nil, diagnostics: TransactionAudit? = nil) {
        self.diagnostics = diagnostics
        self.freshRead = freshRead
        self.freshObservationTime = freshObservationTime
        library = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)
        if let library, let symbol = dlsym(library, "CGSConfigureDisplayEnabled") { enable = unsafeBitCast(symbol, to: EnableFunction.self) } else { enable = nil }
    }
    deinit { if let library { dlclose(library) } }
    public static var bootID: String {
        var time = timeval(); var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &time, &size, nil, 0) == 0 else { return "unknown" }
        return "\(time.tv_sec)-\(time.tv_usec)"
    }
    public static func uuid(_ id: UInt32) -> String? {
        guard let value = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return (CFUUIDCreateString(nil, value) as String).uppercased()
    }
    public func isActive(_ id: UInt32) -> Bool { CGDisplayIsActive(id) != 0 }
    public func list() throws -> [Display] {
        if let freshRead { return try freshRead() }
        var count: UInt32 = 0
        try check(CGGetActiveDisplayList(0, nil, &count), "读取显示器数量")
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        try check(CGGetActiveDisplayList(count, &ids, &count), "读取显示器清单")
        return try ids.prefix(Int(count)).map { id in
            guard let uuid = Self.uuid(id) else { throw OmniError.message("无法读取屏幕 \(id) 的稳定身份。") }
            let bounds = CGDisplayBounds(id); let mode = CGDisplayCopyDisplayMode(id)
            let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
            return Display(id: uuid, displayID: id, name: screen?.localizedName ?? "显示器 \(id)", active: CGDisplayIsActive(id) != 0, main: CGDisplayIsMain(id) != 0, builtin: CGDisplayIsBuiltin(id) != 0, mirrored: CGDisplayIsInMirrorSet(id) != 0, vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id), serial: CGDisplaySerialNumber(id), x: Int32(bounds.minX), y: Int32(bounds.minY), width: mode?.width ?? Int(bounds.width), height: mode?.height ?? Int(bounds.height), pixelWidth: mode?.pixelWidth ?? 0, pixelHeight: mode?.pixelHeight ?? 0, refresh: mode?.refreshRate ?? 0, rotation: CGDisplayRotation(id))
        }.sorted { $0.id < $1.id }
    }
    /// Emergency recovery: enable only, no origin/mode changes, no disabling.
    /// Same-boot cached IDs may be used only when UUID is unavailable AND the
    /// nonzero hardware fingerprint is unique in the saved topology and matches now.
    public func reconnectOnly(_ snapshot: Snapshot, target: String? = nil) -> [String] {
        var messages: [String] = []
        guard snapshot.boot == Self.bootID, Self.bootID != "unknown", let enable else { return ["拒绝：系统会话变化或重连接口不可用。"] }
        for saved in snapshot.displays where (target == nil ? saved.active : saved.id == target) {
            guard let resolved = recoveryID(saved, snapshot: snapshot) else { messages.append("拒绝身份不匹配或歧义：\(saved.name)"); continue }
            if CGDisplayIsActive(resolved) != 0 { messages.append("跳过活动屏幕：\(saved.name)"); continue }
            do {
                try transaction { config in
                    // User may be reconnecting a cable concurrently: never disable or touch active panels.
                    guard recoveryID(saved, snapshot: snapshot) == resolved else { throw OmniError.message("恢复前身份变化，已停止。") }
                    if CGDisplayIsActive(resolved) != 0 { return }
                    diagnostics?.record("enableCall", AuditDetail("", ["displayID": String(resolved), "uuid": saved.id, "enabled": "true"]))
                    try check(enable(config, resolved, true), "仅启用 \(saved.name)")
                }
                messages.append("已发送仅启用：\(saved.name) [\(resolved)]")
            } catch { messages.append(error.localizedDescription) }
        }
        return messages
    }
    private func recoveryID(_ saved: Display, snapshot: Snapshot) -> UInt32? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return nil }
        var online = [UInt32](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &online, &count) == .success else { return nil }
        let ids = Set(Array(online.prefix(Int(count))) + snapshot.displays.map(\.displayID))
        let candidates = ids.map { RecoveryCandidate(displayID: $0, uuid: Self.uuid($0), vendor: CGDisplayVendorNumber($0), model: CGDisplayModelNumber($0), serial: CGDisplaySerialNumber($0)) }
        return RecoveryIdentity.resolve(saved: saved, snapshot: snapshot, boot: Self.bootID, candidates: candidates)
    }
    public func applyRemote(_ request: Request) throws {
        // Legacy batch remote mode remains prohibited; only request-bound single-screen tests exist.
        throw OmniError.message(LiveSwitchPolicy.reason)
    }
    /// Legacy transaction recovery also only enables. Never replays layout or modes.
    public func restore(_ snapshot: Snapshot) -> [String] {
        let messages = reconnectOnly(snapshot)
        var warnings = messages.filter { $0.hasPrefix("拒绝") || $0.contains("失败") }
        let live = (try? list()) ?? []
        for saved in snapshot.displays where saved.active && !live.contains(where: { $0.id == saved.id && $0.active }) {
            warnings.append("\(saved.name)：尚未确认在线，请检查视频线或稍后刷新。")
        }
        return warnings
    }
    public func connect(_ target: String, from registry: Snapshot, preserveLayout: Bool = true) -> [String] {
        guard registry.displays.contains(where: { $0.id == target }) else { return ["目标屏幕不在身份缓存中。"] }
        guard let current = try? list(), !current.contains(where: { $0.id == target && $0.active }) else { return ["目标已活动或当前身份无法读取，未发送连接/排列操作。"] }
        guard LayoutGuard.peersUnchanged(before: registry.displays, current: current, target: target) else { return ["连接前其他屏幕已变化，拒绝使用过期快照。"] }
        let messages = reconnectOnly(registry, target: target)
        for _ in 0..<10 {
            if let live = try? list(), live.contains(where: { $0.id == target && $0.active }) { return preserveLayout ? restoreTargetLayout(target, from: registry, observed: live) : [] }
            HelperEventLoop.wait(0.2)
        }
        return messages + ["未确认目标屏幕在线；检查视频线或手动拔插该屏的视频线，勿拔整个扩展坞。"]
    }
    private func restoreTargetLayout(_ target: String, from snapshot: Snapshot, observed: [Display]) -> [String] {
        guard let saved = snapshot.displays.first(where: { $0.id == target }),
              var live = observed.first(where: { $0.id == target && $0.active }) else { return ["目标身份不可确认，未恢复排列。"] }
        guard LayoutGuard.peersUnchanged(before: snapshot.displays, current: observed, target: target) else { return ["其他屏幕连接/排列已变化，未覆盖当前布局。请确认后手动调整。"] }
        do {
            // Compare with the just-observed complete state immediately before any layout write.
            guard try list() == observed else { return ["检测到并发显示调整，已停止排列恢复。"] }
            if abs(live.rotation - saved.rotation) > 0.1 {
                guard Self.uuid(live.displayID) == target, ODRotationAvailable() else { return ["自动旋转接口不可用。请在系统设置将 \(saved.name) 恢复为 \(Int(saved.rotation))°。"] }
                guard ODRotateDisplay(live.displayID, Int32(saved.rotation)) == 0 else { return ["旋转请求被系统拒绝；请手动恢复 \(Int(saved.rotation))°。"] }
                var rotated = false
                for _ in 0..<30 {
                    let current = try list()
                    guard LayoutGuard.peersUnchanged(before: observed, current: current, target: target), let found = current.first(where: { $0.id == target && $0.active }) else { return ["旋转期间连接/其他屏幕排列变化，已停止后续写入。"] }
                    live = found
                    if abs(live.rotation - saved.rotation) < 0.1 { rotated = true; break }
                    HelperEventLoop.wait(0.1)
                }
                guard rotated else { return ["未确认旋转完成，停止后续排列写入。请手动核对目标屏幕。"] }
            }
            let current = try list()
            guard LayoutGuard.peersUnchanged(before: observed, current: current, target: target),
                  current.first(where: { $0.id == target }) == live else { return ["检测到并发显示调整，停止后续排列写入。"] }
            // Do not steal the primary role from a different current main display.
            if saved.main != live.main { return ["当前主屏角色已变化，不自动切主屏；请在系统设置核对排列。"] }
            let needsMode = live.width != saved.width || live.height != saved.height || live.pixelWidth != saved.pixelWidth || live.pixelHeight != saved.pixelHeight || abs(live.refresh - saved.refresh) > 0.5
            let needsOrigin = live.x != saved.x || live.y != saved.y
            if !needsMode && !needsOrigin { return [] }
            let mode = (CGDisplayCopyAllDisplayModes(live.displayID, nil) as? [CGDisplayMode] ?? []).first { $0.width == saved.width && $0.height == saved.height && $0.pixelWidth == saved.pixelWidth && $0.pixelHeight == saved.pixelHeight && abs($0.refreshRate - saved.refresh) < 0.5 }
            if needsMode && mode == nil { return ["目标屏幕原显示模式不可用，未猜测替代模式或位置。"] }
            try transaction { config in
                guard Self.uuid(live.displayID) == target, CGDisplayIsActive(live.displayID) != 0 else { throw OmniError.message("目标屏幕已变化。") }
                if needsMode, let mode { try check(CGConfigureDisplayWithDisplayMode(config, live.displayID, mode, nil), "恢复目标屏幕模式") }
                if needsOrigin { try check(CGConfigureDisplayOrigin(config, live.displayID, saved.x, saved.y), "恢复目标屏幕位置") }
            }
            guard let final = try list().first(where: { $0.id == target }), final.x == saved.x, final.y == saved.y, abs(final.rotation-saved.rotation) < 0.1, final.width == saved.width, final.height == saved.height else { return ["目标屏幕已连接，但未确认排列完全保持。请在系统设置检查。"] }
            return []
        } catch { return [error.localizedDescription] }
    }
    public func disconnect(_ request: Request, mayProceed: () -> Bool = { true }, willMutate: () throws -> Void = {}, audit: (String) -> Void = { _ in }) throws -> InputWriteResult {
        try LiveTestConsent.validate(request)
        guard let enable else { throw OmniError.message("断开接口不可用。") }
        let current = try list()
        diagnostics?.record("disconnectBefore", current)
        let checked = try DisconnectWriteChecks.validate(request, current: current, boot: Self.bootID)
        let target = checked.target, retained = checked.retained, targetID = checked.target.id
        try transaction { config in
            try LiveTestConsent.validate(request)
            guard mayProceed(), try list() == current,
                  Self.uuid(target.displayID) == targetID, Self.uuid(retained.displayID) == retained.id,
                  CGDisplayIsActive(retained.displayID) != 0, CGDisplayIsMain(target.displayID) == 0,
                  CGDisplayIsActive(target.displayID) != 0 else { throw OmniError.message("提交前目标或保留屏变化，已取消。") }
            try willMutate()
            diagnostics?.record("enableCall", AuditDetail("", ["displayID": String(target.displayID), "uuid": target.id, "enabled": "false"]))
            try check(enable(config, target.displayID, false), "断开所选非主屏")
        }
        guard CGDisplayIsActive(target.displayID) == 0 else { throw OmniError.message("断开请求已发送，但目标仍活动；将尝试回连。") }
        try settleDisconnectedLayout(request, mayProceed: mayProceed, audit: audit)
        return InputWriteResult(submitted: true, verified: true, message: "目标已断开，活动屏幕身份及相对排列已稳定核验。")
    }
    /// A bounded, request-authorized reconciliation immediately after disabling.
    /// Never enable/disable a peer or touch new hardware. The original snapshot is immutable.
    private func settleDisconnectedLayout(_ request: Request, mayProceed: () -> Bool, audit: (String) -> Void) throws {
        guard let target = request.before.displays.first(where: { $0.id == request.target }),
              let retained = request.before.displays.first(where: { $0.id == request.keep }) else { throw OmniError.message("断开身份缺失。") }
        func safe() throws {
            guard mayProceed(), Self.bootID == request.before.boot,
                  Self.uuid(retained.displayID) == retained.id, CGDisplayIsActive(retained.displayID) != 0,
                  CGDisplayIsActive(target.displayID) == 0 else { throw OmniError.message("协调已取消、超时，或目标/保留实体屏状态变化。") }
        }
        func stable(for duration: Double, matching: Bool) throws -> [Display] {
            let monitor = try DisplayObservationMonitor()
            defer { withExtendedLifetime(monitor) {} }
            return try DisconnectStabilizer.wait(request: request, matching: matching, duration: duration,
                                          read: { try self.list() }, safe: safe, state: { monitor.epoch.state() },
                                          observationTime: { self.freshObservationTime?() },
                                          audit: { self.diagnostics?.record("stabilitySample", $0) })
        }
        var observed = try stable(for:1.2, matching:false)
        diagnostics?.record("initialStabilityResult", observed)
        if DisconnectTopology.matches(request,current:observed) { return }
        try LiveTestConsent.validate(request)
        for saved in DisconnectTopology.peers(request) {
            guard let live=observed.first(where: { $0.id == saved.id }) else { throw OmniError.message("活动屏幕身份丢失。") }
            if abs(live.rotation-saved.rotation) < 0.1 { continue }
            try safe()
            _ = try DisconnectTopology.reconciliationTargets(request,observed:observed,current:list())
            guard Self.uuid(live.displayID) == saved.id, ODRotationAvailable() else { throw OmniError.message("协调前有并发变化或旋转接口不可用。") }
            audit("旋转前：\(saved.name) UUID=\(saved.id) displayID=\(live.displayID) 当前\(live.rotation)° 目标\(saved.rotation)°")
            diagnostics?.record("rotationCall", AuditDetail("SLSSetDisplayRotation", ["target": saved.id, "displayID": String(live.displayID), "degrees": String(saved.rotation)]))
            let result=ODRotateDisplay(live.displayID,Int32(saved.rotation))
            diagnostics?.record("rotationReturn", AuditDetail("SLSSetDisplayRotation", ["status": String(result)]))
            audit("旋转底层返回：\(saved.id) SLSSetDisplayRotation status=\(result)；尚未确认完成")
            guard result == 0 else { throw OmniError.message("\(saved.name)：旋转底层拒绝，status=\(result)。") }
            observed = try RotationWait.wait(target:saved.id,degrees:saved.rotation,timeout:2.5,read: {
                try safe()
                let current=try list()
                try DisconnectTopology.validateIdentities(request,current:current)
                return current
            })
            audit("旋转实读核验完成：\(saved.id) \(saved.rotation)°")
        }
        try safe()
        if DisconnectTopology.matches(request,current:observed) { return }
        try DisconnectTopology.validateIdentities(request,current:observed)
        var modes: [String:CGDisplayMode] = [:]
        for saved in DisconnectTopology.peers(request) {
            guard let live=observed.first(where: { $0.id == saved.id }) else { throw OmniError.message("原屏幕不可见。") }
            if live.width != saved.width || live.height != saved.height || live.pixelWidth != saved.pixelWidth || live.pixelHeight != saved.pixelHeight || abs(live.refresh-saved.refresh) >= 0.5 {
                guard let mode=(CGDisplayCopyAllDisplayModes(live.displayID,nil) as? [CGDisplayMode] ?? []).first(where: { $0.width == saved.width && $0.height == saved.height && $0.pixelWidth == saved.pixelWidth && $0.pixelHeight == saved.pixelHeight && abs($0.refreshRate-saved.refresh) < 0.5 }) else { throw OmniError.message("原显示模式不可用，不能猜测替代模式。") }
                modes[saved.id]=mode
            }
        }
        try transaction { config in
            try safe(); try LiveTestConsent.validate(request)
            let desired = try DisconnectTopology.reconciliationTargets(request,observed:observed,current:list())
            diagnostics?.record("reconciliationPlan", desired)
            for saved in desired {
                guard let live=observed.first(where: { $0.id == saved.id }), Self.uuid(live.displayID) == saved.id,
                      CGDisplayIsActive(live.displayID) != 0 else { throw OmniError.message("提交排列前活动屏身份变化。") }
                if let mode=modes[saved.id] { try check(CGConfigureDisplayWithDisplayMode(config,live.displayID,mode,nil),"恢复保留屏原模式") }
                try check(CGConfigureDisplayOrigin(config,live.displayID,saved.x,saved.y),"保留原屏幕排列")
            }
        }
        _ = try stable(for:1.2, matching:true)
    }
    public func recoverDisconnected(_ request: Request) throws -> InputWriteResult {
        try LiveTestConsent.validate(request, restoring: true)
        guard request.operation == .disconnect, let target = request.target else { throw OmniError.message("恢复目标缺失。") }
        let messages = reconnectOnly(request.before, target: target)
        for _ in 0..<15 {
            if let current = try? list(), current.contains(where: { $0.id == target && $0.active }) {
                let warnings = (request.preserveLayout ?? true) ? restoreTargetLayout(target, from: request.before, observed: current) : []
                return InputWriteResult(submitted: true, verified: warnings.isEmpty, message: warnings.isEmpty ? "目标已回连并核对原排列；应用窗口不搬回。" : "目标已回连；" + warnings.joined(separator: "；"))
            }
            HelperEventLoop.wait(0.2)
        }
        throw OmniError.message("目标尚未恢复活动：" + messages.joined(separator: "；") + "。请仅拔插目标屏幕的视频线。")
    }
    /// Called only by the short-lived input worker under the independent helper's
    /// operation lock. All real setting writes remain centralized in this backend.
    public func changeInput(_ request: Request, restoring: Bool, mayProceed: () -> Bool = { true }, willMutate: () throws -> Void = {}) throws -> InputWriteResult {
        // NEVER derive this gate from request.simulation: that could route a fake
        // simulation request to physical I/O. Request-bound confirmation precedes even reads.
        try InputControl.validateWrite(simulation: false, request: request, restoring: restoring)
        let initial = try list()
        let target = try InputWriteChecks.target(request: request, current: initial, boot: Self.bootID, restoring: restoring)
        guard mayProceed() else { throw OmniError.message("输入源操作已取消或超时。") }
        let probe = InputControl.probe(target)
        let needed = try InputWriteChecks.requiresWrite(request: request, target: target, probe: probe, restoring: restoring)
        if !needed { return InputWriteResult(submitted: false, verified: true, message: "原输入已恢复，未重复写入。") }
        guard try list() == initial, mayProceed(), let route = probe.route,
              let retained = initial.first(where: { $0.id == request.keep && $0.active }) else { throw OmniError.message("写入前拓扑变化、取消或超时，停止切源。") }
        let plan = try InputChangePlan(request: request)
        let desired = restoring ? plan.previous : plan.next
        var detail = [CChar](repeating: 0, count: 512)
        try willMutate()
        let result = ODSetInput(target.displayID, target.id, desired, route, retained.displayID, retained.id, true, ProcessInfo.processInfo.systemUptime + 5, &detail, detail.count)
        guard result == 0 else { throw OmniError.message("输入源写入未确认：" + String(cString: detail)) }
        HelperEventLoop.wait(0.15)
        let readback = InputControl.probe(target)
        let verified = readback.state == .readable && readback.current == desired && readback.route == route
        return InputWriteResult(submitted: true, verified: verified, message: verified ? "已读回目标输入值；仍需现场确认画面。" : "已发送切源请求，但无法确认读回；可能已失去 DDC 通道，必须核对实体屏幕。")
    }
    private func transaction(_ body: (CGDisplayConfigRef) throws -> Void) throws {
        var ref: CGDisplayConfigRef?
        try check(CGBeginDisplayConfiguration(&ref), "开始显示事务")
        guard let ref else { throw OmniError.message("显示事务为空。") }
        do { try body(ref) } catch { let result = CGCancelDisplayConfiguration(ref); diagnostics?.record("cgCallResult", AuditDetail("取消未提交的显示事务", ["rawCode": String(result.rawValue), "error": error.localizedDescription])); throw error }
        try check(CGCompleteDisplayConfiguration(ref, .forSession), "提交显示事务")
    }
    private func check(_ result: CGError, _ action: String) throws {
        diagnostics?.record("cgCallResult", AuditDetail(action, ["rawCode": String(result.rawValue)]))
        guard result == .success else { throw OmniError.message("\(action)失败（CGError \(result.rawValue)）。") }
    }
}
