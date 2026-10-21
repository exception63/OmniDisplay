import Foundation

/// 「第几块屏」：从左到右数。全部连着时看现场；有断开的，按断开前那份完整排列数，
/// 这样断开中间一块，后面的不会改号。参考排列取覆盖已知屏幕最多的一份（同样多按给的顺序）。
public enum ScreenNumbering {
    public static func ordered(current: [Display], references: [Snapshot?]) -> [Display] {
        guard !current.isEmpty else { return [] }
        let known = Set(current.map(\.id))
        let reference: [Display]
        if current.allSatisfy(\.active) {
            reference = current
        } else {
            // 覆盖已知屏幕最多的那份（同样多取靠前的）；新接进来、参考里没有的排到最后，已有的不改号。
            let candidates = references.compactMap { $0 }
            func coverage(_ snapshot: Snapshot) -> Int { known.intersection(snapshot.displays.map(\.id)).count }
            let top = candidates.map(coverage).max() ?? 0
            reference = top > 0 ? candidates.first { coverage($0) == top }!.displays : current
        }
        var order = reference.filter { known.contains($0.id) }.sorted(by: leftToRight).map(\.id)
        order += current.filter { !order.contains($0.id) }.sorted(by: leftToRight).map(\.id)
        return order.compactMap { id in current.first { $0.id == id } }
    }

    static func leftToRight(_ a: Display, _ b: Display) -> Bool { a.x != b.x ? a.x < b.x : a.y < b.y }
}
