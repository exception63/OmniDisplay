import Foundation
import CryptoKit

/// One explicit UI confirmation, bound to this request (including topology,
/// operation, target, retained display and input values). Not a persistent unlock.
public struct LiveTestConsent: Codable, Sendable {
    public var requestDigest: String
    public var issuedAt: Date
    public var expiresAt: Date
    public var targetSuffix: String
    public var riskAcknowledged: Bool
    public static func digest(_ request: Request) throws -> String {
        var unsigned = request; unsigned.liveConsent = nil
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(unsigned)).map { String(format: "%02x", $0) }.joined()
    }
    /// App calls this only from the second confirmation button for the shown target and
    /// explicitly acknowledges physical recovery access. Tests use pure fixtures.
    public static func grant(request: Request, confirmedTarget: String, riskAcknowledged: Bool, now: Date = Date()) throws -> LiveTestConsent {
        guard !request.simulation, [.disconnect, .inputSource, .remoteMode, .officeMode].contains(request.operation),
              let target = request.target, confirmedTarget == target, riskAcknowledged,
              request.confirmedPhysical else { throw OmniError.message("请核对目标屏幕并确认现场恢复条件。") }
        return LiveTestConsent(requestDigest: try digest(request), issuedAt: now, expiresAt: now.addingTimeInterval(90), targetSuffix: String(target.suffix(8)), riskAcknowledged: true)
    }
    public static func validate(_ request: Request, restoring: Bool = false, now: Date = Date()) throws {
        guard !request.simulation, [.disconnect, .inputSource, .remoteMode, .officeMode].contains(request.operation),
              let consent = request.liveConsent, consent.riskAcknowledged,
              consent.targetSuffix == String((request.target ?? "").suffix(8)),
              consent.requestDigest == (try? digest(request)),
              (restoring || consent.issuedAt <= now.addingTimeInterval(2)),
              consent.expiresAt > consent.issuedAt, consent.expiresAt.timeIntervalSince(consent.issuedAt) <= 90,
              (restoring || now < consent.expiresAt) else {
            throw OmniError.message("缺少有效的本次真机测试确认，或请求已改变/过期。请在 App 中重新确认。")
        }
    }
}
public struct InputPortMapping: Codable, Equatable, Sendable, Identifiable {
    public var target: String
    public var boot: String
    public var route: UInt64
    public var code: UInt16
    public var label: String
    public var observedAt: Date
    public var id: UInt16 { code }
    public init(target: String, boot: String, route: UInt64, code: UInt16, label: String, observedAt: Date = Date()) {
        self.target=target; self.boot=boot; self.route=route; self.code=code; self.label=label; self.observedAt=observedAt
    }
}
