import SwiftUI
import AppKit
import OmniCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    private var statusConfirmationNonce: String?
    private var confirmationPanel: ConfirmationPanelController?
    private var observer: NSObjectProtocol?
    private var statusItem: NSStatusItem?
    private var panel: NSPopover?
    private var manager: NSWindow?
    private var presentationGeneration = 0
    private var menuHost: NSHostingController<MenuPanel>?
    private func recordUI(_ event: String) {
        let record: [String: Any] = ["statusTitle": statusItem?.button?.title ?? "", "remaining": model.countdown, "awaitingConfirmation": model.awaitingDecision, "buttonBounds": statusItem?.button.map { NSStringFromRect($0.bounds) } ?? "none", "popoverFrame": panel?.contentViewController?.view.window.map { NSStringFromRect($0.frame) } ?? "none", "popoverContentSize": panel.map { NSStringFromSize($0.contentSize) } ?? "none", "event": event, "pid": ProcessInfo.processInfo.processIdentifier, "managerVisible": manager?.isVisible ?? false, "appActive": NSApp.isActive, "managerKey": manager?.isKeyWindow ?? false, "keyWindowClass": NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "none", "firstResponderClass": NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "none", "panelShown": panel?.isShown ?? false, "statusVisible": statusItem?.isVisible ?? false, "statusFrame": statusItem?.button?.window.map { NSStringFromRect($0.frame) } ?? "none"]
        if let data = try? JSONSerialization.data(withJSONObject: record, options: .prettyPrinted) { try? data.write(to: model.dataDirectory.appendingPathComponent("ui-state.json"), options: .atomic) }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if !CommandLine.arguments.contains("--demo"), let primary = NSRunningApplication.runningApplications(withBundleIdentifier:"io.github.exception63.OmniDisplay").first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            DistributedNotificationCenter.default().postNotificationName(NSNotification.Name("OmniDisplay.ShowManager"),object:nil)
            primary.activate(options:[.activateAllWindows]); NSApp.terminate(nil); return
        }
        NSApp.setActivationPolicy(.accessory)
        // Let AppKit choose the status item's position.
        let item = NSStatusBar.system.statusItem(withLength:30)
        item.autosaveName = "OmniDisplay.MenuBar"
        item.isVisible = true
        if let button = item.button {
            button.image = NSImage(systemSymbolName:"display.2",accessibilityDescription:"OmniDisplay 屏幕菜单")
            button.image?.size = NSSize(width:19,height:17)
            button.sendAction(on:[.leftMouseUp,.rightMouseUp])
            button.image?.isTemplate = true; button.toolTip = "OmniDisplay · 点击管理屏幕"
            if #available(macOS 27.0, *) {
                item.expandedInterfaceDelegate = self
            } else {
                button.target = self; button.action = #selector(togglePanel)
            }
        }
        statusItem = item
        let popover = NSPopover(); popover.behavior = .transient; popover.animates = false
        let host = NSHostingController(rootView:MenuPanel(model:model,onOpen:{ [weak self] in self?.showManager() }))
        // Keep the size stable before AppKit computes placement. An unconstrained
        // hosting view can resize around an already positioned popover on macOS 27.
        host.sizingOptions = []
        menuHost = host
        popover.contentViewController = host
        popover.delegate = self
        panel = popover
        observer = DistributedNotificationCenter.default().addObserver(forName:NSNotification.Name("OmniDisplay.ShowManager"),object:nil,queue:.main) { [weak self] _ in Task { @MainActor in self?.showManager() } }
        model.onShowManager = { [weak self] in self?.showManager() }
        confirmationPanel = ConfirmationPanelController(model: model)
        model.onTransactionUIChange = { [weak self] in
            self?.confirmationPanel?.synchronize()
            self?.updateConfirmationStatus()
        }
        model.onShowConfirmation = { [weak self] in
            guard let self else { return }
            if #available(macOS 27.0, *) { self.statusItem?.expandedInterfaceSession?.cancel() }
            self.panel?.performClose(nil)
            self.confirmationPanel?.reopen()
        }
        showManager()
        confirmationPanel?.synchronize()
        updateConfirmationStatus()
    }
    private func updateConfirmationStatus() {
        guard let item = statusItem, let button = item.button else { return }
        item.length = model.awaitingDecision ? NSStatusItem.variableLength : 30
        button.title = model.awaitingDecision ? " 待确认 \(model.countdown)s" : ""
        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        button.imagePosition = .imageLeading
        button.toolTip = model.awaitingDecision ? "OmniDisplay · 待确认，剩余\(model.countdown)秒 · 点击打开确认" : "OmniDisplay · 点击管理屏幕"
        let nonce = model.awaitingDecision ? model.transactionRequest?.nonce : nil
        if statusConfirmationNonce != nonce {
            statusConfirmationNonce = nonce
            if nonce != nil { model.recordConfirmationUI("statusCountdownPresented", details: ["title": button.title, "statusItemVisible": item.isVisible]) }
        }
    }
    @objc func togglePanel() {
        guard let panel else { return }
        if panel.isShown {
            panel.performClose(nil)
        } else {
            scheduleMenuPresentation()
        }
        recordUI("togglePanel")
    }
    private func scheduleMenuPresentation() {
        presentationGeneration += 1
        let generation = presentationGeneration
        // NSSceneStatusItem supplies the presentation screen during the session
        // transition. Read its final view/window transform on the next run loop.
        DispatchQueue.main.async { [weak self] in self?.presentMenu(generation: generation, attempt: 0) }
    }
    private func presentMenu(generation: Int, attempt: Int) {
        guard generation == presentationGeneration, let panel, let host = menuHost,
              let button = statusItem?.button else { return }
        guard let window = button.window else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screens = NSScreen.screens
        guard let index = MenuPopoverLayout.screenIndex(anchor: anchor, frames: screens.map(\.frame)),
              window.frame.height > 0 else {
            if attempt < 3 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in self?.presentMenu(generation:generation, attempt:attempt+1) }
            } else { recordUI("menuAnchorUnavailable") }
            return
        }
        guard let size = MenuPopoverLayout.contentSize(anchor:anchor, visibleFrame:screens[index].visibleFrame, displayCount:model.displays.count) else {
            recordUI("menuSpaceUnavailable"); return
        }
        host.preferredContentSize = size
        host.view.setFrameSize(size)
        host.view.layoutSubtreeIfNeeded()
        panel.contentSize = size
        // The positioning rectangle is in button coordinates, not screen coordinates.
        // AppKit handles secondary screens, negative origins and Retina scaling.
        panel.show(relativeTo:button.bounds,of:button,preferredEdge:.minY)
        recordUI("menuBarOpened")
    }
    @objc func openManagerFromMenu() { showManager() }
    func showManager() {
        presentationGeneration += 1
        if #available(macOS 27.0, *) { statusItem?.expandedInterfaceSession?.cancel() }
        panel?.performClose(nil)
        if manager == nil {
            let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1000,height:760),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
            window.title = "OmniDisplay · 屏幕"; window.titlebarAppearsTransparent = true
            window.delegate = self; window.isReleasedWhenClosed = false; window.minSize = NSSize(width:800,height:590)
            window.contentView = NSHostingView(rootView:ManagerView(model:model))
            window.center(); manager = window
        }
        // Finish the status-item session before acquiring keyboard focus. Do not
        // re-key the parent over a sheet or a text editor that already owns focus.
        NSApp.activate(ignoringOtherApps: true)
        manager?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            guard let self, let manager = self.manager, manager.isVisible, NSApp.isActive else { return }
            if manager.attachedSheet == nil && NSApp.keyWindow == nil { manager.makeKey() }
            self.recordUI("showManager")
        }
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        if let manager, manager.isVisible, manager.attachedSheet == nil, NSApp.keyWindow == nil { manager.makeKey() }
        recordUI("becameActive")
    }
    func windowDidBecomeKey(_ notification: Notification) { recordUI("managerBecameKey") }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool) -> Bool { if !flag && panel?.isShown != true { showManager() }; return true }
    func applicationWillTerminate(_ notification:Notification) { if model.busy { model.cancel() } }
}
@available(macOS 27.0, *)
extension AppDelegate: @preconcurrency NSStatusItemExpandedInterfaceDelegate {
    func statusItem(_ statusItem: NSStatusItem, didBegin expandedInterfaceSession: NSStatusItemExpandedInterfaceSession) {
        scheduleMenuPresentation()
    }
    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
        presentationGeneration += 1
        panel?.performClose(nil)
        recordUI("menuBarClosed")
    }
}
extension AppDelegate: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        if #available(macOS 27.0, *) { statusItem?.expandedInterfaceSession?.cancel() }
    }
}
// Use AppKit for the menu-bar application's lifetime; all content stays SwiftUI.
// This avoids creating a hidden SwiftUI Settings scene just to keep the app alive.
@main struct OmniDisplayApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title:"OmniDisplay")
        let open = NSMenuItem(title:"打开管理窗口", action:#selector(AppDelegate.openManagerFromMenu), keyEquivalent:"0")
        open.target = delegate
        appMenu.addItem(open)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle:"退出 OmniDisplay",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        appItem.submenu = appMenu; menu.addItem(appItem)
        let editItem = NSMenuItem(), editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        editItem.submenu = editMenu; menu.addItem(editItem); app.mainMenu = menu
        withExtendedLifetime(delegate) { app.run() }
    }
}
struct MenuPanel: View {
    @ObservedObject var model: AppModel
    let onOpen: () -> Void
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack { Image(systemName:"display.2").foregroundStyle(.blue); Text("OmniDisplay").font(.headline); Spacer(); Text("\(model.activeCount) 屏活动").font(.caption).foregroundStyle(.secondary) }
            if model.awaitingDecision {
                VStack(alignment: .leading, spacing: 8) {
                    Text("待确认 · \(model.countdown)秒后尝试恢复").font(.callout.bold()).monospacedDigit()
                    Button("打开确认面板") { model.onShowConfirmation?() }.buttonStyle(.borderedProminent)
                }.frame(maxWidth: .infinity, alignment: .leading)
            } else if model.busy {
                Text(model.status).font(.caption)
                Button("立即恢复") { model.cancel(source: "menuBar") }
            }
            ScrollView {
                VStack(spacing:7) {
                    if model.simulation { Text("模拟环境").font(.caption).foregroundStyle(.orange) }
                    ForEach(model.sortedDisplays) { d in DisplayRow(model:model,display:d,compact:true) }
                }.frame(maxWidth:.infinity)
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
            Divider()
            Button(action:onOpen) { Label("打开管理窗口",systemImage:"macwindow").frame(maxWidth:.infinity) }.buttonStyle(.borderedProminent)
            HStack { Button("刷新") { model.refresh() }; Spacer(); Button("退出") { if model.busy { model.cancel() }; NSApp.terminate(nil) } }.font(.caption)
        }.padding(16).frame(maxWidth:.infinity,maxHeight:.infinity)
    }
}
