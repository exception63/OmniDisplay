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
                            Text("屏幕").font(.system(size: 28, weight: .semibold))
                            Text("\(model.activeCount) 块已连接").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("刷新连接状态")
                }.padding(.top, 16)
                if model.simulation { Label("模拟模式 · \(model.demoCount) 屏 · 所有操作不改变真实显示器", systemImage: "testtube.2").foregroundStyle(.orange).font(.callout) }
                if let error = model.error { HStack(alignment: .top) { Image(systemName: "exclamationmark.triangle"); Text(error).textSelection(.enabled); Spacer(); Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }.font(.callout).foregroundStyle(.red).padding(15).background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 14)) }
                if model.modeFailureHistory != nil { Label("上次操作未完成 · 详见诊断",systemImage:"exclamationmark.circle").font(.caption).foregroundStyle(.orange) }
                ModeControls(model:model).padding(20).modifier(GlassCard())
                VStack(alignment: .leading, spacing: 18) {
                    HStack { Label("屏幕排列", systemImage: "rectangle.3.group").font(.headline); Spacer(); Text("\(model.activeCount) 活动 · \(model.displays.count) 已知").font(.caption).foregroundStyle(.secondary) }
                    DisplayMap(model: model).frame(height: 190)
                    HStack {
                        Text("点击屏幕以连接、断开或旋转").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("保存当前排列") { model.saveCurrentLayout() }.disabled(model.busy).help("只记录显示器位置、旋转和模式，不调整屏幕，不记录应用窗口")
                    }
                }.padding(24).modifier(GlassCard())
                HStack { Text("显示器").font(.headline); Spacer() }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 12)], spacing: 12) {
                    ForEach(model.sortedDisplays) { d in DisplayRow(model: model, display: d, compact: false) }
                }
                DisclosureGroup("诊断与帮助") {
                    VStack(alignment:.leading,spacing:10) {
                        Text(model.displayedStatus).font(.caption).textSelection(.enabled)
                        if let history=model.modeFailureHistory { Text("上次操作："+history).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        Text("保存显示器排列，不搬动其他 App 的窗口。恢复失败时，请现场核对显示器菜单或单独重插目标视频线。软件无法保证硬件或系统故障时恢复。").font(.caption).foregroundStyle(.secondary)
                        Text("OmniDisplay 1.0 · 本机版本 · 四方向旋转尚待现场验证").font(.caption2).foregroundStyle(.secondary)
                    }.padding(.top,8).frame(maxWidth:.infinity,alignment:.leading)
                }.font(.callout).foregroundStyle(.secondary)

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
                    Text("\(display.width)×\(display.height) · \(Int(display.rotation))°").font(.caption).foregroundStyle(.secondary)
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
                    Button { model.choose(d.id); model.prepare(.disconnect) } label: { Label("断开这块屏幕…",systemImage:"link.badge.plus").frame(maxWidth:.infinity,alignment:.leading) }.disabled(model.reason(for:.disconnect,display:d) != nil)
                    if let reason = model.reason(for:d.active ? .disconnect : .connect,display:d) { Text(reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true) }
                    Divider()
                    RotationControls(model:model, display:d)
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

struct RotationControls: View {
    @ObservedObject var model: AppModel
    let display: Display
    @State private var angle = 0
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Text("屏幕方向").font(.headline)
            Picker("方向",selection:$angle) {
                Text("横向 0°").tag(0);Text("竖向 90°").tag(90)
                Text("横向 180°").tag(180);Text("竖向 270°").tag(270)
            }.labelsHidden().pickerStyle(.segmented).disabled(model.rotationReason(display) != nil)
            if let reason=model.rotationReason(display) { Text(reason).font(.caption).foregroundStyle(.secondary) }
            Button("预览旋转…") { model.prepareRotation(display.id,degrees:angle) }
                .disabled(angle == Int(display.rotation) || model.rotationReason(display) != nil)
        }.onAppear { angle=Int(display.rotation) }
    }
}
