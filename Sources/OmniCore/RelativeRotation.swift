import Foundation

/// Directions describe the image as viewed on a stationary physical panel.
/// Apple's CGDisplayRotation describes the physical panel's clockwise angle:
/// https://developer.apple.com/documentation/coregraphics/cgdisplayrotation(_:)
/// Compensating image rotation is the inverse. Native setter and getter share
/// the same absolute degrees (see References/displayplacer/MonitorPanel.m).
public enum RelativeRotation: String, CaseIterable, Sendable {
    case counterclockwise, clockwise, flip
    public var title: String {
        switch self { case .counterclockwise: return "逆时针90°"; case .clockwise: return "顺时针90°"; case .flip: return "翻转180°" }
    }
    public var symbol: String {
        switch self { case .counterclockwise: return "rotate.left"; case .clockwise: return "rotate.right"; case .flip: return "arrow.uturn.down" }
    }
    public func target(from current: Double) throws -> Int {
        guard current.isFinite, [0.0,90,180,270].contains(current) else { throw OmniError.message("当前方向尚未稳定，未采用缓存角度。") }
        let delta = self == .clockwise ? -90 : self == .counterclockwise ? 90 : 180
        return (Int(current) + delta + 360) % 360
    }
    public func prepare(target: String, baseline: Snapshot?, simulation: Bool, read: () throws -> Snapshot) throws -> Request {
        let entry = try read() // always called for each click; never a default-zero angle
        guard entry.boot != "unknown", let display=entry.displays.first(where: { $0.id == target && $0.active }) else { throw OmniError.message("目标屏幕已变化，请重新读取。") }
        let keep=entry.displays.first(where: { $0.id != target && $0.main })?.id ?? entry.displays.first(where: { $0.id != target })?.id ?? target
        var request=Request(operation:.rotate,before:entry,office:entry,keep:keep,confirmedPhysical:true,simulation:simulation,target:target)
        request.rotationDegrees=try self.target(from:display.rotation);request.rotationBaseline=baseline
        _ = try RotationPlan.make(request)
        return request
    }
    public static func validateConfirmation(_ request: Request, current: Snapshot) throws {
        guard current.boot == request.before.boot, TemporaryLayout.matches(request.before.displays,current.displays) else {
            throw OmniError.message("画面或排列已变化，请重新点击方向按钮；未沿用旧角度。")
        }
    }
}
