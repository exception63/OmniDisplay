import Foundation
import SwiftUI
import AppKit
import OmniCore

@MainActor final class AppModel: ObservableObject {
    @Published var modePreview: ModePreview?
    @Published var modeKeep = ""
    @Published var officeLayout: Snapshot?
    @Published var requestedInputs: [String: UInt16] = [:]
    @Published var displays: [Display] = []
    @Published var selectedID: String?
    @Published var status = "只读检测中…"
    @Published var error: String?
    @Published var receipt: Receipt?
    @Published var confirmation: OmniCore.Operation?
    @Published var retained = ""
    @Published var physicalConfirmed = false
    @Published var testRiskAcknowledged = false
    @Published var actionDisplay: Display?
    var onTransactionUIChange: (() -> Void)?
    var onShowConfirmation: (() -> Void)?
    @Published private(set) var transactionRequest: Request?
    @Published private(set) var decisionPending = false
    var onShowManager: (() -> Void)?
    @Published var inputPortMappings: [String: [InputPortMapping]] = [:]
    @Published var now = Date()
    @Published var inputProbes: [String: InputProbe] = [:]
    @Published var probingInput: String?
    private var inputProcess: Process?
    let backend = CoreGraphicsBackend()
    let dataDirectory: URL
    let demoCount: Int
    private var registry: Snapshot?
    private var layoutSession: LayoutSession?
    private var modeBaselineError: String?
    private var sessionLoadError: String?
    private var sessionURL: URL { dataDirectory.appendingPathComponent(simulation ? "demo-layout-session.json" : "layout-session.json") }
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var process: Process?
    private var journal: URL?
    private var sentExecute = false
    private var requestTopology: [Display]?
    private var lastRefresh = Date.distantPast
    var simulation: Bool { demoCount > 0 }
    var busy: Bool { journal != nil && !(receipt?.phase.terminal ?? false) }
    var countdown: Int { max(0, Int(ceil((receipt?.deadline ?? now).timeIntervalSince(now)))) }
    var activeCount: Int { displays.filter(\.active).count }
    var selected: Display? { displays.first { $0.id == selectedID } }
    var sortedDisplays: [Display] { displays.sorted { if $0.main != $1.main { return $0.main }; return $0.id < $1.id } }
    var currentBoot: String { simulation ? "simulation" : CoreGraphicsBackend.bootID }
    init(configuration: AppLaunch) {
        dataDirectory = configuration.dataDirectory
        demoCount = configuration.demoCount
        do {
            try FileManager.default.createDirectory(at: dataDirectory.appendingPathComponent("Transactions"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = dataDirectory.appendingPathComponent(simulation ? "demo-identities.json" : "identities.json")
            if FileManager.default.fileExists(atPath: file.path) { registry = try Files.read(Snapshot.self, from: file) }
            // One-time import: keep only identity/connection history from the old office file, never replay it.
            if registry == nil && !simulation { registry = try? Files.read(Snapshot.self, from: dataDirectory.appendingPathComponent("office.json")) }
            if registry?.version != 1 { registry = nil }
        } catch { self.error = "读取身份缓存失败：\(error.localizedDescription)" }
        if simulation { displays = Display.samples(demoCount); registry = Snapshot(boot: "simulation", displays: displays) }
        inputPortMappings = (try? Files.read([String: [InputPortMapping]].self, from: dataDirectory.appendingPathComponent("input-ports.json"))) ?? [:]
        layout = try? Files.read(Snapshot.self, from: dataDirectory.appendingPathComponent(simulation ? "demo-layout.json" : "layout.json"))
        if FileManager.default.fileExists(atPath: sessionURL.path) {
            do { layoutSession = try Files.read(LayoutSession.self, from: sessionURL) }
            catch { sessionLoadError = "完整排列记录无法读取；已阻止覆盖和切换，请保留记录供检查。"; self.error = sessionLoadError }
        }
        if FileManager.default.fileExists(atPath:modeOfficeURL.path) {
            do { officeLayout=try Files.read(Snapshot.self,from:modeOfficeURL) }
            catch { modeBaselineError="办公室基线损坏，已阻止模式切换；请保留记录供检查。";self.error=modeBaselineError }
        }
        refresh()
        modeKeep = displays.first(where: { $0.main && $0.active })?.id ?? ""
        if layout == nil { saveCurrentLayout() }
        status = simulation ? "模拟模式 · 不改变真实显示器" : "点击一块屏幕，选择连接或断开"
        if let path = try? Files.read(String.self, from: activeURL) {
            let candidate = URL(fileURLWithPath: path)
            if candidate.deletingLastPathComponent().standardizedFileURL == dataDirectory.appendingPathComponent("Transactions").standardizedFileURL,
               let request = try? Files.read(Request.self, from: candidate.appendingPathComponent("request.json")), request.simulation == simulation,
               let result = try? Files.read(Receipt.self, from: candidate.appendingPathComponent("receipt.json")) {
                if !result.phase.terminal { journal = candidate; receipt = result; sentExecute = true; transactionRequest = request }
                else if result.phase == .failed, ModePlan.isMode(request.operation), !TemporaryLayout.matches(request.office.displays,displays.filter(\.active)) {
                    error="上次模式恢复未完成。请核对实体画面后选择办公室恢复；原基线与事务入口均已保留。"
                }
            }
        }
        retireRestoredSession()
        timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.refresh() } })
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in
                guard let self else { return }; if self.busy { self.cancel() }; self.confirmation = nil; self.modePreview = nil; self.physicalConfirmed = false; self.refresh()
            } })
        }
    }
    private var modeOfficeURL: URL { dataDirectory.appendingPathComponent(simulation ? "demo-mode-office.json" : "mode-office.json") }
    var modeScreens: [Display] { (officeLayout?.displays ?? layoutSession?.original.displays ?? displays).sorted { $0.main && !$1.main } }
    var modeStatus: String { ModePlan.status(current:displays.filter(\.active),office:officeLayout ?? layoutSession?.original ?? layout) }
    func prepareMode(_ action: OmniCore.Operation) {
        guard !busy, probingInput == nil, ModePlan.isMode(action) else { return }
        if let modeBaselineError { error=modeBaselineError;return }
        do {
            refresh()
            let entry = Snapshot(boot:currentBoot,displays:displays.filter(\.active))
            let baseline = officeLayout ?? layoutSession?.original ?? layout ?? entry
            guard baseline.displays.allSatisfy(\.active), baseline.boot == currentBoot else { throw OmniError.message("办公室完整基线缺失或跨开机；请先连齐屏幕，以当前排列为准。") }
            let keep = action == .officeMode ? (baseline.displays.first(where: \.main)?.id ?? "") : modeKeep
            let request = Request(operation:action,before:entry,office:baseline,keep:keep,confirmedPhysical:true,simulation:simulation,target:keep)
            let plan = try ModePlan.make(request)
            if plan.steps.isEmpty { status = "当前硬件已符合所选模式。"; return }
            actionDisplay=nil;onShowManager?();modePreview=ModePreview(request:request)
        } catch { self.error=error.localizedDescription }
    }
    func executeMode(_ preview: ModePreview, confirmed: Bool) {
        guard confirmed, !busy, modePreview?.id == preview.id else { return }
        do {
            refresh()
            var request=preview.request
            guard TemporaryLayout.matches(request.before.displays,displays.filter(\.active)) else { throw OmniError.message("预览后屏幕状态变化，请重新选择模式。") }
            _ = try ModePlan.make(request)
            if !simulation { request.liveConsent = try LiveTestConsent.grant(request:request,confirmedTarget:request.keep,riskAcknowledged:confirmed) }
            // Persist once before any worker; no intermediate checkpoint becomes the office baseline.
            try Files.write(request.office,to:modeOfficeURL);officeLayout=request.office
            try launch(request);modePreview=nil
        } catch { self.error=error.localizedDescription }
    }
    private var activeURL: URL { dataDirectory.appendingPathComponent(simulation ? "demo-active.json" : "active.json") }
    private func retireRestoredSession() {
        guard !busy, let session = layoutSession, session.original.boot == currentBoot,
              !RecoveryEngine.operationIsRunning(parent: dataDirectory.appendingPathComponent("Transactions")),
              session.matchesOriginal(displays.filter(\.active)) else { return }
        do {
            let fresh = simulation ? displays.filter(\.active) : try backend.list()
            guard session.matchesOriginal(fresh), !RecoveryEngine.operationIsRunning(parent: dataDirectory.appendingPathComponent("Transactions")) else { return }
            // Preserve the immutable completed snapshot before retiring the active guard.
            let archive = dataDirectory.appendingPathComponent("CompletedLayouts")
            try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
            try Files.write(session, to: archive.appendingPathComponent(UUID().uuidString + ".json"))
            try FileManager.default.removeItem(at: sessionURL)
            layoutSession = nil
        } catch { self.error = "完整排列已恢复，但记录归档失败：\(error.localizedDescription)" }
    }
    func saveCurrentLayout() {
        guard !busy else { return }; refresh()
        if let sessionLoadError { error = sessionLoadError; return }
        if let session = layoutSession, !session.matchesOriginal(displays.filter(\.active)) {
            error = "完整排列已单独保留。请先连接目标并恢复完整排列，再保存新基准。"; return
        }
        let saved = Snapshot(boot: currentBoot, displays: displays)
        do { guard saved.displays.allSatisfy(\.active), Set(saved.displays.map(\.id)) == Set((officeLayout?.displays ?? saved.displays).map(\.id)) else { throw OmniError.message("请连齐所有管理屏幕后再保存办公室基线。") }; try Files.write(saved,to:modeOfficeURL);officeLayout=saved;modeBaselineError=nil; try Files.write(saved, to: dataDirectory.appendingPathComponent(simulation ? "demo-layout.json" : "layout.json")); layout = saved; status = "已将当前排列设为基准；不记录应用窗口。" } catch { self.error = error.localizedDescription }
    }
    @Published var layout: Snapshot?
    func refresh() {
        defer { lastRefresh = Date() }
        guard !simulation else { return }
        do {
            let live = try backend.list()
            let ids = Set(live.map(\.id))
            let offline = (registry?.displays ?? []).filter { !ids.contains($0.id) }.map { d -> Display in var copy = d; copy.active = false; copy.main = false; return copy }
            let latest = (live + offline).sorted { $0.id < $1.id }
            if latest != displays { confirmation = nil; physicalConfirmed = false; testRiskAcknowledged = false; inputProbes = [:] }
            displays = latest
            // A boot transition invalidates cached numeric IDs; do not relabel them as this boot.
            if registry == nil || registry?.boot == currentBoot || offline.isEmpty {
                registry = Snapshot(boot: currentBoot, displays: latest)
                try Files.write(registry!, to: dataDirectory.appendingPathComponent("identities.json"))
            }
        } catch { self.error = error.localizedDescription }
    }
    func reason(for action: OmniCore.Operation, display: Display) -> String? {
        if let sessionLoadError { return sessionLoadError }
        if busy || probingInput != nil { return "请等待当前操作结束。" }
        if action == .disconnect {
            if !display.active { return "屏幕已不活动。" }
            if activeCount <= 1 { return "不能断开最后一块活动屏幕。" }
            if display.main { return "主屏受保护，请选择一块非主屏。" }
            if display.builtin { return "内置屏受保护。" }
            if let session = layoutSession, !session.matchesOriginal(displays.filter(\.active)) { return "已有未恢复的完整排列；请先连接上次目标并核对排列。" }
            do { _ = try LayoutSession.make(original: Snapshot(boot: currentBoot, displays: displays.filter(\.active)), target: display.id) }
            catch { return error.localizedDescription }
            if !simulation && !backend.canDisconnect { return "当前系统的断开接口不可用。" }
            if displays.contains(where: { $0.active && $0.mirrored }) { return "镜像模式不支持断开。" }
            if !simulation && (display.vendor == 0 || display.model == 0 || displays.filter({ $0.vendor == display.vendor && $0.model == display.model && $0.serial == display.serial }).count != 1) { return "恢复指纹不唯一，不能安全进行断开测试。" }
        } else {
            if display.active { return "屏幕已连接。" }
            if !simulation && registry?.boot != currentBoot { return "系统已重启，离线身份缓存过期；请拔插该屏视频线重新识别。" }
            if !simulation && !backend.canDisconnect { return "本系统不支持重新连接接口。" }
        }
        return nil
    }
    func temporaryLayoutPreview(target: String) -> String {
        guard let session = try? LayoutSession.make(original: Snapshot(boot: currentBoot, displays: displays.filter(\.active)), target: target) else { return "当前排列无法安全规划。" }
        let changes = session.temporary.displays.compactMap { d -> String? in
            guard let old=session.original.displays.first(where:{$0.id==d.id}), old.x != d.x || old.y != d.y else { return nil }
            return "\(d.name)：(\(old.x), \(old.y)) → (\(d.x), \(d.y))"
        }
        return changes.isEmpty ? "临时排列：其他屏幕保持原位。" : "临时排列（点）：\n" + changes.joined(separator:"\n")
    }
    func openActions(_ id: String) {
        choose(id)
        onShowManager?()
        actionDisplay = displays.first(where: { $0.id == id })
    }
    func choose(_ id: String) { selectedID = id; confirmation = nil; physicalConfirmed = false; testRiskAcknowledged = false }
    func prepare(_ action: OmniCore.Operation) {
        guard let selected, reason(for: action, display: selected) == nil else { return }
        retained = displays.first(where: { $0.active && $0.id != selected.id && $0.main })?.id ?? displays.first(where: { $0.active && $0.id != selected.id })?.id ?? ""
        physicalConfirmed = false; testRiskAcknowledged = false; confirmation = action; requestTopology = displays
    }
    func executeSelected() {
        guard let selected, let action = confirmation, !busy else { return }
        do {
            if action == .disconnect {
                guard physicalConfirmed else { throw OmniError.message("请确认保留实体屏幕。") }
                if !simulation { guard testRiskAcknowledged else { throw OmniError.message("请核对目标屏幕并确认现场恢复条件。") } }
            }
            guard requestTopology == displays else { throw OmniError.message("连接状态变化，请重新选择。") }
            _ = try SingleDisplayPlan.make(action: action, target: selected.id, displays: displays, retainedPhysical: retained)
            if let reason = reason(for: action, display: selected) { throw OmniError.message(reason) }
            var session = layoutSession
            if action == .disconnect {
                let captured = Snapshot(boot: currentBoot, displays: displays.filter(\.active))
                session = try LayoutSession.make(original: captured, target: selected.id)
                try Files.write(session!, to: sessionURL)
                layoutSession = session
                try Files.write(captured, to: dataDirectory.appendingPathComponent(simulation ? "demo-layout.json" : "layout.json"))
                layout = captured
            }
            var baseline = displays
            if action == .connect, session == nil, let saved = layout?.displays.first(where: { $0.id == selected.id }) {
                baseline = baseline.map { current in
                    guard current.id == selected.id else { return current }
                    var d = current; d.x = saved.x; d.y = saved.y; d.width = saved.width; d.height = saved.height; d.pixelWidth = saved.pixelWidth; d.pixelHeight = saved.pixelHeight; d.refresh = saved.refresh; d.rotation = saved.rotation; d.main = saved.main; return d
                }
            }
            if action == .disconnect { baseline = session!.original.displays }
            if let session {
                try session.validate(boot: currentBoot)
                guard session.target == selected.id || action == .disconnect else { throw OmniError.message("请先连接上次断开的目标屏幕。") }
            }
            let before = Snapshot(boot: registry?.boot ?? currentBoot, displays: baseline)
            var request = Request(operation: action, before: before, office: before, keep: retained, confirmedPhysical: physicalConfirmed, simulation: simulation, target: selected.id)
            request.layoutSession = session
            if action == .disconnect && !simulation { request.liveConsent = try LiveTestConsent.grant(request: request, confirmedTarget: selected.id, riskAcknowledged: testRiskAcknowledged) }
            try launch(request)
            confirmation = nil; actionDisplay = nil
        } catch { self.error = error.localizedDescription }
    }
    func probeInput(_ target: String) {
        guard !busy, probingInput == nil, let display = displays.first(where: { $0.id == target }) else { return }
        if simulation {
            inputProbes[target] = InputProbe(target: target, state: .readable, current: inputProbes[target]?.current ?? 0x11, detail: "模拟 HDMI / DisplayPort；不表示实体屏幕支持。", simulation: true)
            return
        }
        let child = Process(), pipe = Pipe()
        child.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/OmniRecovery")
        child.arguments = ["--probe-input", target]; child.standardOutput = pipe; child.standardError = FileHandle.nullDevice
        let original = display
        probingInput = target; inputProcess = child
        child.terminationHandler = { [weak self] process in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            Task { @MainActor in
                guard let self, self.inputProcess === process else { return }
                self.probingInput = nil; self.inputProcess = nil
                guard self.displays.first(where: { $0.id == target }) == original else { return }
                let parsed = try? JSONDecoder().decode(InputProbe.self, from: data)
                self.inputProbes[target] = parsed?.target == target ? parsed : InputProbe(target: target, state: .readFailed, detail: "读取进程超时或未返回有效结果。未发送切源命令。")
            }
        }
        do { try child.run() }
        catch { probingInput = nil; inputProcess = nil; self.error = error.localizedDescription; return }
        // A blocked private I/O call cannot block the menu/window. Bound our own
        // short-lived read-only child; no driver, service or elevated permissions.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self, weak child] in
            guard let child, child.isRunning, self?.inputProcess === child else { return }
            child.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak child] in
                if let child, child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
    }
    func mappedInputPorts(_ target: String) -> [InputPortMapping] {
        guard let probe = inputProbes[target], let route = probe.route else { return [] }
        return (inputPortMappings[target] ?? []).filter { $0.target == target && $0.boot == currentBoot && $0.route == route }.sorted { $0.code < $1.code }
    }
    func recordInputPort(_ target: String, label: String, osdConfirmed: Bool) {
        do {
            let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard osdConfirmed, !name.isEmpty, let probe = inputProbes[target], probe.state == .readable,
                  let current = probe.current, let route = probe.route, Date().timeIntervalSince(probe.date) < 60 else { throw OmniError.message("请重新只读检测，并核对实体 OSD 当前端口名称后记录。") }
            var ports = mappedInputPorts(target).filter { $0.code != current }
            guard !ports.contains(where: { $0.label == name }) else { throw OmniError.message("同一端口名称对应不同代码，请重新核对 OSD。") }
            ports.append(InputPortMapping(target: target, boot: currentBoot, route: route, code: current, label: name, observedAt: probe.date))
            inputPortMappings[target] = ports
            try Files.write(inputPortMappings, to: dataDirectory.appendingPathComponent("input-ports.json"))
            status = "已记录当前端口；没有切换输入。"
        } catch { self.error = error.localizedDescription }
    }
    func inputTestReason(_ display: Display) -> String? {
        if busy || probingInput != nil { return "请等待当前操作结束。" }
        if !display.active || display.builtin || display.main { return "仅对活动的外接非主屏进行切源测试。" }
        if activeCount < 2 { return "必须保留另一块活动实体屏。" }
        if displays.contains(where: { $0.active && $0.mirrored }) { return "镜像模式不支持。" }
        guard let probe = inputProbes[display.id], probe.state == .readable, let value = probe.current else { return "没有可靠的当前输入读数，禁止试写端口。" }
        if Date().timeIntervalSince(probe.date) >= 60 { return "读数已过期，请重新检测。" }
        let ports = mappedInputPorts(display.id)
        if ports.count < 2 || !ports.contains(where: { $0.code == value }) { return "需要先记录两个不同输入的真实代码与 OSD 名称；不猜测 HDMI/DP 代码。" }
        return nil
    }
    func changeInput(_ target: String, to value: UInt16, confirmed: Bool) {
        guard !busy, probingInput == nil else { return }
        do {
            guard let probe = inputProbes[target], probe.state == .readable, let previous = probe.current,
                  Date().timeIntervalSince(probe.date) < 60, confirmed,
                  let display = displays.first(where: { $0.id == target }) else { throw OmniError.message("请先重新读取当前输入并确认现场恢复条件。") }
            if !simulation, let reason = inputTestReason(display) { throw OmniError.message(reason) }
            let retained = displays.first(where: { $0.id != target && $0.active && $0.main })?.id ?? displays.first(where: { $0.id != target && $0.active })?.id ?? ""
            let before = Snapshot(boot: currentBoot, displays: displays)
            var request = Request(operation: .inputSource, before: before, office: before, keep: retained, confirmedPhysical: confirmed, simulation: simulation, target: target)
            request.inputBefore = previous; request.inputAfter = value
            if !simulation {
                let ports = mappedInputPorts(target)
                request.inputPortsConfirmed = true; request.inputPortMappings = ports
                request.inputFromPort = ports.first(where: { $0.code == previous })?.label
                request.inputToPort = ports.first(where: { $0.code == value })?.label
                request.liveConsent = try LiveTestConsent.grant(request: request, confirmedTarget: target, riskAcknowledged: confirmed)
            }
            _ = try InputChangePlan(request: request)
            try launch(request); requestedInputs[target] = value; actionDisplay = nil
        } catch { self.error = error.localizedDescription }
    }
    private func launch(_ request: Request) throws {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/OmniRecovery")
        let fallback = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("OmniRecovery")
        let executable = FileManager.default.isExecutableFile(atPath: helper.path) ? helper : fallback
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw OmniError.message("缺少安全操作程序，已阻止操作。") }
        let dir = dataDirectory.appendingPathComponent("Transactions/\(request.nonce)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Files.write(request, to: dir.appendingPathComponent("request.json"))
        let child = Process(); child.executableURL = executable; child.arguments = ["--transaction", dir.path]
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        try child.run(); error = nil; transactionRequest = request; decisionPending = false; journal = dir; process = child; sentExecute = false; receipt = nil
        do { try Files.write(dir.path, to: activeURL) } catch { try? Files.marker("cancel", in: dir); throw error }
        status = "正在准备目标屏幕操作…"
    }
    var awaitingDecision: Bool { busy && receipt?.phase == .awaitingConfirmation }
    var keepButtonTitle: String {
        switch transactionRequest?.operation { case .remoteMode: return "保留远程模式"; case .officeMode:return "保留办公室模式"; case .disconnect:return "保留断开";default:return "保留更改" }
    }
    var transactionTargetName: String {
        transactionRequest?.before.displays.first(where: { $0.id == transactionRequest?.target })?.name ?? "目标屏幕"
    }
    // UI evidence is separate from the helper's phase/write logs. A rendered panel
    // does not prove human observation; clicks and marker writes have distinct events.
    func recordConfirmationUI(_ event: String, details: [String: Any] = [:]) {
        guard let journal, let request = transactionRequest else { return }
        var item = details
        item["event"] = event; item["date"] = ISO8601DateFormatter().string(from: Date())
        item["unixTime"] = Date().timeIntervalSince1970; item["uptime"] = ProcessInfo.processInfo.systemUptime
        item["nonce"] = request.nonce; item["simulation"] = simulation
        item["phase"] = receipt?.phase.rawValue ?? "preparing"; item["remaining"] = countdown
        let file = journal.appendingPathComponent("ui-events.jsonl")
        do {
            var data = try JSONSerialization.data(withJSONObject: item, options: [.sortedKeys]); data.append(10)
            if !FileManager.default.fileExists(atPath: file.path) {
                try data.write(to: file, options: .atomic)
            } else {
                let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
                try handle.seekToEnd(); try handle.write(contentsOf: data)
            }
        } catch { self.error = "界面记录未写入：\(error.localizedDescription)" }
    }
    func confirm(source: String = "unknown") {
        recordConfirmationUI("keepClicked", details: ["source": source])
        guard awaitingDecision, countdown > 0, !decisionPending, let journal else { return }
        do { try Files.marker("confirm", in: journal); decisionPending = true; recordConfirmationUI("confirmMarkerWritten", details: ["source": source]) }
        catch { self.error = error.localizedDescription }
    }
    func cancel(source: String = "system") {
        guard busy, let journal else { return }
        recordConfirmationUI("restoreRequested", details: ["source": source])
        do { try Files.marker("cancel", in: journal); decisionPending = true; recordConfirmationUI("cancelMarkerWritten", details: ["source": source]) }
        catch { self.error = error.localizedDescription }
    }
    private func tick() {
        defer { retireRestoredSession(); onTransactionUIChange?() }
        now = Date(); if now.timeIntervalSince(lastRefresh) > 2 { refresh() }
        guard let journal else { return }
        if let next = try? Files.read(Receipt.self, from: journal.appendingPathComponent("receipt.json")) {
            receipt = next; status = next.message
            if next.phase == .ready && !sentExecute { do { try Files.marker("execute", in: journal); sentExecute = true } catch { self.error = error.localizedDescription; cancel() } }
            if simulation, let state = try? Files.read([Display].self, from: journal.appendingPathComponent("simulated-displays.json")) {
                let known = ModePlan.isMode(transactionRequest?.operation ?? .connect) ? (officeLayout?.displays ?? []) : []
                displays = state + known.filter { d in !state.contains(where:{$0.id==d.id}) }.map { d in var offline=d;offline.active=false;offline.main=false;return offline }
            }
            if simulation, let inputs = try? Files.read([String: UInt16].self, from: journal.appendingPathComponent("simulated-inputs.json")) {
                for (target, value) in inputs { inputProbes[target] = InputProbe(target: target, state: .readable, current: value, detail: "模拟输入源；真实屏幕未改变。", simulation: true) }
            }
            if next.phase == .failed { error = next.message }
        }
        if !(receipt?.phase.terminal ?? false), (process.map { !$0.isRunning } ?? !RecoveryEngine.operationIsRunning(parent: journal.deletingLastPathComponent())) {
            receipt = Receipt(.failed, "上次操作进程已退出，恢复未确认。完整办公室基线和事务入口已保留；请检查实体屏幕后选择办公室恢复，勿重复断开。")
            error = receipt?.message
        }
    }
}
