import SwiftUI
import OmniCore

private let accent = Color(red: 0.12, green: 0.43, blue: 0.76)
struct GlassCard: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) { content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22)) }
        else { content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22)) }
    }
}
struct ManagerView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    HStack(spacing: 14) {
                        Image(systemName: "display.2").font(.system(size: 32, weight: .light)).foregroundStyle(accent)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("你的屏幕，随点随选。").font(.system(size: 28, weight: .semibold))
                            Text("点击一块屏幕，连接或断开。断开时临时靠拢，连接后恢复排列。").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("刷新连接状态")
                }.padding(.top, 16)
                if model.simulation { Label("模拟模式 · \(model.demoCount) 屏 · 所有操作不改变真实显示器", systemImage: "testtube.2").foregroundStyle(.orange).font(.callout) }
                if let error = model.error { HStack(alignment: .top) { Image(systemName: "exclamationmark.triangle"); Text(error).textSelection(.enabled); Spacer(); Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }.font(.callout).foregroundStyle(.red).padding(15).background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 14)) }
                if let history = model.modeFailureHistory {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(model.modeFailureSummary, systemImage: "clock.arrow.circlepath").font(.callout)
                        DisclosureGroup("上次事务原始结果") { Text(history).font(.caption).textSelection(.enabled) }
                    }.padding(15).frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                }
                ModeControls(model:model).padding(20).modifier(GlassCard())
                VStack(alignment: .leading, spacing: 18) {
                    HStack { Label("屏幕排列", systemImage: "rectangle.3.group").font(.headline); Spacer(); Text("\(model.activeCount) 活动 · \(model.displays.count) 已知").font(.caption).foregroundStyle(.secondary) }
                    DisplayMap(model: model).frame(height: 220)
                    HStack {
                        Text("主屏标有圆点 · 灰色虚线表示未活动 · 点击屏幕查看操作").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("以当前排列为准") { model.saveCurrentLayout() }.disabled(model.busy).help("只记录显示器位置、旋转和模式，不调整屏幕，不记录应用窗口")
                    }
                }.padding(24).modifier(GlassCard())
                HStack { Text("所有屏幕").font(.headline); Spacer(); Text("离线屏幕仍保留，方便重新连接").font(.caption).foregroundStyle(.secondary) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 12)], spacing: 12) {
                    ForEach(model.sortedDisplays) { d in DisplayRow(model: model, display: d, compact: false) }
                }
                VStack(alignment: .leading, spacing: 9) {
                    Label("保存完整排列，不搬应用窗口", systemImage: "rectangle.on.rectangle").font(.callout.weight(.semibold))
                    Text("连接时核对该屏原来的位置、旋转与显示模式；若检测到其他屏幕已被调整，会停止自动恢复并提示。应用窗口不会搬回原屏，断开时的窗口迁移由 macOS 和各 App 决定。").font(.caption).foregroundStyle(.secondary)
                    if !model.simulation {
                        Label("单次现场测试 · 主屏和最后一屏受保护", systemImage: "lock.shield").font(.caption).foregroundStyle(.orange)
                        Text("部分屏幕可能仍需物理拔插；独立恢复进程不能保证硬件或 WindowServer 故障时恢复。").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
                HStack { Text(model.displayedStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled); Spacer(); Text("OmniDisplay 0.5 · 屏幕与工作模式").font(.caption2).foregroundStyle(.tertiary) }
            }.padding(30)
        }.background { ZStack { Color(nsColor: .windowBackgroundColor); LinearGradient(colors: [accent.opacity(0.12), .clear, Color.cyan.opacity(0.06)], startPoint: .topTrailing, endPoint: .bottomLeading) }.ignoresSafeArea() }.tint(accent)
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.busy { TransactionBanner(model: model).padding(16).background(.regularMaterial) }
        }
        .sheet(item:$model.modePreview) { preview in ModeReview(model:model,preview:preview) }
        .sheet(item: $model.actionDisplay, onDismiss: { model.confirmation = nil; model.physicalConfirmed = false; model.testRiskAcknowledged = false }) { display in
            VStack(spacing: 0) {
                HStack { Text("屏幕操作").font(.headline); Spacer(); Button("完成") { model.actionDisplay = nil }.keyboardShortcut(.cancelAction) }.padding(20)
                Divider()
                ScrollView { ScreenActions(model: model, displayID: display.id) }.frame(maxHeight: 560)
            }.frame(width: 440)
        }

    }
}

struct DisplayMap: View {
    @ObservedObject var model: AppModel
    var body: some View {
        GeometryReader { geometry in
            let screens = model.displays
            let minX = screens.map { Double($0.x) }.min() ?? 0
            let minY = screens.map { Double($0.y) }.min() ?? 0
            let maxX = screens.map { Double($0.x) + Double($0.width) }.max() ?? 1
            let maxY = screens.map { Double($0.y) + Double($0.height) }.max() ?? 1
            let scale = min((geometry.size.width-12)/max(maxX-minX,1), (geometry.size.height-14)/max(maxY-minY,1))
            ZStack {
                ForEach(screens) { d in
                    ScreenTile(model: model, display: d)
                        .frame(width: max(25,Double(d.width)*scale-5), height: max(28,Double(d.height)*scale-5))
                        .position(x:(Double(d.x)-minX+Double(d.width)/2)*scale+(geometry.size.width-(maxX-minX)*scale)/2, y:(Double(d.y)-minY+Double(d.height)/2)*scale+(geometry.size.height-(maxY-minY)*scale)/2)
                }
            }
        }
    }
}
struct ScreenTile: View {
    @ObservedObject var model: AppModel
    let display: Display
    var body: some View {
        Button { model.openActions(display.id) } label: {
            VStack(spacing: 6) {
                if display.main { Circle().fill(.white).frame(width: 5,height: 5) }
                Text(display.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.5)
                Text(display.active ? (display.main ? "主屏" : "已连接") : "未活动").font(.caption2)
            }.foregroundStyle(display.active ? .white : .secondary).frame(maxWidth: .infinity,maxHeight: .infinity)
                .background(LinearGradient(colors: display.active ? (display.main ? [accent,.cyan.opacity(0.8)] : [accent.opacity(0.6),.gray.opacity(0.5)]) : [.gray.opacity(0.12),.gray.opacity(0.05)], startPoint: .topLeading,endPoint: .bottomTrailing), in:RoundedRectangle(cornerRadius:12))
                .overlay { RoundedRectangle(cornerRadius:12).strokeBorder(display.active ? Color.white.opacity(0.6) : Color.secondary.opacity(0.4),style:StrokeStyle(lineWidth:1,dash:display.active ? [] : [5,4])) }
        }.buttonStyle(.plain).accessibilityLabel("\(display.label)，\(display.active ? "已连接" : "未活动")，点击操作")
    }
}
struct DisplayRow: View {
    @ObservedObject var model: AppModel
    let display: Display
    let compact: Bool
    var body: some View {
        Button { model.openActions(display.id) } label: {
            HStack(spacing: 12) {
                Image(systemName: display.builtin ? "laptopcomputer" : "display").font(.system(size: 22,weight:.light)).foregroundStyle(display.active ? accent : .secondary).frame(width:30)
                VStack(alignment:.leading,spacing:4) {
                    Text(display.name + (display.main ? " · 主屏" : "")).font(.callout.weight(.medium)).lineLimit(1)
                    Text(compact ? display.shortID : "\(display.width)×\(display.height) · \(Int(display.rotation))° · \(display.shortID)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Circle().fill(display.active ? .green : .gray.opacity(0.5)).frame(width:6,height:6)
                Image(systemName:"chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }.padding(compact ? 10 : 16).contentShape(Rectangle())
                .background(.background.opacity(0.6),in:RoundedRectangle(cornerRadius:14))
        }.buttonStyle(.plain).help("\(display.id) · \(display.active ? "活动" : "未活动：可能软件停用或视频线断开")")
    }
}
struct ScreenActions: View {
    @ObservedObject var model: AppModel
    let displayID: String
    var body: some View {
        VStack(alignment:.leading,spacing:15) {
            if let d = model.displays.first(where: { $0.id == displayID }) {
                HStack { Image(systemName:"display").foregroundStyle(accent); Text(d.name).font(.headline); Spacer(); Text(d.active ? "已连接" : "未活动").font(.caption).foregroundStyle(d.active ? .green : .secondary) }
                Text("身份 \(d.shortID) · \(d.width)×\(d.height) · \(Int(d.rotation))°").font(.caption).foregroundStyle(.secondary)
                if model.confirmation == nil || model.selectedID != displayID {
                    Button { model.choose(d.id); model.prepare(.connect) } label: { Label("连接这块屏幕",systemImage:"link").frame(maxWidth:.infinity,alignment:.leading) }.disabled(model.reason(for:.connect,display:d) != nil)
                    Button { model.choose(d.id); model.prepare(.disconnect) } label: { Label(model.simulation ? "断开这块屏幕" : "单次断开测试…",systemImage:"link.badge.plus").frame(maxWidth:.infinity,alignment:.leading) }.disabled(model.reason(for:.disconnect,display:d) != nil)
                    if let reason = model.reason(for:d.active ? .disconnect : .connect,display:d) { Text(reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true) }
                    Divider()
                    InputSourceControls(model: model, display: d)
                } else if let action = model.confirmation {
                    Text(action == .connect ? "连接目标并恢复完整原排列，不搬应用窗口。" : "只断开所选屏幕；保留主屏、旋转及相对顺序，剩余屏幕可能临时靠拢。连接时恢复完整原排列；核验后开始45秒确认。").font(.callout).fixedSize(horizontal: false, vertical: true)
                    if action == .disconnect {
                        Text(model.temporaryLayoutPreview(target: d.id)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Picker("保留实体屏幕",selection:$model.retained) { ForEach(model.displays.filter { $0.active && $0.id != d.id }) { peer in Text(peer.label).tag(peer.id) } }
                        Toggle("确认保留的是活动实体屏幕",isOn:$model.physicalConfirmed).font(.caption)
                        if !model.simulation {
                            Text("此屏会黑屏，悠悠可能短断。45秒不确认会尝试回连，但硬件/系统故障时可能失败。届时只拔插这块屏的视频线；不要拔主屏或扩展坞。").font(.caption).fixedSize(horizontal: false, vertical: true)
                            Toggle("我在现场，能操作该屏菜单并单独拔插视频线", isOn: $model.testRiskAcknowledged).font(.caption)
                        }
                    }
                    HStack { Button("取消") { model.confirmation = nil }; Spacer(); Button(model.simulation ? "模拟执行" : (action == .disconnect ? "确认断开 \(d.name)" : "确认连接 \(d.name)")) { model.executeSelected() }.buttonStyle(.borderedProminent).disabled(model.busy || (action == .disconnect && (!model.physicalConfirmed || (!model.simulation && (!model.testRiskAcknowledged))))) }
                }
                if model.busy { Text(model.status).font(.caption).foregroundStyle(.secondary) }
            } else { Text("屏幕身份已变化，请刷新后重新选择。") }
        }.padding(20).frame(width:440)
            .onChange(of: model.retained) { _ in model.physicalConfirmed = false; model.testRiskAcknowledged = false }
    }
}

struct InputSourceControls: View {
    @ObservedObject var model: AppModel
    let display: Display
    @State private var choice: UInt16 = 0
    @State private var reviewing = false
    @State private var physical = false
    @State private var portLabel = ""
    @State private var osdConfirmed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("输入源", systemImage: "cable.connector").font(.callout.weight(.semibold))
                Spacer()
                Button(model.probingInput == display.id ? "读取中…" : "只读检测") { model.probeInput(display.id); reviewing = false; physical = false }
                    .disabled(model.busy || model.probingInput != nil || !display.active)
            }
            if let probe = model.inputProbes[display.id] {
                Text("Mac 连接：\(display.active ? "已启用" : "未启用")").font(.caption)
                if let requested=model.requestedInputs[display.id] { Text("上次请求：\(model.mappedInputPorts(display.id).first{$0.code==requested}?.label ?? InputProbe.label(requested)) · 不代表物理画面已切换").font(.caption).foregroundStyle(.secondary) }
                Text(probe.state.title).font(.caption).foregroundStyle(probe.state == .readable ? .primary : .secondary)
                if let current = probe.current { Text("最后读回：" + (model.mappedInputPorts(display.id).first(where: { $0.code == current })?.label ?? InputProbe.label(current))).font(.callout.monospacedDigit()) }
                if probe.state != .readable { Text("未取得可靠输入值，禁止试写。请检查实体菜单中 DDC/CI；当前链路或系统也可能不支持。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                DisclosureGroup("检测详情") { ScrollView { Text(probe.detail).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }.frame(height: 90) }.font(.caption)
                if probe.state == .readable {
                    if !model.simulation {
                        DisclosureGroup("记录实体端口（不切换）") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("先在屏幕实体菜单查看当前输入名称，记录此读数。再由你手动切到另一输入并重新检测、记录。若切走后无法读取，就不能安全开放软件切源。").font(.caption).fixedSize(horizontal: false, vertical: true)
                                TextField("OSD 名称，例如 HDMI 1（Mac）", text: $portLabel).textFieldStyle(.roundedBorder)
                                Toggle("已在实体 OSD 核对当前输入", isOn: $osdConfirmed).font(.caption)
                                Button("记录当前端口") { model.recordInputPort(display.id, label: portLabel, osdConfirmed: osdConfirmed); osdConfirmed = false; portLabel = "" }.disabled(!osdConfirmed || portLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
                                Text("本次系统启动已记录 \(model.mappedInputPorts(display.id).count) 个端口").font(.caption2).foregroundStyle(.secondary)
                            }.padding(.top, 4)
                        }.font(.caption)
                    }
                    if model.simulation || model.inputTestReason(display) == nil {
                        Picker("目标输入", selection: $choice) {
                            if model.simulation { Text("选择输入源").tag(UInt16(0)); ForEach([UInt16(0x11), 0x0F], id: \.self) { Text(InputProbe.label($0)).tag($0) } }
                            else { Text("选择已记录端口").tag(UInt16(0)); ForEach(model.mappedInputPorts(display.id)) { Text($0.label).tag($0.code) } }
                        }
                        if reviewing {
                            Text("从：\(model.mappedInputPorts(display.id).first(where: { $0.code == probe.current })?.label ?? InputProbe.label(probe.current ?? 0)) → 到：\(model.mappedInputPorts(display.id).first(where: { $0.code == choice })?.label ?? InputProbe.label(choice))").font(.callout).fixedSize(horizontal: false, vertical: true)
                            Text("只切换 \(display.name)。45秒内未确认将尝试恢复原输入。切走后可能失去 DDC 通道，软件不能保证切回；请准备使用实体 OSD 选回 Mac 原输入。").font(.caption).fixedSize(horizontal: false, vertical: true)
                            Toggle("我在现场，保留另一块可见实体屏，并会用 OSD 切回", isOn: $physical).font(.caption)
                            HStack {
                                Button("取消") { reviewing = false; physical = false }
                                Button(model.simulation ? "确认模拟切源" : "确认切换 \(display.name)") { model.changeInput(display.id, to: choice, confirmed: physical); reviewing = false; physical = false }.disabled(!physical || model.busy)
                            }
                        } else { Button(model.simulation ? "预览模拟切源" : "预览单次切源测试") { reviewing = true; physical = false }.disabled(model.busy || choice == probe.current || choice == 0 || model.activeCount < 2 || (!model.simulation && !model.mappedInputPorts(display.id).contains(where: { $0.code == choice }))) }
                    } else if let reason = model.inputTestReason(display) { Text(reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
            } else { Text("Mac连接：\(display.active ? "已启用" : "未启用")。尚无信号源读数；检测不会切换输入。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }.onChange(of: choice) { _ in reviewing = false; physical = false }
    }
}
