import Foundation

/// 命令行 `omnidisplay` 与 App 之间的收件箱：本机目录（Application Support，不随同步盘走），只有本用户可读写。
/// 命令行把请求写进 requests/，App 每 0.25 秒取一封，结果写回 responses/。
/// 超过 `maxAge` 还没被取走的请求作废——App 没开着时，绝不能等它几小时后启动再把旧的「断开」执行掉。
public enum AgentCommand: String, Codable, Sendable {
    case list, connect, disconnect, office, remote, rotate, saveLayout = "save-layout"
}

public struct AgentRequest: Codable, Sendable {
    public var id: String
    public var command: AgentCommand
    /// 第几块屏（从左到右，1 起）。
    public var number: Int?
    /// connect all。
    public var all: Bool?
    public var rotation: String?
    public var createdAt: Date
    public init(command: AgentCommand, number: Int? = nil, all: Bool? = nil, rotation: String? = nil, now: Date = Date()) {
        id = UUID().uuidString.lowercased(); self.command = command; self.number = number; self.all = all; self.rotation = rotation; createdAt = now
    }
}

public struct AgentScreen: Codable, Sendable, Equatable {
    public var number: Int
    public var connected: Bool
    public var main: Bool
    public var portrait: Bool
    public var rotation: Int
    public var name: String
    public var id: String
    public init(number: Int, display: Display) {
        self.number = number; connected = display.active; main = display.main; rotation = Int(display.rotation)
        portrait = display.height > display.width; name = display.name; id = display.id
    }
}

public struct AgentResponse: Codable, Sendable {
    public var id: String
    public var ok: Bool
    public var message: String
    public var phase: String?
    public var screens: [AgentScreen]
    public init(id: String, ok: Bool, message: String, phase: String? = nil, screens: [AgentScreen]) {
        self.id = id; self.ok = ok; self.message = message; self.phase = phase; self.screens = screens
    }
}

public enum AgentMailbox {
    public static let maxAge: TimeInterval = 20
    public static func directory(support: URL, instanceKey: String) -> URL {
        let safe = String(instanceKey.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" })
        return support.appendingPathComponent("OmniDisplay/Agent/\(safe)", isDirectory: true)
    }
    public static func requests(_ directory: URL) -> URL { directory.appendingPathComponent("requests", isDirectory: true) }
    public static func responses(_ directory: URL) -> URL { directory.appendingPathComponent("responses", isDirectory: true) }
    public static func prepare(_ directory: URL) throws {
        for sub in [directory, requests(directory), responses(directory)] {
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }
    public static func expired(_ request: AgentRequest, now: Date = Date()) -> Bool {
        now.timeIntervalSince(request.createdAt) > maxAge || request.createdAt.timeIntervalSince(now) > 5
    }
    /// 先写临时文件再改名，读的一方永远看不到半截。
    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        try encoder.encode(value).write(to: temp)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
        _ = try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: temp, to: url)
    }
    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(contentsOf: url))
    }
    /// 本机这个实例在不在跑：App 持有 Instances/<key>.lock 的排他锁。
    public static func instanceRunning(support: URL, instanceKey: String) -> Bool {
        let safe = String(instanceKey.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" })
        let path = support.appendingPathComponent("OmniDisplay/Instances/\(safe).lock").path
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 { flock(fd, LOCK_UN); return false }
        return errno == EWOULDBLOCK
    }
}
