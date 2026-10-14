import Foundation
import Darwin

/// Simulation is a separate bundle, never a persisted mode of the real app.
public struct AppLaunch: Equatable {
    public let simulation: Bool
    public let demoCount: Int
    public let dataDirectory: URL
    public let instanceKey: String
    public var notificationName: String { instanceKey + ".ShowManager" }
    public static func resolve(arguments: [String], bundleID: String, simulationBundle: Bool,
                               support: URL, savedProductionDirectory: String? = nil) throws -> AppLaunch {
        guard simulationBundle == bundleID.hasSuffix(".simulation") else {
            throw OmniError.message("应用身份与模拟标记不一致，请重新构建应用。")
        }
        if !simulationBundle && arguments.contains("--demo") {
            throw OmniError.message("正式版不接受 --demo。请运行 scripts/build.sh --simulation，并打开 OmniDisplay Simulation.app；正式屏幕未改变。")
        }
        func value(_ flag: String) throws -> String? {
            guard let i = arguments.firstIndex(of: flag) else { return nil }
            guard i + 1 < arguments.count, !arguments[i + 1].hasPrefix("--"), !arguments[i + 1].isEmpty else {
                throw OmniError.message("启动参数 \(flag) 缺少值。")
            }
            return arguments[i + 1]
        }
        let requestedDirectory = try value("--data-dir")
        let countString = try value("--demo")
        var count = 0
        if simulationBundle {
            guard let n = Int(countString ?? "4"), (1...24).contains(n) else {
                throw OmniError.message("模拟屏幕数量必须为1至24。")
            }
            count = n
        }
        let base = requestedDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? (!simulationBundle ? savedProductionDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) } : nil)
            ?? support.appendingPathComponent("OmniDisplay", isDirectory: true)
        // Even an explicit shared --data-dir cannot overwrite production records.
        let directory = simulationBundle ? base.appendingPathComponent("Simulation", isDirectory: true) : base
        return AppLaunch(simulation: simulationBundle, demoCount: count, dataDirectory: directory.standardizedFileURL,
                         instanceKey: bundleID + (simulationBundle ? ".demo" : ".production"))
    }
}

/// The descriptor stays alive for the application's lifetime. No stale PID locks.
public final class AppInstanceLock {
    private let descriptor: Int32
    public init?(directory: URL, key: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let safeKey = key.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" }
        let path = directory.appendingPathComponent(String(safeKey) + ".lock").path
        let fd = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw OmniError.message("无法创建应用实例锁，请检查数据目录。") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno; close(fd)
            if code == EWOULDBLOCK { return nil }
            throw OmniError.message("无法检查应用实例锁，已停止启动。")
        }
        descriptor = fd
    }
    deinit { close(descriptor) }
}
