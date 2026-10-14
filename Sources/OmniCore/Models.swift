import Foundation

public struct Display: Codable, Equatable, Identifiable, Sendable {
    public var id: String // CoreGraphics UUID, never the model name
    public var displayID: UInt32
    public var name: String
    public var active: Bool
    public var main: Bool
    public var builtin: Bool
    public var mirrored: Bool
    public var vendor: UInt32
    public var model: UInt32
    public var serial: UInt32
    public var x: Int32
    public var y: Int32
    public var width: Int
    public var height: Int
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var refresh: Double
    public var rotation: Double
    public var shortID: String { String(id.suffix(8)) }
    public var label: String { "\(name) · \(shortID)" }
    public static func samples(_ count: Int) -> [Display] {
        (0..<max(count, 0)).map { i in
            Display(id: String(format: "00000000-0000-0000-0000-%012d", i+1), displayID: UInt32(i+1), name: i == 0 ? "Studio Display" : "办公显示器", active: true, main: i == 0, builtin: false, mirrored: false, vendor: 610, model: 1, serial: UInt32(i), x: Int32(i*1920), y: 0, width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, refresh: 60, rotation: 0)
        }
    }
}
public struct Snapshot: Codable, Equatable, Sendable {
    public var version = 1
    public var date = Date()
    public var boot: String
    public var displays: [Display]
    public init(boot: String, displays: [Display]) { self.boot = boot; self.displays = displays }
}
public enum OmniError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
public struct RemotePlan: Codable, Equatable, Sendable {
    public var keep: String
    public var disable: [String]
    public var topology: [Display]
    public static func make(displays: [Display], keep: String) throws -> RemotePlan {
        guard !displays.isEmpty, Set(displays.map(\.id)).count == displays.count else { throw OmniError.message("显示器身份缺失或重复，已停止切换。") }
        guard let retained = displays.first(where: { $0.id == keep }), retained.active else { throw OmniError.message("保留屏幕已离线，请重新选择。") }
        guard !displays.contains(where: \.mirrored) else { throw OmniError.message("当前包含镜像屏幕，请先在系统设置中退出镜像。") }
        guard displays.filter(\.active).count > 1 else { throw OmniError.message("当前只有一块活动屏幕，无需切换。") }
        return RemotePlan(keep: keep, disable: displays.filter { $0.active && $0.id != keep }.map(\.id), topology: displays)
    }
    public func validate(current: [Display]) throws {
        guard current == topology else { throw OmniError.message("显示器连接或布局已改变，请重新预览后再切换。") }
        guard current.contains(where: { $0.id == keep && $0.active }), !disable.contains(keep), Set(disable).isSubset(of: Set(current.filter(\.active).map(\.id))) else { throw OmniError.message("安全检查失败：必须保留一块活动实体屏幕。") }
    }
}
public enum Operation: String, Codable, Sendable { case remote, restore, connect, disconnect, inputSource, remoteMode, officeMode }
public struct Request: Codable, Sendable {
    public var version = 1
    public var nonce: String
    public var operation: Operation
    public var before: Snapshot
    public var office: Snapshot
    public var keep: String
    public var target: String?
    public var preserveLayout: Bool?
    public var inputBefore: UInt16?
    public var inputAfter: UInt16?
    public var inputPortsConfirmed: Bool?
    public var inputFromPort: String?
    public var inputToPort: String?
    public var inputPortMappings: [InputPortMapping]?
    public var liveConsent: LiveTestConsent?
    public var layoutSession: LayoutSession?
    public var confirmedPhysical: Bool
    public var simulation: Bool
    public var timeout: Double
    public init(operation: Operation, before: Snapshot, office: Snapshot, keep: String, confirmedPhysical: Bool, simulation: Bool, timeout: Double = 45, target: String? = nil, preserveLayout: Bool = true) {
        nonce = UUID().uuidString; self.operation = operation; self.before = before; self.office = office; self.keep = keep; self.confirmedPhysical = confirmedPhysical; self.simulation = simulation; self.timeout = timeout; self.target = target; self.preserveLayout = preserveLayout
    }
}
public enum Phase: String, Codable, Sendable {
    case ready, applying, awaitingConfirmation, confirmed, restoring, restored, failed
    public var terminal: Bool { [.confirmed, .restored, .failed].contains(self) }
}
public struct Receipt: Codable, Sendable {
    public var phase: Phase
    public var message: String
    public var deadline: Date?
    public init(_ phase: Phase, _ message: String, deadline: Date? = nil) { self.phase = phase; self.message = message; self.deadline = deadline }
}
/// Append-only phase history for one helper run; the final receipt retains its cause.
public struct RecoveryEvent: Codable, Sendable {
    public var date: Date
    public var uptime: TimeInterval
    public var receipt: Receipt
    public init(receipt: Receipt) {
        self.date = Date(); self.uptime = ProcessInfo.processInfo.systemUptime; self.receipt = receipt
    }
}
public enum Files {
    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T { try JSONDecoder().decode(type, from: Data(contentsOf: url)) }
    public static func marker(_ name: String, in dir: URL) throws { try Data().write(to: dir.appendingPathComponent(name), options: .atomic) }
}

/// Recovery only: never authorizes a disable operation.
public enum RecoveryIdentity {
    public static func canReconnect(saved: Display, snapshot: Snapshot, boot: String, currentUUID: String?, vendor: UInt32, model: UInt32, serial: UInt32) -> Bool {
        guard snapshot.version == 1, snapshot.boot == boot, boot != "unknown" else { return false }
        if let currentUUID { return currentUUID == saved.id }
        guard saved.vendor != 0, saved.model != 0,
              vendor == saved.vendor, model == saved.model, serial == saved.serial else { return false }
        return snapshot.displays.filter { $0.vendor == vendor && $0.model == model && $0.serial == serial }.count == 1
    }
}

public enum LiveSwitchPolicy {
    public static let reason = "真实远程切换已暂停：本机发生过恢复失败，修复验证前仅允许模拟切换与屏幕恢复。"
    public static func validate(simulation: Bool) throws {
        guard simulation else { throw OmniError.message(reason) }
    }
}

public struct SingleDisplayPlan: Equatable {
    public var action: Operation
    public var target: String
    public var retained: String?
    public var topology: [Display]
    public static func make(action: Operation, target: String, displays: [Display], retainedPhysical: String? = nil) throws -> SingleDisplayPlan {
        guard action == .connect || action == .disconnect,
              Set(displays.map(\.id)).count == displays.count,
              let display = displays.first(where: { $0.id == target }) else { throw OmniError.message("屏幕身份不明确，请刷新后再试。") }
        if action == .disconnect {
            guard display.active else { throw OmniError.message("这块屏幕已经不活动。") }
            guard displays.filter(\.active).count > 1 else { throw OmniError.message("不能断开最后一块活动屏幕。") }
            guard !displays.contains(where: { $0.active && $0.mirrored }) else { throw OmniError.message("镜像模式暂不支持断开。") }
            guard let retainedPhysical, retainedPhysical != target, displays.contains(where: { $0.id == retainedPhysical && $0.active }) else { throw OmniError.message("必须确认仍保留一块活动实体屏幕。") }
        } else if display.active { throw OmniError.message("这块屏幕已经连接，无需重复连接。") }
        return SingleDisplayPlan(action: action, target: target, retained: retainedPhysical, topology: displays)
    }
    public func validate(current: [Display]) throws {
        guard topology == current else { throw OmniError.message("连接状态已变化，本次操作已取消，请重新选择屏幕。") }
    }
    public func simulatedResult() -> [Display] {
        topology.map { original in
            var d = original
            if d.id == target { d.active = action == .connect; if !d.active { d.main = false } }
            if action == .disconnect, original.id == retained, topology.first(where: { $0.id == target })?.main == true { d.main = true }
            return d
        }
    }
}

public enum LayoutGuard {
    public static func peersUnchanged(before: [Display], current: [Display], target: String) -> Bool {
        let a = before.filter { $0.active && $0.id != target }.sorted { $0.id < $1.id }
        let b = current.filter { $0.active && $0.id != target }.sorted { $0.id < $1.id }
        return a == b
    }
}

public struct RecoveryCandidate {
    public let displayID: UInt32
    public let uuid: String?
    public let vendor: UInt32
    public let model: UInt32
    public let serial: UInt32
    public init(displayID: UInt32, uuid: String?, vendor: UInt32, model: UInt32, serial: UInt32) {
        self.displayID = displayID; self.uuid = uuid; self.vendor = vendor; self.model = model; self.serial = serial
    }
}
extension RecoveryIdentity {
    public static func resolve(saved: Display, snapshot: Snapshot, boot: String, candidates: [RecoveryCandidate]) -> UInt32? {
        guard snapshot.boot == boot, boot != "unknown", snapshot.version == 1,
              Set(candidates.map(\.displayID)).count == candidates.count else { return nil }
        let exact = candidates.filter { $0.uuid == saved.id }
        if exact.count == 1 { return exact[0].displayID }
        guard exact.isEmpty, let cached = candidates.first(where: { $0.displayID == saved.displayID }), cached.uuid == nil,
              canReconnect(saved: saved, snapshot: snapshot, boot: boot, currentUUID: nil, vendor: cached.vendor, model: cached.model, serial: cached.serial),
              candidates.filter({ $0.vendor == saved.vendor && $0.model == saved.model && $0.serial == saved.serial }).count == 1 else { return nil }
        return cached.displayID
    }
}
