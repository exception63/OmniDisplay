import SwiftUI
import OmniCore

struct ModePreview: Identifiable { let request: Request; var id:String { request.nonce } }
struct ModeControls: View {
    @ObservedObject var model:AppModel
    var compact=false
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            HStack { Label("工作模式",systemImage:"rectangle.3.group").font(.headline);Spacer() }
            Text(model.modeStatus).font(.caption).foregroundStyle(.secondary)
            Picker("远程保留",selection:$model.modeKeep) {
                ForEach(model.modeScreens) { Text($0.name).tag($0.id) }
            }.disabled(model.busy)
            HStack {
                Button { model.prepareMode(.officeMode) } label:{ Label("办公室",systemImage:"display.2") }
                Button { model.prepareMode(.remoteMode) } label:{ Label("远程单屏",systemImage:"display") }
            }.buttonStyle(.bordered).disabled(model.busy || model.probingInput != nil)

        }
    }
}
struct ModeReview: View {
    @ObservedObject var model:AppModel
    let preview:ModePreview
    @State private var physical=false
    var body:some View {
        let r=preview.request
        VStack(alignment:.leading,spacing:16) {
            if r.operation == .rotate {
                Text("确认旋转屏幕").font(.title2.bold())
                Text("\(r.before.displays.first{$0.id==r.target}?.name ?? "屏幕") → \(r.rotationDegrees ?? 0)°").font(.headline)
                if let plan=try? RotationPlan.make(r) {
                    let moved=plan.desired.filter { next in r.before.displays.contains { $0.id==next.id && ($0.x != next.x || $0.y != next.y) } }
                    Text(moved.isEmpty ? "其他屏幕保持原位。" : "为避免重叠，调整位置："+moved.map(\.name).joined(separator:"、")+"。主屏和顺序不变。").font(.callout)
                }
                Text("45秒内不确认会尝试恢复。保留后更新办公室排列；不搬应用窗口。").font(.callout)
                Toggle(model.simulation ? "仅模拟，不改变实体屏幕" : "我在现场，能核对画面并在系统设置恢复方向",isOn:$physical)
                if !model.simulation { Text("切换时可能短暂黑屏；硬件或系统故障时自动恢复可能失败。").font(.caption).foregroundStyle(.secondary) }
            } else {
                Text(r.operation == .remoteMode ? "进入远程单屏" : "恢复办公室").font(.title2.bold())
                Text("保留画面：\(r.office.displays.first{$0.id==r.keep}?.name ?? "未知")").font(.headline)
                if let plan=try? ModePlan.make(r) {
                    Text(r.operation == .remoteMode ? "将断开 \(plan.steps.filter{$0.action == .disable}.count) 块屏幕。" : "恢复 \(r.office.displays.count) 块屏幕及已保存排列。").font(.callout)
                }
                Text(r.operation == .officeMode ? "未确认或取消都会保留已连接屏幕。" : "45秒内不确认会尝试恢复原状态。").font(.callout)
                Toggle(model.simulation ? "仅模拟，不改变实体屏幕" : "我在现场，保留屏可见，能手动恢复屏幕",isOn:$physical)
                if !model.simulation { Text("远控可能短断；软件恢复失败时需操作显示器菜单或目标视频线。").font(.caption).foregroundStyle(.secondary) }
            }
            HStack {
                Button("取消") { model.modePreview=nil };Spacer()
                Button(model.simulation ? "模拟执行" : r.operation == .rotate ? "确认旋转" : "确认切换") { model.executeMode(preview,confirmed:physical) }
                    .buttonStyle(.borderedProminent).disabled(!physical || model.busy)
            }
        }.padding(24).frame(width:500)
    }
}
