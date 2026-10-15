import AppKit
import SwiftUI
import OmniCore

/// Uses AppKit points and visible frames; no display configuration calls.
enum ConfirmationPlacement {
    static func screenIndex(ids: [String], preferred: [String], mainID: String) -> Int? {
        for id in preferred + [mainID] {
            if let index = ids.firstIndex(of: id) { return index }
        }
        return ids.isEmpty ? nil : 0
    }
    static func frame(size: CGSize, visible: CGRect) -> CGRect {
        let area = visible.insetBy(dx: 16, dy: 16)
        let width = min(size.width, max(1, area.width)), height = min(size.height, max(1, area.height))
        return CGRect(x: area.midX-width/2, y: area.midY-height/2, width: width, height: height)
    }
}

@MainActor final class ConfirmationPanelController {
    private let model: AppModel
    private var host: NSHostingController<ConfirmationPanelView>?
    private var window: NSPanel?
    private var displayedNonce: String?
    private var displayedAwaiting = false
    private var observer: NSObjectProtocol?
    private var lastPlacement: CGRect?
    init(model: AppModel) {
        self.model = model
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.model.busy else { return }
                self.position(reason: "screenParametersChanged") // no activation or focus change
            }
        }
    }
    func synchronize() {
        guard model.busy, let nonce = model.transactionRequest?.nonce else {
            if displayedNonce != nil {
                window?.orderOut(nil); model.recordConfirmationUI("panelHidden")
                displayedNonce = nil; lastPlacement = nil; displayedAwaiting = false
            }
            return
        }
        let enteringConfirmation = model.awaitingDecision && !displayedAwaiting
        displayedAwaiting = model.awaitingDecision
        guard displayedNonce != nonce || enteringConfirmation else { return }
        displayedNonce = nonce
        show(reason: enteringConfirmation ? "enteredAwaitingConfirmation" : "enteredExecution")
    }
    func reopen() {
        guard model.busy else { return }
        show(reason: "userOpenedConfirmation")
    }
    private func show(reason: String) {
        if window == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 320), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
            panel.title = "OmniDisplay · 请确认屏幕画面"
            panel.titlebarAppearsTransparent = true
            panel.level = .floating; panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            let host = NSHostingController(rootView: ConfirmationPanelView(model: model))
            host.sizingOptions = []
            host.preferredContentSize = NSSize(width: 540, height: 320)
            panel.contentViewController = host
            self.host = host
            window = panel
        }
        position(reason: reason)
        model.recordConfirmationUI("panelOrderRequested", details: ["reason": reason])
        // Exactly once on entry, or an explicit reopen. Timer ticks never activate.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        let nonce = model.transactionRequest?.nonce
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.displayedNonce == nonce, self.model.busy else { return }
            self.recordVisibility(reason: reason)
        }
    }
    private func screenID(_ screen: NSScreen) -> String {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return "" }
        return CFUUIDCreateString(nil, uuid) as String
    }
    private func position(reason: String) {
        guard let window else { return }
        let screens = NSScreen.screens
        let ids = screens.map(screenID)
        let mainID = CGDisplayCreateUUIDFromDisplayID(CGMainDisplayID()).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? ""
        let request = model.transactionRequest
        let preferred = (request.map { ModePlan.isMode($0.operation) } == true ? [request?.keep] : [request?.before.displays.first(where: { $0.main && $0.active && $0.id != request?.target })?.id, request?.keep]).compactMap { $0 }
        guard let index = ConfirmationPlacement.screenIndex(ids: ids, preferred: preferred, mainID: mainID) else {
            model.recordConfirmationUI("panelScreenUnavailable"); return
        }
        let frame = ConfirmationPlacement.frame(size: CGSize(width: 540, height: 342), visible: screens[index].visibleFrame)
        guard frame != lastPlacement || window.frame != frame else { return }
        host?.view.setFrameSize(window.contentRect(forFrameRect: frame).size)
        window.setFrame(frame, display: true)
        host?.view.layoutSubtreeIfNeeded()
        lastPlacement = frame
        model.recordConfirmationUI("panelPositioned", details: ["reason": reason, "screenUUID": ids[index], "screenName": screens[index].localizedName, "frame": NSStringFromRect(frame), "visibleFrame": NSStringFromRect(screens[index].visibleFrame), "insideVisibleFrame": screens[index].visibleFrame.contains(frame)])
        if window.isVisible { recordVisibility(reason: reason) }
    }
    private func recordVisibility(reason: String) {
        guard let window else { return }
        let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]]
        let onScreen = rows?.first?[kCGWindowIsOnscreen as String] as? Bool ?? false
        model.recordConfirmationUI("panelVisibilityObserved", details: ["reason": reason, "visible": window.isVisible, "occlusionVisible": window.occlusionState.contains(.visible), "windowServerOnScreen": onScreen, "key": window.isKeyWindow, "windowNumber": window.windowNumber, "frame": NSStringFromRect(window.frame), "insideVisibleFrame": NSScreen.screens.contains(where: { $0.visibleFrame.contains(window.frame) }), "screenName": window.screen?.localizedName ?? "unknown"])
    }
}

struct ConfirmationButtons: View {
    @ObservedObject var model: AppModel
    let source: String
    var body: some View {
        HStack(spacing: 12) {
            Button(model.transactionRequest?.operation == .officeMode ? "结束检查，保持连接" : "立即恢复") { model.cancel(source: source) }.controlSize(.large)
                .accessibilityIdentifier("confirmation.restore")
            Button(model.decisionPending ? "正在处理…" : model.keepButtonTitle) { model.confirm(source: source) }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!model.awaitingDecision || model.countdown <= 0 || model.decisionPending)
                .accessibilityIdentifier("confirmation.keep")
        }
    }
}
struct ConfirmationPanelView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !model.awaitingDecision {
                HStack { ProgressView().controlSize(.small); Text(model.simulation ? "模拟 · 操作进度" : "正在处理屏幕操作").font(.title2.bold()) }
                Text("目标：\(model.transactionTargetName)").foregroundStyle(.secondary)
                Text(model.shortTransactionStatus).fixedSize(horizontal: false, vertical: true)
                Text(model.transactionRequest?.operation == .officeMode ? "已连接屏幕会保持启用。" : "核验后请在45秒内确认；取消会尝试恢复。").font(.callout).foregroundStyle(.secondary)
                Button(model.transactionRequest?.operation == .officeMode ? "停止并保留已连接屏幕" : "取消并尝试恢复") { model.cancel(source: "progressPanel") }.disabled(model.decisionPending)
            } else {
            HStack(alignment: .top) {
                Image(systemName: "display.badge.checkmark").font(.system(size: 30)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.simulation ? "模拟 · 请确认画面" : "请确认画面").font(.title2.bold())
                    Text("目标：\(model.transactionTargetName)").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(model.countdown)秒").font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(.orange)
                    .accessibilityIdentifier("confirmation.countdown")
            }
            Text(model.transactionRequest?.operation == .disconnect ? "请检查主屏和其他保留屏幕：画面与旋转正常、屏幕按预览临时靠拢后，点击「保留断开」。" : "请检查保留屏幕的画面，正常后点击「\(model.keepButtonTitle)」。")
                .font(.body).fixedSize(horizontal: false, vertical: true)
            Text(model.transactionRequest?.operation == .officeMode ? "取消或倒计时结束不会关闭已连接屏幕；请核对全部画面及排列。" : model.countdown > 0 ? "不操作将在倒计时结束后尝试恢复。\(model.simulation ? "本次不会改变实体显示器。" : "恢复无法保证处理硬件或系统故障。")" : "确认时间已结束，正在等待恢复结果…")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); ConfirmationButtons(model: model, source: "confirmationPanel") }
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(.regularMaterial).tint(.blue)
    }
}
struct TransactionBanner: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.awaitingDecision ? "待确认 · \(model.transactionTargetName) · \(model.countdown)秒" : model.shortTransactionStatus).font(.headline).monospacedDigit()
                Text(model.transactionRequest?.operation == .officeMode ? "核对全部屏幕；未确认或取消都不会再次断屏。" : model.awaitingDecision ? "检查保留屏幕的画面；不操作会尝试恢复。" : "操作期间请保留此窗口。确认面板将在核验通过后出现。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.awaitingDecision {
                Button("打开确认") { model.onShowConfirmation?() }
                ConfirmationButtons(model: model, source: "managerBanner")
            } else { Button(model.transactionRequest?.operation == .officeMode ? "结束检查，保持连接" : "立即恢复") { model.cancel(source: "managerBanner") } }
        }
    }
}
