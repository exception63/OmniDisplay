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
    public var generationBefore: UInt64?
    public var generationAfter: UInt64?
    public var pendingBefore: Bool?
    public var pendingAfter: Bool?
    public var evidenceAge: Double?
}
/// Initial reflow grace and the hard read deadline share a 1.2s window. A quorum
/// is two consecutive, timely observations in one local invalidation epoch.
/// In the final cadence, a quorum fresh through the grace boundary is held without
/// starting another read. No late result is accepted, including a late second vote.
/// Returned reflow is evidence for planning only; writes still require fresh CAS.
public enum DisconnectStabilizer {
    public static let cadence = 0.15
    public static func wait(request: Request, matching: Bool, duration: Double = 1.2,
                            read: () throws -> [Display], safe: () throws -> Void,
                            state: () -> (generation: UInt64, pending: Bool) = { (0, false) },
                            observationTime: () -> Double? = { nil },
                            now: () -> Double = { ProcessInfo.processInfo.systemUptime },
                            pause: (Double) -> Void = { HelperEventLoop.wait($0) },
                            audit: (StabilitySample) -> Void = { _ in }) throws -> [Display] {
        guard duration.isFinite, duration > 0, duration <= 1.2 else { throw OmniError.message("稳定采样期限无效。") }
        let deadline = now() + duration, stage = matching ? "finalVerification" : "initialStability"
        var prior: [Display]?, count = 0, index = 0
        var acceptedAt: Double?, acceptedGeneration: UInt64?
        var watch = DisconnectWatch()
        func recordDecision(_ outcome: String) {
            let epoch = state()
            audit(StabilitySample(stage: stage, index: index, started: acceptedAt ?? now(), completed: now(),
                deadline: deadline, consecutive: count, outcome: outcome, displays: prior,
                differencesFromPrevious: [], differencesFromExpected: prior.map { DisplayDifferences.between(DisconnectTopology.peers(request), $0) } ?? [],
                generationBefore: acceptedGeneration, generationAfter: epoch.generation, pendingBefore: false,
                pendingAfter: epoch.pending, evidenceAge: acceptedAt.map { now() - $0 }))
        }
        func finishGrace() throws -> [Display] {
            // Pump callbacks and cancellation while holding evidence; never sleep
            // through invalidation or let an overslept/stale quorum authorize CAS.
            recordDecision("holdingReflowEvidence")
            while true {
                try safe()
                let epoch = state()
                guard !epoch.pending, epoch.generation == acceptedGeneration else {
                    recordDecision("graceInvalidated")
                    throw OmniError.message("宽限等待期间出现显示重配，原观察失效，停止协调。")
                }
                let currentTime = now()
                guard let acceptedAt, currentTime >= acceptedAt, currentTime - acceptedAt <= cadence else {
                    recordDecision("staleEvidence")
                    throw OmniError.message("宽限结束时观察已过期，停止协调。")
                }
                if currentTime >= deadline {
                    guard let prior, count >= 2 else { throw OmniError.message("稳定观察不足。") }
                    recordDecision("graceComplete")
                    return prior
                }
                pause(min(0.03, deadline - currentTime))
            }
        }
        while now() < deadline {
            try safe()
            let epochBefore = state()
            if epochBefore.pending || acceptedGeneration != epochBefore.generation {
                prior = nil; count = 0; acceptedAt = nil; acceptedGeneration = nil
            }
            if !matching, count >= 2, let acceptedAt,
               deadline - now() <= cadence, deadline - acceptedAt < cadence {
                return try finishGrace()
            }
            let started = now(); index += 1
            // safe()/audit/dispatch can also consume the remaining budget.
            guard started < deadline else { break }
            var current: [Display]?, readError: String?
            do { current = try read() } catch { readError = error.localizedDescription }
            let completed = now(), epochAfter = state()
            // Production supplies the child observer's actual sampling completion,
            // not the parent's receipt time. Synthetic reads default to completion.
            let observedAt = observationTime() ?? completed
            var sample = StabilitySample(stage: stage, index: index, started: started, completed: completed, deadline: deadline,
                                         consecutive: count, outcome: "reading", error: readError, displays: current,
                                         differencesFromPrevious: current.map { DisplayDifferences.between(prior ?? [], $0) } ?? [],
                                         differencesFromExpected: current.map { DisplayDifferences.between(DisconnectTopology.peers(request), $0) } ?? [])
            sample.generationBefore = epochBefore.generation; sample.generationAfter = epochAfter.generation
            sample.pendingBefore = epochBefore.pending; sample.pendingAfter = epochAfter.pending
            sample.evidenceAge = acceptedAt.map { completed - $0 }
            try safe()
            // A late in-flight result is an explicit failure, not a new vote or a
            // fallback to earlier evidence. Keep its actual quorum count in audit.
            guard completed < deadline else {
                sample.outcome = "deadlineExceeded"; audit(sample)
                throw OmniError.message("只读采样越过1.2秒截止，未采用迟到结果，停止协调。")
            }
            do {
                if let current {
                    if Set(current.map(\.id)) == Set(DisconnectTopology.peers(request).map(\.id)) {
                        try DisconnectTopology.validateIdentities(request, current: current)
                        guard observedAt.isFinite, observedAt >= started, observedAt <= completed,
                              completed - observedAt <= cadence else {
                            sample.outcome = "staleObservation"
                            throw OmniError.message("独立样本时间无效或过期，停止协调。")
                        }
                        if epochBefore.pending || epochAfter.pending || epochBefore.generation != epochAfter.generation {
                            count = 0; prior = nil; acceptedAt = nil; acceptedGeneration = nil
                            sample.outcome = "observationInvalidated"
                        } else {
                            count = prior.map { DisconnectTopology.sameObservation($0, current) } == true ? count+1 : 1
                            prior = current; acceptedAt = observedAt; acceptedGeneration = epochAfter.generation
                            sample.consecutive = count
                            let matches = DisconnectTopology.matches(request, current: current)
                            if count >= 2 && matches {
                                sample.outcome = "stableOriginalLayout"
                                audit(sample); return current
                            }
                            sample.outcome = matches ? "needsSecondObservation" : "layoutDiffers"
                        }
                    } else {
                        _ = try watch.observe(current, request: request, uptime: completed)
                        count = 0; prior = nil; acceptedAt = nil; acceptedGeneration = nil
                        sample.outcome = "partialEnumeration"
                    }
                } else {
                    count = 0; prior = nil; acceptedAt = nil; acceptedGeneration = nil
                    sample.outcome = "readFailed"
                }
            } catch {
                if sample.outcome != "staleObservation" { sample.outcome = "rejected" }
                sample.error = error.localizedDescription; audit(sample); throw error
            }
            sample.consecutive = count; audit(sample)
            if !matching, count >= 2, let acceptedAt,
               deadline - now() <= cadence, deadline - acceptedAt < cadence {
                return try finishGrace()
            }
            let remaining = min(cadence - (now()-started), deadline-now())
            if remaining > 0 { pause(remaining) }
        }
        if !matching, count >= 2, prior != nil { return try finishGrace() }
        throw OmniError.message(matching ? "协调后的最终排列未在1.2秒内稳定核验。" : "断开后的初始采样在1.2秒内未形成有效一致证据，尚未进入排列协调。")
    }
}
