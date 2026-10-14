import Foundation
import OmniDDC

public enum InputProbeState: String, Codable, Sendable {
    case readable, unsupported, unavailable, unknown, readFailed
    public var title: String {
        switch self {
        case .readable: return "当前输入可读取"
        case .unsupported: return "屏幕报告不支持输入查询"
        case .unavailable: return "读取接口不可用"
        case .unknown: return "能力未确认"
        case .readFailed: return "读取失败"
        }
    }
}
public struct InputProbe: Codable, Sendable {
    public var target: String
    public var state: InputProbeState
    public var current: UInt16?
    public var route: UInt64?
    public var detail: String
    public var date = Date()
    public var simulation = false
    public init(target: String, state: InputProbeState, current: UInt16? = nil, detail: String, simulation: Bool = false, route: UInt64? = nil) {
        self.target = target; self.state = state; self.current = current; self.detail = detail; self.simulation = simulation; self.route = route
    }
    public static func label(_ value: UInt16) -> String {
        let names: [UInt16: String] = [0x01:"VGA 1",0x03:"DVI 1",0x04:"DVI 2",0x0F:"DisplayPort 1",0x10:"DisplayPort 2",0x11:"HDMI 1",0x12:"HDMI 2"]
        return names[value]?.replacingOccurrences(of:" 1",with:"") ?? "未识别输入"
    }
}
public enum DDCReply: Equatable {
    case current(UInt16), unsupported
    public static func parse(_ bytes: [UInt8]) throws -> DDCReply {
        guard bytes.count >= 11, bytes[0] == 0x6e, bytes[1] == 0x88,
              bytes[2] == 0x02, bytes[4] == 0x60,
              bytes.prefix(11).reduce(UInt8(0x50), ^) == 0 else {
            throw OmniError.message("DDC 回复长度、命令或校验和无效；不能据此判断输入源。")
        }
        if bytes[3] == 1 { return .unsupported }
        guard bytes[3] == 0, bytes[5] <= 1 else { throw OmniError.message("DDC 回复结果或类型未知。") }
        let value = UInt16(bytes[8]) << 8 | UInt16(bytes[9])
        guard value > 0 else { throw OmniError.message("屏幕返回空输入值，不能判断当前输入。") }
        return .current(value)
    }
}
public enum InputControl {
    public static let lockReason = "仅允许单次确认后切源：需有效读数、两个已核对的端口、另一块保留实体屏，以及现场 OSD 切回条件。"
    public static func validateWrite(simulation: Bool, request: Request? = nil, restoring: Bool = false) throws {
        if simulation { return }
        guard let request else { throw OmniError.message(lockReason) }
        try LiveTestConsent.validate(request, restoring: restoring)
    }
    public static func probe(_ display: Display) -> InputProbe {
        guard display.active, !display.builtin, !display.mirrored else { return InputProbe(target: display.id, state: .unknown, detail: "仅检测活动、非镜像的外接屏幕。") }
        var results: [DDCReply] = []; var details: [String] = []; var routes: [UInt64] = []
        for _ in 0..<2 {
            var reply = [UInt8](repeating: 0, count: 12), message = [CChar](repeating: 0, count: 512)
            var route: UInt64 = 0
            let code = ODReadInputProfile(display.displayID, display.id, &reply, &message, message.count, &route, 0, 200000, true)
            routes.append(route)
            let detail = String(cString: message); details.append(detail)
            guard code == 0 else {
                return InputProbe(target: display.id, state: code == 1 ? .unavailable : (code == 5 ? .readFailed : .unknown), detail: detail)
            }
            do { results.append(try DDCReply.parse(reply)) }
            catch { return InputProbe(target: display.id, state: .readFailed, detail: detail + "；" + error.localizedDescription + " 原始回复：" + reply.map { String(format: "%02X", $0) }.joined(separator: " ")) }
            HelperEventLoop.wait(0.05)
        }
        guard routes[0] != 0, routes[0] == routes[1], results[0] == results[1], details[0] == details[1] else { return InputProbe(target: display.id, state: .readFailed, detail: "两次读取结果或硬件路由不一致，丢弃读数。") }
        switch results[0] {
        case .unsupported: return InputProbe(target: display.id, state: .unsupported, detail: details[0])
        case .current(let value): return InputProbe(target: display.id, state: .readable, current: value, detail: details[0] + "；两次有效回复一致，仅证明当前输入可读。可选端口列表未验证。", route: routes[0])
        }
    }
}

/// A write plan is not permission. The helper, backend and native transport each
/// enforce request-specific confirmation before hardware access.
public struct InputChangePlan {
    public let target: String
    public let previous: UInt16
    public let next: UInt16
    public init(request: Request) throws {
        guard request.confirmedPhysical, let target = request.target,
              request.before.displays.filter({ $0.id == target }).count == 1,
              let d = request.before.displays.first(where: { $0.id == target }), d.active, !d.builtin,
              !request.before.displays.contains(where: { $0.active && $0.mirrored }),
              request.keep != target, request.before.displays.contains(where: { $0.id == request.keep && $0.active }),
              let previous = request.inputBefore, let next = request.inputAfter,
              previous > 0, next > 0, previous != next else { throw OmniError.message("输入源目标、保留实体屏或端口确认不完整。") }
        guard request.operation == .inputSource, request.before.version == 1,
              Set(request.before.displays.map(\.id)).count == request.before.displays.count,
              request.before.displays.allSatisfy({ UUID(uuidString: $0.id) != nil }) else { throw OmniError.message("输入源请求身份格式无效。") }
        if !request.simulation {
            guard !d.main, request.inputPortsConfirmed == true,
                  let mappings = request.inputPortMappings,
                  mappings.filter({ $0.target == target && $0.boot == request.before.boot && $0.route > 0 && $0.code == previous && $0.label == request.inputFromPort }).count == 1,
                  mappings.filter({ $0.target == target && $0.boot == request.before.boot && $0.route > 0 && $0.code == next && $0.label == request.inputToPort }).count == 1,
                  let from = request.inputFromPort, !from.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let to = request.inputToPort, !to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  from != to else { throw OmniError.message("真实切源只接受非主屏，且必须现场确认原端口、目标端口和物理切回方法。") }
        }
        self.target = target; self.previous = previous; self.next = next
    }
}

public enum TargetRecovery {
    /// Recover only the target; preserve new peers and concurrent peer changes.
    public static func simulated(before: [Display], current: [Display], target: String) throws -> [Display] {
        guard Set(current.map(\.id)).count == current.count,
              let saved = before.first(where: { $0.id == target }) else { throw OmniError.message("目标恢复身份不唯一。") }
        var recovered = saved
        if current.contains(where: { $0.id != target && $0.main && $0.active }) { recovered.main = false }
        if let index = current.firstIndex(where: { $0.id == target }) {
            var merged = current; merged[index] = recovered; return merged
        }
        return current + [recovered]
    }
}

public struct InputReadDiagnostic: Codable {
    public var target: String
    public var samples: [Sample]
    public struct Sample: Codable {
        public var profile: String
        public var attempt: Int
        public var transportCode: Int32
        public var route: UInt64
        public var raw: [UInt8]
        public var interpretation: String
        public var detail: String
    }
    /// Bounded read-only variants, all fixed Get VCP 0x60. Never try Set to probe support.
    public static func run(_ display: Display) -> InputReadDiagnostic {
        let profiles: [(String, UInt32, UInt32, Bool)] = [("IOAV-offset0-50ms",0,50000,false),("IOAV-offset0-200ms",0,200000,false),("legacy-offset51-200ms",0x51,200000,false),("source-checksum-offset0-200ms",0,200000,true)]
        var samples: [Sample] = []
        for (name, offset, delay, source) in profiles {
            for attempt in 1...2 {
                var bytes = [UInt8](repeating: 0, count: 12), detail = [CChar](repeating: 0, count: 512), route: UInt64 = 0
                let code = ODReadInputProfile(display.displayID, display.id, &bytes, &detail, detail.count, &route, offset, delay, source)
                let interpretation: String
                do {
                    guard code == 0 else { throw OmniError.message("传输未成功") }
                    switch try DDCReply.parse(bytes) {
                    case .unsupported: interpretation = "valid-unsupported"
                    case .current(let value): interpretation = String(format: "valid-current-0x%04X", value)
                    }
                } catch { interpretation = error.localizedDescription }
                samples.append(Sample(profile: name, attempt: attempt, transportCode: code, route: route, raw: bytes, interpretation: interpretation, detail: String(cString: detail)))
            }
        }
        return InputReadDiagnostic(target: display.id, samples: samples)
    }
}
