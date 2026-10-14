import Foundation
import Darwin

public struct DisplayFieldDifference: Codable, Equatable {
    public var id: String
    public var field: String
    public var before: String?
    public var after: String?
}
public enum DisplayDifferences {
    /// Diagnostics only. Safety comparisons still use DisconnectTopology.
    public static func between(_ before: [Display], _ after: [Display]) -> [DisplayFieldDifference] {
        func fields(_ d: Display) -> [String: String] {
            guard let data = try? JSONEncoder().encode(d),
                  let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return values.mapValues { String(describing: $0) }
        }
        var result: [DisplayFieldDifference] = []
        for id in Set(before.map(\.id) + after.map(\.id)).sorted() {
            let old = before.filter { $0.id == id }, new = after.filter { $0.id == id }
            if old.count != 1 || new.count != 1 {
                result.append(.init(id: id, field: "identityCount", before: String(old.count), after: String(new.count)))
            }
            let a = old.first.map(fields) ?? [:], b = new.first.map(fields) ?? [:]
            for key in Set(a.keys).union(b.keys).sorted() where a[key] != b[key] {
                result.append(.init(id: id, field: key, before: a[key], after: b[key]))
            }
        }
        return result
    }
}

private struct AuditRecord<Payload: Encodable>: Encodable {
    let version = 1
    let nonce: String
    let phase: String
    let role: String
    let pid: Int32
    let parentPID: Int32
    let sequence: Int
    let date: Date
    let uptime: Double
    let event: String
    let payload: Payload
}
public struct AuditDetail: Codable {
    public var message: String
    public var values: [String: String]
    public init(_ message: String = "", _ values: [String: String] = [:]) { self.message = message; self.values = values }
}

/// Each writer exclusively creates its own file. Apply/restore/confirmation are
/// separate namespaces. No truncate, replace, shared array, or reopening an old file.
/// Append failures are visible on stderr and sticky; recovery never depends on logs.
public final class TransactionAudit {
    public let directory: URL
    public let nonce: String
    public let phase: String
    public let file: URL
    public private(set) var failure: String?
    private let role: String
    private let fd: Int32
    private var sequence = 0
    private let lock = NSLock()
    public init(directory: URL, nonce: String, phase: String, role: String) throws {
        guard UUID(uuidString: nonce) != nil, directory.lastPathComponent == nonce,
              ["apply", "restore", "confirmation"].contains(phase),
              ["owner", "worker", "observer"].contains(role) else { throw OmniError.message("审计会话参数无效。") }
        self.directory = directory; self.nonce = nonce; self.phase = phase; self.role = role
        let folder = directory.appendingPathComponent("audit/" + phase)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        file = folder.appendingPathComponent("\(role)-\(getpid())-\(UUID().uuidString).jsonl")
        fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_APPEND | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw OmniError.message("不能创建独立追加审计文件。") }
    }
    deinit { close(fd) }
    @discardableResult public func record<T: Encodable>(_ event: String, _ payload: T) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard failure == nil else { return false }
        do {
            sequence += 1
            let entry = AuditRecord(nonce: nonce, phase: phase, role: role, pid: getpid(), parentPID: getppid(), sequence: sequence,
                                    date: Date(), uptime: ProcessInfo.processInfo.systemUptime, event: event, payload: payload)
            var data = try JSONEncoder().encode(entry); data.append(10)
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count-offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw OmniError.message("追加审计写入失败。") }
                    offset += count
                }
            }
            return true
        } catch {
            failure = error.localizedDescription
            fputs("OmniDisplay audit failure: \(error.localizedDescription)\n", stderr)
            return false
        }
    }
}
