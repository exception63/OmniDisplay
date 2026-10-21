import Foundation
import OmniCore

// omnidisplay：让快捷助手、Claude、Codex 和终端控制屏幕（用户 2026-10-21 授权 agent 直接执行）。
// 只是个遥控器：请求放进本机收件箱，真正干活、做全部安全检查的是 OmniDisplay App。
let usage = """
用法：omnidisplay <命令> [--json]
  list                          列出屏幕（从左到右编号）
  disconnect <n>                断开第 n 块（主屏不能断）
  connect <n>                   连接第 n 块
  connect all                   全部接回（= 办公室模式）
  mode office|remote            办公室模式（全部屏幕）/ 远程模式（只留主屏）
  rotate <n> left|right|flip    第 n 块逆时针90° / 顺时针90° / 翻转180°
  save-layout                   把当前排列存为办公室基线（屏幕要全部连着）
屏幕从左到右编号；断开中间一块，后面的不改号。
"""

var args = Array(CommandLine.arguments.dropFirst())
let asJSON = args.contains("--json")
args.removeAll { $0 == "--json" }

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8)); exit(code)
}
guard let verb = args.first else { print(usage); exit(0) }
func number(at index: Int) -> Int {
    guard args.count > index, let n = Int(args[index]), n > 0 else { fail("要说第几块，比如：omnidisplay \(verb) 4") }
    return n
}

var request: AgentRequest
switch verb {
case "list", "status": request = AgentRequest(command: .list)
case "disconnect": request = AgentRequest(command: .disconnect, number: number(at: 1))
case "connect":
    request = args.count > 1 && args[1] == "all" ? AgentRequest(command: .connect, all: true) : AgentRequest(command: .connect, number: number(at: 1))
case "mode":
    guard args.count > 1, let mode = ["office": AgentCommand.office, "remote": .remote][args[1]] else { fail("mode 后面跟 office（办公室）或 remote（远程）") }
    request = AgentRequest(command: mode)
case "rotate":
    let n = number(at: 1)
    let directions = ["left": "counterclockwise", "ccw": "counterclockwise", "right": "clockwise", "cw": "clockwise", "flip": "flip"]
    guard args.count > 2, let direction = directions[args[2]] else { fail("rotate <n> 后面跟 left（逆时针90°）、right（顺时针90°）或 flip（翻转180°）") }
    request = AgentRequest(command: .rotate, number: n, rotation: direction)
case "save-layout": request = AgentRequest(command: .saveLayout)
case "help", "-h", "--help": print(usage); exit(0)
default: fail("不认识的命令：\(verb)\n\n\(usage)")
}

// 发给哪个 App：就是装着这个命令的那个包（~/.local/bin 里的软链会解析到包里）。模拟版的包发给模拟版。
let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
let appURL = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
guard appURL.pathExtension == "app", let bundleID = Bundle(url: appURL)?.bundleIdentifier else {
    fail("请用 OmniDisplay.app 里的 Contents/Helpers/omnidisplay（或指向它的软链）。", code: 1)
}
let simulation = bundleID.hasSuffix(".simulation")
let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
let instanceKey = bundleID + (simulation ? ".demo" : ".production")
let directory = AgentMailbox.directory(support: support, instanceKey: instanceKey)
do { try AgentMailbox.prepare(directory) } catch { fail("收件箱建不起来：\(error.localizedDescription)", code: 1) }

// App 没开着就在后台拉起来（不弹管理窗口），等它占上实例锁。
if !AgentMailbox.instanceRunning(support: support, instanceKey: instanceKey) {
    if simulation { fail("模拟版没在跑（它要带 --demo / --data-dir 启动）。", code: 1) }
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["-g", appURL.path, "--args", "--agent"]
    try? open.run(); open.waitUntilExit()
    let until = Date().addingTimeInterval(15)
    while !AgentMailbox.instanceRunning(support: support, instanceKey: instanceKey) && Date() < until { Thread.sleep(forTimeInterval: 0.2) }
    guard AgentMailbox.instanceRunning(support: support, instanceKey: instanceKey) else { fail("OmniDisplay 没能启动，什么也没做。", code: 1) }
}

request.createdAt = Date()
let millis = Int(request.createdAt.timeIntervalSince1970 * 1000)
let file = AgentMailbox.requests(directory).appendingPathComponent("\(millis)-\(request.id).json")
let answer = AgentMailbox.responses(directory).appendingPathComponent("\(request.id).json")
do { try AgentMailbox.write(request, to: file) } catch { fail("请求写不进去：\(error.localizedDescription)", code: 1) }

let deadline = Date().addingTimeInterval(request.command == .list || request.command == .saveLayout ? 20 : 150)
var response: AgentResponse?
while Date() < deadline {
    if let read = try? AgentMailbox.read(AgentResponse.self, from: answer) {
        response = read; try? FileManager.default.removeItem(at: answer); break
    }
    // 没被接手就撤回：App 那边过期的请求也不会执行。
    if Date().timeIntervalSince(request.createdAt) > AgentMailbox.maxAge, (try? FileManager.default.removeItem(at: file)) != nil {
        fail("OmniDisplay \(Int(AgentMailbox.maxAge)) 秒内没有接这个请求，已撤回，什么也没做。", code: 1)
    }
    Thread.sleep(forTimeInterval: 0.1)
}
guard let response else { fail("等了 \(Int(deadline.timeIntervalSince(request.createdAt))) 秒还没有结果；操作可能还在进行，稍后用 omnidisplay list 核对。", code: 1) }

if asJSON {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    print(String(decoding: (try? encoder.encode(response)) ?? Data(), as: UTF8.self))
} else {
    print((response.ok ? "✓ " : "✗ ") + response.message)
    if !response.screens.isEmpty {
        print("屏幕（从左到右）：")
        for screen in response.screens {
            var line = "  \(screen.number)  \(screen.portrait ? "竖屏" : "横屏")  \(screen.connected ? "连着" : "已断开")"
            if screen.main { line += "  主屏" }
            print(line)
        }
    }
}
exit(response.ok ? 0 : 1)
