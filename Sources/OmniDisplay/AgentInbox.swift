import Foundation
import OmniCore

/// 接 `omnidisplay` 命令行的请求（用户 2026-10-21 授权：agent 可直接连接 / 断开 / 切模式 / 旋转，不经二次确认）。
///
/// 一次只办一件。事务仍交给 App 原来那套 helper 流程（单次许可、核验、排列靠拢与恢复、事务记录），
/// helper 核验通过进入待确认后，由这里替用户「保留」。主屏不能断、最后一块不能断等拒绝理由和手动完全相同。
@MainActor final class AgentInbox {
    private let model: AppModel
    private let directory: URL
    private var timer: Timer?
    private var job: Job?
    private var starting = false

    private struct Job {
        let request: AgentRequest
        let nonce: String
        let success: Phase
        let done: String
        let note: String?
    }

    init(model: AppModel, directory: URL) {
        self.model = model
        self.directory = directory
        do {
            try AgentMailbox.prepare(directory)
            // 上次没取走的回执留着没用；请求过期的下面取的时候会回绝。
            for file in (try? FileManager.default.contentsOfDirectory(at: AgentMailbox.responses(directory), includingPropertiesForKeys: nil)) ?? [] {
                try? FileManager.default.removeItem(at: file)
            }
        } catch { model.error = "命令行收件箱建不起来：\(error.localizedDescription)" }
        timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func tick() {
        if let job { follow(job); return }
        guard !starting, let request = take() else { return }
        handle(request)
    }

    /// 取最早的一封（文件名以毫秒时间开头）；先改名占住。读坏的丢掉，过期的回绝、不执行。
    private func take() -> AgentRequest? {
        let inbox = AgentMailbox.requests(directory)
        guard let files = try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil) else { return nil }
        for file in files.filter({ $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let claimed = file.appendingPathExtension("taken")
            guard (try? FileManager.default.moveItem(at: file, to: claimed)) != nil else { continue }
            defer { try? FileManager.default.removeItem(at: claimed) }
            guard let request = try? AgentMailbox.read(AgentRequest.self, from: claimed) else { continue }
            if AgentMailbox.expired(request) {
                reply(request, ok: false, "请求已过期（超过 \(Int(AgentMailbox.maxAge)) 秒没被处理），没有执行。")
                continue
            }
            return request
        }
        return nil
    }

    private func handle(_ request: AgentRequest) {
        do {
            switch request.command {
            case .list:
                model.refresh()
                reply(request, ok: true, "共 \(model.displays.count) 块屏幕，连着 \(model.activeCount) 块。")
            case .saveLayout:
                reply(request, ok: true, try model.agentSaveLayout())
            case .office:
                start(request, try model.agentMode(.officeMode), success: .confirmed, done: "已切到办公室模式：屏幕都接上，排列按办公室基线恢复。")
            case .connect where request.all == true:
                start(request, try model.agentMode(.officeMode), success: .confirmed, done: "屏幕都接上了，排列按办公室基线恢复。")
            case .remote:
                let main = model.numberedScreens.firstIndex(where: \.main).map { "第 \($0 + 1) 块" } ?? "主屏"
                start(request, try model.agentMode(.remoteMode), success: .confirmed, done: "已切到远程模式：只留主屏（\(main)），其余断开。")
            case .connect:
                let (number, display) = try target(request)
                start(request, try model.agentSingle(.connect, target: display.id), success: .restored, done: "已连接第 \(number) 块屏幕，排列已恢复。")
            case .disconnect:
                let (number, display) = try target(request)
                if display.main { throw OmniError.message("第 \(number) 块是主屏，不能断开。") }
                start(request, try model.agentSingle(.disconnect, target: display.id), success: .confirmed, done: "已断开第 \(number) 块屏幕。")
            case .rotate:
                let (number, display) = try target(request)
                guard let raw = request.rotation, let action = RelativeRotation(rawValue: raw) else {
                    throw OmniError.message("旋转方向只能是 counterclockwise（逆时针90°）、clockwise（顺时针90°）或 flip（翻转180°）。")
                }
                starting = true
                Task {
                    defer { starting = false }
                    do { start(request, try await model.agentRotate(display.id, action), success: .confirmed, done: "第 \(number) 块已\(action.title)。") }
                    catch { reply(request, ok: false, error.localizedDescription) }
                }
            }
        } catch { reply(request, ok: false, error.localizedDescription) }
    }

    private func target(_ request: AgentRequest) throws -> (Int, Display) {
        model.refresh()
        let screens = model.numberedScreens
        guard let number = request.number, (1...max(screens.count, 1)).contains(number), number <= screens.count else {
            throw OmniError.message("没有第 \(request.number.map(String.init) ?? "?") 块屏幕；现在共 \(screens.count) 块，从左到右编号 1–\(screens.count)。")
        }
        return (number, screens[number - 1])
    }

    private func start(_ request: AgentRequest, _ result: AppModel.AgentStart, success: Phase, done: String) {
        switch result {
        case .done(let message): reply(request, ok: true, message)
        case .started(let nonce, let note): job = Job(request: request, nonce: nonce, success: success, done: done, note: note)
        }
    }

    private func follow(_ current: Job) {
        guard model.transactionRequest?.nonce == current.nonce else {
            job = nil
            reply(current.request, ok: false, "这次操作没有跟踪到结果；用 omnidisplay list 核对现状。")
            return
        }
        guard let phase = model.receipt?.phase else { return }
        if phase == .awaitingConfirmation { model.confirmForAgent() }
        guard phase.terminal else { return }
        job = nil
        model.refresh()
        let ok = phase == current.success
        let message = ok ? [current.note, current.done].compactMap { $0 }.joined(separator: " ")
                         : [current.note, model.receipt?.message].compactMap { $0 }.joined(separator: " ")
        reply(current.request, ok: ok, message, phase: phase.rawValue)
    }

    private func reply(_ request: AgentRequest, ok: Bool, _ message: String, phase: String? = nil) {
        let screens = model.numberedScreens.enumerated().map { AgentScreen(number: $0.offset + 1, display: $0.element) }
        let response = AgentResponse(id: request.id, ok: ok, message: message, phase: phase, screens: screens)
        do { try AgentMailbox.write(response, to: AgentMailbox.responses(directory).appendingPathComponent("\(request.id).json")) }
        catch { model.error = "命令行结果写不回去：\(error.localizedDescription)" }
    }
}
