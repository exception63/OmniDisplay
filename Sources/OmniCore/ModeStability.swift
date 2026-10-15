import Foundation

public struct ModeSettleDeadline: LocalizedError {
    public var errorDescription: String? { "模式步骤未在期限内完成活动状态/完整排列核验；未采用迟到读数。" }
}
/// Created only after a successful geometry submission (layout or explicit rotation), never for a pre-write failure.
public struct ModePostCommitDeadline: LocalizedError {
    public var errorDescription: String? { ModeSettleDeadline().localizedDescription }
}

/// Post-write observation only: never retries a write or accepts a failed sample.
public enum ModeStability {
    public static func wait(expected: [Display], office: [Display], matching: Bool, enabling: Bool,
                            timeout: Double = 2.5, mayProceed: () -> Bool,
                            read: () throws -> [Display], now: () -> Double = { ProcessInfo.processInfo.systemUptime },
                            pause: (Double) -> Void = { HelperEventLoop.wait($0) },
                            audit: (AuditDetail) -> Void = { _ in }) throws -> [Display] {
        let start = now(), end = start + timeout
        var previous: [Display]?
        func record(_ reason: String, _ live: [Display]? = nil) {
            audit(AuditDetail(reason, ["started": String(start), "deadline": String(end), "observedAt": String(now()),
                                      "matchesExpected": live.map { String(TemporaryLayout.matches(expected, $0)) } ?? "unavailable"]))
        }
        record("started")
        while now() < end {
            guard mayProceed() else { throw OmniError.message("模式步骤已取消或过期。") }
            let live: [Display]
            do { live = try read() }
            catch is ObservationNotSettled {
                record("observerNotSettled")
                previous = nil
                guard mayProceed() else { throw OmniError.message("模式步骤已取消或过期。") }
                guard now() < end else { break }
                pause(0.1); continue
            }
            guard mayProceed() else { throw OmniError.message("模式步骤已取消或过期。") }
            guard now() < end else { record("lateSampleRejected", live); break }
            record("sample", live)
            guard ModePlan.identities(live, within: office),
                  live.contains(where: { $0.id == expected.first(where: \.main)?.id }) || enabling else {
                throw OmniError.message("模式执行期间出现未知屏幕或保留屏丢失。")
            }
            guard Set(live.map(\.id)) == Set(expected.map(\.id)) else {
                previous = nil; pause(0.1); continue
            }
            if let previous, DisconnectTopology.sameObservation(previous, live),
               !matching || TemporaryLayout.matches(expected, live) { record("verified", live); return live }
            previous = live; pause(0.1)
        }
        record("settleDeadline")
        guard mayProceed() else { throw OmniError.message("模式步骤已取消或过期。") }
        throw ModeSettleDeadline()
    }
}

/// A separate, bounded verification stage. It has no mutation dependency and
/// never reuses the timed-out worker's evidence or accepts a different layout.
public enum ModeFinalVerification {
    public static func wait(expected: [Display], office: [Display], boot: String,
                            timeout: Double = 2.5, mayProceed: () -> Bool,
                            read: (Double) throws -> Snapshot,
                            now: () -> Double = { ProcessInfo.processInfo.systemUptime },
                            pause: (Double) -> Void = { HelperEventLoop.wait($0) },
                            audit: (AuditDetail) -> Void = { _ in }) throws -> [Display] {
        let end = now() + timeout
        return try ModeStability.wait(expected: expected, office: office, matching: true, enabling: false,
            timeout: timeout, mayProceed: mayProceed, read: {
                guard boot != "unknown", now() < end else { throw ModeSettleDeadline() }
                let snapshot = try read(min(1.2, max(0, end - now())))
                guard snapshot.boot == boot else { throw OmniError.message("收尾核验期间系统启动标识变化。") }
                guard ModePlan.identities(snapshot.displays, within: office),
                      TemporaryLayout.matches(expected, snapshot.displays) else {
                    throw OmniError.message("收尾读数与目标身份或完整排列不同；未覆盖当前状态。")
                }
                return snapshot.displays
            }, now: now, pause: pause, audit: audit)
    }
}
