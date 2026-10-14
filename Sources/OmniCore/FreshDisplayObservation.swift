import Foundation
import CoreGraphics
import AppKit
import Darwin

/// Exit code 75 marks only an observer that exhausted its local settle window.
/// Identity, transport, decoding and cancellation errors remain fatal.
public struct ObservationNotSettled: LocalizedError {
    public init() {}
    public var errorDescription: String? { "独立只读观察期间仍在重配，未获得一致快照。" }
}

/// Receipt from a newly exec'd read-only observer, never the mutation process's CG cache.
public struct DisplayObservation: Codable {
    public var nonce: String
    public var pid: Int32
    public var boot: String
    public var started: Double
    public var completed: Double
    public var generation: UInt64
    public var displays: [Display]

    public func validate(nonce expected: String, childPID: Int32, boot expectedBoot: String,
                         launched: Double, now: Double) throws -> [Display] {
        guard nonce == expected, pid == childPID, pid != getpid(), boot == expectedBoot,
              expectedBoot != "unknown", started.isFinite, completed.isFinite,
              started >= launched, completed >= started, completed <= now,
              now - launched <= 1.5, !displays.isEmpty,
              Set(displays.map(\.id)).count == displays.count,
              Set(displays.map(\.displayID)).count == displays.count,
              displays.allSatisfy({ $0.active && UUID(uuidString: $0.id) != nil }) else {
            throw OmniError.message("独立观察结果过期、身份不符或不完整，停止后续写入。")
        }
        return displays
    }
}

/// Callback only invalidates observations; never queries or mutates displays.
public final class DisplayObservationEpoch {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var pending: Set<UInt32> = []
    public init() {}
    public func changed(display: UInt32, beginning: Bool) {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
        if beginning { pending.insert(display) } else { pending.remove(display) }
    }
    public func state() -> (generation: UInt64, pending: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (generation, !pending.isEmpty)
    }
    public func invalidate() {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
    }
}

/// Scoped read-only invalidation monitor. Its generation is local to this
/// process and must never be compared with a different observer's generation.
final class DisplayObservationMonitor {
    let epoch = DisplayObservationEpoch()
    private let callback: CGDisplayReconfigurationCallBack = { display, flags, context in
        guard let context else { return }
        Unmanaged<DisplayObservationEpoch>.fromOpaque(context).takeUnretainedValue()
            .changed(display: display, beginning: flags.contains(.beginConfigurationFlag))
    }
    private var appNotice: NSObjectProtocol?
    init() throws {
        let pointer = Unmanaged.passUnretained(epoch).toOpaque()
        guard CGDisplayRegisterReconfigurationCallback(callback, pointer) == .success else {
            throw OmniError.message("无法注册只读重配观察。")
        }
        appNotice = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: nil) { [epoch] _ in epoch.invalidate() }
    }
    deinit {
        CGDisplayRemoveReconfigurationCallback(callback, Unmanaged.passUnretained(epoch).toOpaque())
        if let appNotice { NotificationCenter.default.removeObserver(appNotice) }
    }
}

public struct DisplayObservationStability {
    private var previous: [Display]?
    private var priorGeneration: UInt64?
    public init() {}
    public mutating func observe(_ sample: [Display], before: (generation: UInt64, pending: Bool),
                                 after: (generation: UInt64, pending: Bool)) -> Bool {
        guard !before.pending, !after.pending, before.generation == after.generation else {
            previous = nil; priorGeneration = nil; return false
        }
        let stable = priorGeneration == after.generation && previous.map { DisconnectTopology.sameObservation($0, sample) } == true
        previous = sample; priorGeneration = after.generation
        return stable
    }
}

public struct ObserverSample: Codable {
    var index: Int; var started: Double; var completed: Double; var deadline: Double
    var generationBefore: UInt64; var generationAfter: UInt64; var pendingBefore: Bool; var pendingAfter: Bool
    var displays: [Display]?; var differences: [DisplayFieldDifference]; var outcome: String; var error: String?
}
public enum DisplayObservationCollector {
    public static func collect(nonce: String, pid: Int32, boot: String, started: Double,
                               read: () throws -> [Display], state: () -> (generation: UInt64, pending: Bool),
                               now: () -> Double, pause: (Double) -> Void,
                               audit: (ObserverSample) -> Void = { _ in }) throws -> DisplayObservation {
        var stability = DisplayObservationStability()
        var previous: [Display] = [], index = 0
        while now() - started < 0.7 {
            let before = state(), readStarted = now()
            index += 1
            let sample: [Display]
            do { sample = try read() }
            catch {
                let after = state()
                audit(ObserverSample(index: index, started: readStarted, completed: now(), deadline: started+0.7,
                    generationBefore: before.generation, generationAfter: after.generation, pendingBefore: before.pending, pendingAfter: after.pending,
                    displays: nil, differences: [], outcome: "readFailed", error: error.localizedDescription))
                throw error
            }
            let after = state(), completed = now()
            let stable = stability.observe(sample, before: before, after: after)
            let inTime = completed-started < 0.7
            audit(ObserverSample(index: index, started: readStarted, completed: completed, deadline: started+0.7,
                generationBefore: before.generation, generationAfter: after.generation, pendingBefore: before.pending, pendingAfter: after.pending,
                displays: sample, differences: DisplayDifferences.between(previous, sample), outcome: !inTime ? "deadlineExceeded" : stable ? "stable" : "awaitingStableEpoch", error: nil))
            previous = sample
            if stable && inTime {
                return DisplayObservation(nonce: nonce, pid: pid, boot: boot,
                                          started: started, completed: completed,
                                          generation: after.generation, displays: sample)
            }
            if !inTime { break }
            pause(0.03)
        }
        throw ObservationNotSettled()
    }
}

public enum FreshDisplayObserver {
    public static func pumpEvents(for interval: Double) {
        HelperEventLoop.wait(interval)
    }
    /// Main-thread entry point of --observe-displays. No request, consent, backend
    /// mutation, or recovery commands are accepted by this branch.
    public static func collect(nonce: String, journal: TransactionAudit? = nil) throws -> DisplayObservation {
        guard Thread.isMainThread, UUID(uuidString: nonce) != nil else { throw OmniError.message("只读观察参数无效。") }
        let started = ProcessInfo.processInfo.systemUptime
        let monitor = try DisplayObservationMonitor()
        defer { withExtendedLifetime(monitor) {} }
        let backend = CoreGraphicsBackend(diagnostics: journal)
        return try DisplayObservationCollector.collect(nonce: nonce, pid: getpid(), boot: CoreGraphicsBackend.bootID, started: started,
            read: { try backend.list() }, state: { monitor.epoch.state() }, now: { ProcessInfo.processInfo.systemUptime },
            pause: { pumpEvents(for: $0) }, audit: { journal?.record("observerSample", $0) })
    }

    public static func read(executable: URL = URL(fileURLWithPath: CommandLine.arguments[0]),
                            cancelled: () -> Bool = { false }, journal: TransactionAudit? = nil, audit: (DisplayObservation) -> Void = { _ in }) throws -> [Display] {
        let nonce = UUID().uuidString
        let readStarted = ProcessInfo.processInfo.systemUptime
        journal?.record("freshReadStarted", AuditDetail("", ["observerNonce": nonce, "startedUptime": String(readStarted)]))
        do {
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("OmniDisplay-observe-" + nonce)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: scratch) }
            let output = scratch.appendingPathComponent("snapshot.json")
            guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw OmniError.message("不能创建只读观察回执。") }
            let handle = try FileHandle(forWritingTo: output)
            defer { try? handle.close() }
            let child = Process(); child.executableURL = executable
            child.arguments = ["--observe-displays", nonce]
            if let journal { child.arguments! += [journal.directory.path, journal.phase] }
            child.standardOutput = handle; child.standardError = FileHandle.nullDevice
            let launched = ProcessInfo.processInfo.systemUptime
            let boot = CoreGraphicsBackend.bootID
            guard !cancelled() else { throw OmniError.message("只读观察已取消。") }
            try child.run()
            journal?.record("observerLaunched", AuditDetail("", ["observerNonce": nonce, "childPID": String(child.processIdentifier), "launched": String(launched), "transportDeadline": String(launched+1.2)]))
            while child.isRunning {
                if cancelled() || ProcessInfo.processInfo.systemUptime - launched >= 1.2 {
                    journal?.record("observerTerminationRequested", AuditDetail("cancelledOrTransportDeadline", ["childPID": String(child.processIdentifier)]))
                    child.terminate()
                    if child.isRunning { kill(child.processIdentifier, SIGKILL) }
                    throw OmniError.message("独立只读观察已取消或超时，未采用旧进程读数。")
                }
                HelperEventLoop.wait(0.01)
            }
            journal?.record("observerExited", AuditDetail("", ["childPID": String(child.processIdentifier), "terminationStatus": String(child.terminationStatus), "terminationReason": String(describing: child.terminationReason)]))
            let size = ((try FileManager.default.attributesOfItem(atPath: output.path)[.size]) as? NSNumber)?.intValue ?? Int.max
            if !cancelled(), child.terminationStatus == 75 { throw ObservationNotSettled() }
            guard !cancelled(), child.terminationStatus == 0, size <= 262144 else {
                throw OmniError.message("独立只读观察失败，未采用旧进程读数。")
            }
            let observation = try JSONDecoder().decode(DisplayObservation.self, from: Data(contentsOf: output))
            let result = try observation.validate(nonce: nonce, childPID: child.processIdentifier, boot: boot,
                                                  launched: launched, now: ProcessInfo.processInfo.systemUptime)
            journal?.record("validatedObservation", observation)
            audit(observation)
            return result
        } catch {
            journal?.record("freshReadFailed", AuditDetail(error.localizedDescription, ["observerNonce": nonce, "started": String(readStarted), "completed": String(ProcessInfo.processInfo.systemUptime)]))
            throw error
        }
    }
}
