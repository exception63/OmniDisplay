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
            if !compact { Text("完整排列单独保存；远程失败回退入口，办公室恢复不会重新关闭已连接屏幕。输入源独立控制。").font(.caption).foregroundStyle(.secondary) }
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
            Text(r.operation == .remoteMode ? "确认进入远程单屏" : "确认恢复办公室").font(.title2.bold())
            Text("保留画面：\(r.office.displays.first{$0.id==r.keep}?.name ?? "未知")").font(.headline)
            ScrollView {
                if let plan=try? ModePlan.make(r) {
                    ForEach(Array(plan.steps.enumerated()),id:\.offset) { index,step in
                        let name=r.office.displays.first{$0.id==step.target}?.name ?? "屏幕排列与主屏"
                        Text("\(index+1). \(step.action == .enable ? "连接" : step.action == .disable ? "断开" : "核对并恢复") · \(name)").frame(maxWidth:.infinity,alignment:.leading)
                    }
                }
            }.frame(maxHeight:180)
            Text((r.operation == .remoteMode ? "先确认保留屏已启用，再逐块断开其他屏幕。" : "逐块连接管理屏幕，恢复办公室完整排列、旋转与主屏。") + (r.operation == .officeMode ? "排列可能变化，应用窗口不搬回。失败时保留已连接屏幕并报告尚未恢复的项目；取消或45秒未确认也不会重新断屏。" : "切换期间排列可能变化，应用窗口不搬回。完成后45秒未确认，将恢复本次切换前状态。")).font(.callout)
            if !model.simulation { Text("悠悠可能短断。须能通过显示器实体OSD选回Mac，并单独重新插拔视频线；软件恢复不能保证硬件/WindowServer故障。").font(.caption).foregroundStyle(.secondary) }
            Toggle(model.simulation ? "确认仅执行模拟" : "我在现场，保留屏可见，并能手动恢复受影响屏幕",isOn:$physical)
            HStack { Button("取消") { model.modePreview=nil };Spacer();Button(model.simulation ? "模拟切换" : "确认本次模式切换") { model.executeMode(preview,confirmed:physical) }.buttonStyle(.borderedProminent).disabled(!physical || model.busy) }
        }.padding(24).frame(width:500)
    }
}
