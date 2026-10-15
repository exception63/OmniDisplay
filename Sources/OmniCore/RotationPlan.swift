import Foundation

/// A user-requested quarter-turn; only the target changes mode dimensions or angle.
public enum RotationPlan {
    public static let angles = [0, 90, 180, 270]
    public static func layout(_ entry: [Display], target: String, degrees: Int) throws -> [Display] {
        guard angles.contains(degrees), (1...24).contains(entry.count),
              Set(entry.map(\.id)).count == entry.count, Set(entry.map(\.displayID)).count == entry.count,
              entry.filter(\.main).count == 1, TemporaryLayout.validArrangement(entry),
              entry.allSatisfy({ UUID(uuidString: $0.id) != nil && $0.active && !$0.mirrored &&
                  [0.0,90,180,270].contains($0.rotation) &&
                  (1...131072).contains($0.width) && (1...131072).contains($0.height) &&
                  $0.pixelWidth > 0 && $0.pixelHeight > 0 && $0.refresh.isFinite }),
              let selected = entry.first(where: { $0.id == target }) else {
            throw OmniError.message("当前排列或屏幕身份不适合旋转。")
        }
        var desired = entry
        let i = desired.firstIndex(where: { $0.id == target })!
        desired[i].rotation = Double(degrees)
        if (Int(selected.rotation) / 90) % 2 != (degrees / 90) % 2 {
            (desired[i].width, desired[i].height) = (desired[i].height, desired[i].width)
            (desired[i].pixelWidth, desired[i].pixelHeight) = (desired[i].pixelHeight, desired[i].pixelWidth)
        }
        if TemporaryLayout.validArrangement(desired) { return desired }
        // A connected row/column can be reflowed without changing order or the
        // perpendicular offsets. More complex unsupported geometry is rejected.
        for horizontal in [true, false] {
            let sorted = entry.sorted { horizontal ? $0.x < $1.x : $0.y < $1.y }
            guard zip(sorted, sorted.dropFirst()).allSatisfy({ a,b in
                TemporaryLayout.adjacent(a,b) && (horizontal ? Int64(a.x)+Int64(a.width)==Int64(b.x) : Int64(a.y)+Int64(a.height)==Int64(b.y))
            }), let main = sorted.firstIndex(where: \.main) else { continue }
            let map = Dictionary(uniqueKeysWithValues: desired.map { ($0.id, $0) })
            var cursor = -sorted.prefix(main).reduce(Int64(0)) { $0 + Int64(horizontal ? map[$1.id]!.width : map[$1.id]!.height) }
            var placed: [String: Display] = [:]
            for original in sorted {
                var d = map[original.id]!
                guard let position = Int32(exactly: cursor) else { throw OmniError.message("旋转后的排列超出范围。") }
                if horizontal { d.x = position } else { d.y = position }
                cursor += Int64(horizontal ? d.width : d.height); placed[d.id] = d
            }
            let result = entry.map { placed[$0.id]! }
            if TemporaryLayout.validArrangement(result) { return result }
        }
        throw OmniError.message("无法在保留主屏和顺序的同时安全排列；请先在系统设置简化排列。")
    }
    public static func make(_ request: Request) throws -> ModePlan {
        guard request.operation == .rotate, request.before.version == 1, request.office == request.before,
              request.before.boot != "unknown", request.confirmedPhysical,
              let target = request.target, let degrees = request.rotationDegrees,
              request.before.displays.contains(where: { $0.id == request.keep && $0.active }) else {
            throw OmniError.message("旋转请求缺少目标、入口或保留屏。")
        }
        let desired = try layout(request.before.displays, target: target, degrees: degrees)
        _ = try updatedBaseline(request, desired: desired)
        let steps = TemporaryLayout.matches(desired, request.before.displays) ? [] : [ModeStep(action: .arrange, target: target, before: request.before.displays, after: desired)]
        return ModePlan(steps: steps, desired: desired)
    }
    /// Recognize only the planned before/after or a target rotated at old origins.
    /// Unknown peer movement, hotplug and identity changes must not be overwritten.
    public static func recognizes(_ live: [Display], request: Request, desired: [Display]) -> Bool {
        if TemporaryLayout.matches(request.before.displays, live) || TemporaryLayout.matches(desired, live) { return true }
        let intermediate = request.before.displays.map { old -> Display in
            guard old.id == request.target, var rotated = desired.first(where: { $0.id == old.id }) else { return old }
            rotated.x = old.x; rotated.y = old.y; return rotated
        }
        return TemporaryLayout.matches(intermediate, live)
    }
    public static func validateStep(_ step: ModeStep, request: Request, restoring: Bool) throws {
        let plan = try make(request)
        let allowed = restoring
            ? step.action == .arrange && step.target == request.target && TemporaryLayout.matches(step.after,request.before.displays) && recognizes(step.before,request:request,desired:plan.desired)
            : plan.steps.first == step
        guard allowed else { throw OmniError.message("旋转步骤不属于本次确认的方向或恢复快照。") }
    }
    public static func updatedBaseline(_ request: Request, desired: [Display]) throws -> Snapshot {
        guard let old = request.rotationBaseline else { return Snapshot(boot: request.before.boot, displays: desired) }
        if Set(old.displays.map(\.id)) == Set(desired.map(\.id)) {
            guard ModePlan.identities(desired, within: old.displays) else { throw OmniError.message("办公室屏幕身份变化，请重新保存排列。") }
            return Snapshot(boot: request.before.boot, displays: desired)
        }
        // In remote mode, keep the complete office layout while updating the
        // target's orientation there. Never promote one active screen to a full baseline.
        guard old.boot == request.before.boot, request.before.displays.count == 1,
              let current = request.before.displays.first,
              var saved = old.displays.first(where: { $0.id == current.id }), let degrees = request.rotationDegrees else {
            throw OmniError.message("请先恢复办公室完整排列，再调整方向。")
        }
        saved.x = 0; saved.y = 0; saved.main = true
        guard TemporaryLayout.matches([saved], [current]) else { throw OmniError.message("当前单屏与办公室基线不同，请先核对排列。") }
        return Snapshot(boot: old.boot, displays: try layout(old.displays, target: current.id, degrees: degrees))
    }
}

public enum RotationBaselineCommit {
    /// The mode baseline is the authoritative atomic commit. The former layout
    /// file remains as history; AppModel prefers this newer confirmed baseline.
    public static func commit(request: Request, desired: [Display], directory: URL) throws {
        let root = directory.deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent(request.simulation ? "demo-mode-office.json" : "mode-office.json")
        let current: Snapshot? = FileManager.default.fileExists(atPath: url.path) ? try Files.read(Snapshot.self, from: url) : nil
        guard current == request.rotationBaseline else { throw OmniError.message("办公室基线已被其他操作修改；保留当前方向，未覆盖基线。") }
        let updated = try RotationPlan.updatedBaseline(request, desired: desired)
        if let current { try Files.write(current, to: directory.appendingPathComponent("rotation-prior-baseline.json")) }
        try Files.write(updated, to: directory.appendingPathComponent("rotation-confirmed-baseline.json"))
        try Files.write(updated, to: url)
    }
}
