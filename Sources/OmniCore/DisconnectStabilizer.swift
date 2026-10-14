import Foundation

public struct StabilitySample: Codable {
    public var stage: String
    public var index: Int
    public var started: Double
    public var completed: Double
    public var deadline: Double
    public var consecutive: Int
    public var outcome: String
    public var error: String?
    public var displays: [Display]?
    public var differencesFromPrevious: [DisplayFieldDifference]
    public var differencesFromExpected: [DisplayFieldDifference]
}
/// Pure read/clock/pause dependencies permit actual production logic to be replayed
/// without CG access. Quorum, identity checks and the 1.2-second budget are unchanged.
public enum DisconnectStabilizer {
    public static func wait(request: Request, matching: Bool, duration: Double = 1.2,
                            read: () throws -> [Display], safe: () throws -> Void,
                            now: () -> Double = { ProcessInfo.processInfo.systemUptime },
                            pause: (Double) -> Void = { HelperEventLoop.wait($0) },
                            audit: (StabilitySample) -> Void = { _ in }) throws -> [Display] {
        guard duration.isFinite, duration > 0, duration <= 1.2 else { throw OmniError.message("稳定采样期限无效。") }
        let deadline = now() + duration, stage = matching ? "finalVerification" : "initialStability"
        var prior: [Display]?, count = 0, index = 0
        var watch = DisconnectWatch()
        while now() < deadline {
            try safe()
            let started = now(); index += 1
            var current: [Display]?, readError: String?
            do { current = try read() } catch { readError = error.localizedDescription }
            let completed = now()
            var sample = StabilitySample(stage: stage, index: index, started: started, completed: completed, deadline: deadline,
                                         consecutive: count, outcome: "reading", error: readError, displays: current,
                                         differencesFromPrevious: current.map { DisplayDifferences.between(prior ?? [], $0) } ?? [],
                                         differencesFromExpected: current.map { DisplayDifferences.between(DisconnectTopology.peers(request), $0) } ?? [])
            // A successful but late read can never authorize subsequent writes.
            guard completed < deadline else { sample.outcome = "deadlineExceeded"; audit(sample); count = 0; prior = nil; break }
            do {
                try safe()
                if let current {
                    if Set(current.map(\.id)) == Set(DisconnectTopology.peers(request).map(\.id)) {
                        try DisconnectTopology.validateIdentities(request, current: current)
                        count = prior.map { DisconnectTopology.sameObservation($0, current) } == true ? count+1 : 1
                        prior = current
                        sample.consecutive = count
                        let matches = DisconnectTopology.matches(request, current: current)
                        // Preserve the initial reflow grace period. Stable original
                        // geometry may finish early; changed geometry waits until its end.
                        if count >= 2 && matches {
                            sample.outcome = "stableOriginalLayout"
                            audit(sample); return current
                        }
                        sample.outcome = matches ? "needsSecondObservation" : "layoutDiffers"
                    } else {
                        _ = try watch.observe(current, request: request, uptime: completed)
                        count = 0; prior = nil; sample.outcome = "partialEnumeration"
                    }
                } else { count = 0; prior = nil; sample.outcome = "readFailed" }
            } catch {
                sample.outcome = "rejected"; sample.error = error.localizedDescription; audit(sample); throw error
            }
            sample.consecutive = count; audit(sample)
            // Cadence is measured start-to-start. A slow fresh observer already
            // spent this interval sampling; do not add another unconditional 150ms.
            let remaining = min(0.15 - (now()-started), deadline-now())
            if remaining > 0 { pause(remaining) }
        }
        if !matching, count >= 2, let prior {
            try safe()
            return prior // fresh compare-before-write remains mandatory in reconciliation
        }
        throw OmniError.message(matching ? "协调后的最终排列未在1.2秒内稳定核验。" : "断开后的初始采样未在1.2秒内取得两次一致观察，尚未进入排列协调。")
    }
}
