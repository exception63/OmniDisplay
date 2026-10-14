import Foundation

/// Immutable full layout plus one deterministic, constrained temporary layout.
/// No observed/reflowed geometry is ever promoted to the full-layout baseline.
public struct LayoutSession: Codable, Sendable {
    public var original: Snapshot
    public var temporary: Snapshot
    public var target: String
    public static func make(original: Snapshot, target: String) throws -> LayoutSession {
        let plan = try TemporaryLayout.plan(original.displays, removing: target)
        var temporary = original; temporary.displays = plan
        return LayoutSession(original: original, temporary: temporary, target: target)
    }
    public func validate(boot: String) throws {
        guard original.version == 1, temporary.version == 1, original.boot == boot, temporary.boot == boot,
              boot != "unknown", try TemporaryLayout.plan(original.displays, removing: target) == temporary.displays else {
            throw OmniError.message("完整排列/临时排列记录无效或已过期。")
        }
    }
    public func validateRestore(_ current: [Display]) throws {
        let saved = original.displays
        guard Set(current.map(\.id)).count == current.count,
              Set(current.map(\.displayID)).count == current.count,
              Set(current.map(\.id)) == Set(saved.map(\.id)), peersMayRestore(current),
              current.allSatisfy({ live in saved.contains(where: {
                  $0.id == live.id && live.active && !live.mirrored && $0.main == live.main &&
                  $0.builtin == live.builtin && $0.vendor == live.vendor && $0.model == live.model && $0.serial == live.serial
              }) }) else { throw OmniError.message("重连期间出现未知屏幕、主屏或排列变化；停止覆盖布局。") }
    }
    public func simulatedDisconnected() -> [Display] {
        temporary.displays + original.displays.filter { $0.id == target }.map { d in
            var offline=d; offline.active=false; offline.main=false; return offline
        }
    }
    public func simulatedRestore(_ current: [Display]) throws -> [Display] {
        // Even on interference, recovery only enables the target; it never removes new peers.
        let enabled = try TargetRecovery.simulated(before: original.displays, current: current, target: target)
        guard peersMayRestore(current.filter(\.active)), (try? validateRestore(enabled)) != nil else { return enabled }
        return original.displays.map { d in
            var saved=d; if let live=enabled.first(where:{$0.id==d.id}) { saved.displayID=live.displayID }; return saved
        }
    }
    public func matchesTemporary(_ current: [Display]) -> Bool { TemporaryLayout.matches(temporary.displays, current) }
    public func matchesOriginal(_ current: [Display]) -> Bool { TemporaryLayout.matches(original.displays, current) }
    /// Only a known original or authorized temporary peer arrangement may be replayed.
    public func peersMayRestore(_ current: [Display]) -> Bool {
        let peers = current.filter { $0.id != target }
        return matchesTemporary(peers) || TemporaryLayout.matches(original.displays.filter { $0.id != target }, peers)
    }
}

public enum TemporaryLayout {
    private static func right(_ d: Display) -> Int64 { Int64(d.x) + Int64(d.width) }
    private static func bottom(_ d: Display) -> Int64 { Int64(d.y) + Int64(d.height) }
    private static func overlapX(_ a: Display, _ b: Display) -> Bool { min(right(a),right(b)) > max(Int64(a.x),Int64(b.x)) }
    private static func overlapY(_ a: Display, _ b: Display) -> Bool { min(bottom(a),bottom(b)) > max(Int64(a.y),Int64(b.y)) }
    public static func adjacent(_ a: Display, _ b: Display) -> Bool {
        ((right(a) == Int64(b.x) || right(b) == Int64(a.x)) && overlapY(a,b)) ||
        ((bottom(a) == Int64(b.y) || bottom(b) == Int64(a.y)) && overlapX(a,b))
    }
    private static func nonoverlapping(_ values: [Display]) -> Bool {
        for i in values.indices { for j in values.indices where i < j {
            if overlapX(values[i],values[j]) && overlapY(values[i],values[j]) { return false }
        } }; return true
    }
    private static func components(_ values: [Display]) -> [[Display]] {
        var remaining = values.sorted { $0.id < $1.id }, result: [[Display]] = []
        while !remaining.isEmpty {
            var group = [remaining.removeFirst()], changed = true
            while changed {
                changed = false
                for i in remaining.indices.reversed() where group.contains(where: { adjacent($0, remaining[i]) }) {
                    group.append(remaining.remove(at:i)); changed = true
                }
            }
            result.append(group.sorted { $0.id < $1.id })
        }; return result
    }
    /// Preserve every unambiguous left/right and above/below relation, not centers.
    private static func ordered(_ original: [Display], _ current: [Display]) -> Bool {
        let map = Dictionary(uniqueKeysWithValues: current.map { ($0.id,$0) })
        for a in original { for b in original where a.id != b.id {
            guard let x = map[a.id], let y = map[b.id] else { continue }
            if right(a) <= Int64(b.x) && right(x) > Int64(y.x) { return false }
            if bottom(a) <= Int64(b.y) && bottom(x) > Int64(y.y) { return false }
        } }; return true
    }
    public static func plan(_ original: [Display], removing target: String) throws -> [Display] {
        guard original.count > 1, original.count <= 24, Set(original.map(\.id)).count == original.count, Set(original.map(\.displayID)).count == original.count,
              original.allSatisfy({ UUID(uuidString: $0.id) != nil && $0.rotation.isFinite && [0.0,90,180,270].contains($0.rotation) && $0.refresh.isFinite && $0.active && !$0.mirrored && $0.width > 0 && $0.height > 0 && $0.width <= 131072 && $0.height <= 131072 }),
              original.filter(\.main).count == 1, let anchor = original.first(where: \.main),
              let removed = original.first(where: { $0.id == target && !$0.main && !$0.builtin }),
              nonoverlapping(original), components(original).count == 1 else {
            throw OmniError.message("需完整、无重叠且边缘相连的实体屏排列；主屏/内置屏不能移除。")
        }
        let peers = original.filter { $0.id != target }
        var groups = components(peers)
        guard let index = groups.firstIndex(where: { $0.contains(where: { $0.id == anchor.id }) }) else { throw OmniError.message("保留主屏不存在。") }
        var placed = groups.remove(at:index)
        while !groups.isEmpty {
            var best: (index: Int, moved: [Display], cost: Int64, tie: String)?
            for (i, group) in groups.enumerated() {
                for a in placed { for b in group {
                    // Only axis translations close the removed screen's hole. Keep
                    // the orthogonal offsets and each surviving component rigid.
                    let shifts: [(Int64,Int64)] = [(right(a)-Int64(b.x),0),(Int64(a.x)-right(b),0),
                        (0,bottom(a)-Int64(b.y)),(0,Int64(a.y)-bottom(b))]
                    for (dx,dy) in shifts {
                        guard abs(dx) <= Int64(removed.width), abs(dy) <= Int64(removed.height) else { continue }
                        var moved: [Display] = []
                        for var d in group {
                            guard let x = Int32(exactly:Int64(d.x)+dx), let y = Int32(exactly:Int64(d.y)+dy) else { break }
                            d.x=x; d.y=y; moved.append(d)
                        }
                        let combined=placed+moved
                        guard moved.count==group.count, nonoverlapping(combined), ordered(peers,combined),
                              moved.contains(where:{ b in placed.contains(where:{adjacent($0,b)}) }) else { continue }
                        let cost=abs(dx)+abs(dy), tie="\(group[0].id):\(dx):\(dy)"
                        if best == nil || cost < best!.cost || (cost == best!.cost && tie < best!.tie) { best=(i,moved,cost,tie) }
                    }
                } }
            }
            guard let best else { throw OmniError.message("该拓扑无法在保留顺序/旋转的约束内靠拢，未执行断开。") }
            placed += best.moved; groups.remove(at:best.index)
        }
        guard components(placed).count == 1, nonoverlapping(placed), ordered(peers,placed),
              placed.first(where:{$0.id==anchor.id}) == anchor else { throw OmniError.message("临时排列未通过几何约束。") }
        let map=Dictionary(uniqueKeysWithValues:placed.map{($0.id,$0)})
        return peers.map{map[$0.id]!}
    }
    public static func matches(_ expected: [Display], _ current: [Display]) -> Bool {
        guard Set(expected.map(\.id)).count == expected.count, Set(current.map(\.id)).count == current.count,
              Set(current.map(\.displayID)).count == current.count, expected.count == current.count else { return false }
        let map=Dictionary(uniqueKeysWithValues:current.map{($0.id,$0)})
        return expected.allSatisfy { saved in
            guard var live=map[saved.id] else{return false}
            live.name=saved.name; live.displayID=saved.displayID
            return live == saved
        }
    }
}
