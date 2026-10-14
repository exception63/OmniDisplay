import Foundation

/// Post-write observation only: never retries a write or accepts a failed sample.
public enum ModeStability {
    public static func wait(expected: [Display], office: [Display], matching: Bool, enabling: Bool,
                            timeout: Double = 2.5, mayProceed: () -> Bool,
                            read: () throws -> [Display], now: () -> Double = { ProcessInfo.processInfo.systemUptime },
                            pause: (Double) -> Void = { HelperEventLoop.wait($0) }) throws -> [Display] {
        let end = now() + timeout
        var previous: [Display]?
        while now() < end {
            guard mayProceed() else { throw OmniError.message("模式步骤已取消或过期。") }
            let live: [Display]
            do { live = try read() }
            catch is ObservationNotSettled {
                previous = nil
                guard mayProceed(), now() < end else { break }
                pause(0.1); continue
            }
            guard mayProceed(), now() < end else { break }
            guard ModePlan.identities(live, within: office),
                  live.contains(where: { $0.id == expected.first(where: \.main)?.id }) || enabling else {
                throw OmniError.message("模式执行期间出现未知屏幕或保留屏丢失。")
            }
            guard Set(live.map(\.id)) == Set(expected.map(\.id)) else {
                previous = nil; pause(0.1); continue
            }
            if let previous, DisconnectTopology.sameObservation(previous, live),
               !matching || TemporaryLayout.matches(expected, live) { return live }
            previous = live; pause(0.1)
        }
        throw OmniError.message("模式步骤的活动状态/完整排列未及时稳定；不会采用暂态读数。")
    }
}
