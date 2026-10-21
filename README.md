# OmniDisplay 1.1.0

原生 macOS 菜单栏显示器管理工具，使用 SwiftUI / AppKit。中文窗口动态显示屏幕、连接状态与排列；macOS 26+ 使用正式 Liquid Glass API，旧系统使用原生材质。

1.0保留单屏连接/断开、办公室/远程单屏模式，新增基于当前画面的逆时针90°、顺时针90°、翻转180°内联按钮。常用操作放在屏幕卡片中，历史错误与说明收进“诊断与帮助”。输入源与校准入口已移除，使用显示器实体菜单切换；旧数据保留。

## 功能与边界

- 点击屏幕卡片下方的相对方向按钮，在卡片内核对；仅用户核对目标和现场条件、最终确认后执行。45秒内未保留或主动恢复时，尝试回到旋转前的排列。
- 保留方向后，独立办公室完整基线同步更新。远程单屏只更新完整基线中的该屏，不把单屏覆盖为办公室配置。[旋转规则与现场步骤](docs/ROTATION.md)。
- 单屏断开会按已验证方案临时靠拢，重连恢复完整原排列；办公室恢复不重新关闭已连接屏幕。[布局规则](docs/TEMPORARY_LAYOUT.md) · [模式规则](docs/MODES.md)。
- 身份不明、镜像、并发调整或无法安全规划时拒绝。不会关闭最后实体屏；恢复不关闭新接入屏幕，不搬其他App窗口，不自动判断悠悠会话。
- 每次实际写入需要请求绑定的一次许可与独立helper握手，没有永久解锁。UUID优先；仅恢复允许同次开机、唯一指纹匹配的缺UUID回退。

**相对旋转的实机视觉方向和恢复尚未验收。** 当前Mac Studio/macOS27.0.1四屏只读报告支持方向调整，但能力存在不代表旋转或恢复成功。过去单屏测试与远程保持有成功记录，办公室恢复修复仍待现场复测。软件无法保证WindowServer或硬件故障时恢复；其他机器、Intel、旧系统降级与长期稳定性未验证。[验收记录](docs/VALIDATION.md)。

## 命令行与 agent（1.1）

`omnidisplay` 在 App 包的 `Contents/Helpers/` 里（本机 `~/.local/bin/omnidisplay` 是指向它的软链）。快捷助手、Claude、Codex 和终端都用它控制屏幕，真正执行和做全部安全检查的仍是 App。

- `omnidisplay list`：从左到右编号，连着没有、哪块是主屏
- `omnidisplay disconnect <n>` / `connect <n>` / `connect all`（全部接回 = 办公室模式）
- `omnidisplay mode office|remote`：办公室模式（全部屏幕）/ 远程模式（只留主屏）
- `omnidisplay rotate <n> left|right|flip`：逆时针90° / 顺时针90° / 翻转180°
- `omnidisplay save-layout`：把当前排列存为办公室基线（屏幕要全部连着）
- 加 `--json` 输出结构化结果；成功退出码 0，被拒或失败 1

规则：
- 屏幕从左到右编号；有断开的时候按断开前的完整排列数，断开中间一块，后面的不改号。
- agent 发起的操作不经二次确认（用户 2026-10-21 授权）：helper 核验通过后由 App 自动保留，不弹确认面板。主屏不能断，agent 的远程模式只留主屏；其余拒绝理由和手动相同。用户在 App 里手动操作仍要二次确认。
- 命令行把请求写进本机收件箱（`~/Library/Application Support/OmniDisplay/Agent/<实例>/`，仅本用户可读写）；20 秒内没被 App 接手的请求作废，不会在 App 之后启动时补执行。App 没开时命令行在后台拉起它（`--agent`，不弹管理窗口）。
- 重启后办公室基线过期时，若屏幕全部连着，第一次切模式会以当前排列为准（等于手动「保存当前排列」）。
- 每笔事务的 `request.json` 记 `origin: "agent"`；模拟端到端检查是 `scripts/test-agent.py`（先 `scripts/build.sh --simulation`）。

## 构建与启动

需要 Xcode 27 SDK、Swift 工具链及 Python 3（仅运行进程测试时需要）。本次构建环境为 Swift 6.4 / macOS 27.0.1。部署目标为 macOS 14；14/15 的材质降级与 Intel 实机尚未验证，DDC 路由实现仅面向可明确识别的 Apple Silicon 硬件。无第三方 Swift 包依赖。

```sh
./scripts/build.sh
open dist.noindex/OmniDisplay.app
```

产物为 `dist.noindex/OmniDisplay.app`，内含 `OmniRecovery` helper。仅启动或打开管理窗口不会更改显示设置。关闭窗口后菜单栏应用继续运行，可用 ⌘0 打开管理窗口。可在无待处理事务时退出应用，将整个 `.app` 拷贝至 `/Applications` 后再启动；不要同时运行两份。

构建脚本进行本地 ad-hoc 签名；项目未提供开发者签名、公证或安装包，不应通过关闭系统安全保护来安装。应用不要求辅助功能或屏幕录制权限。底层显示启停、旋转和 DDC 含私有接口，API 存在只说明符号可加载，不保证某台机器可安全恢复；不保证未来 macOS 兼容。

## 第一次现场测试

1. 保持另一块实体屏有画面，先确认能通过目标屏实体 OSD 选回 Mac 输入，并能单独重新插拔目标视频线。远程连接可能短暂中断，不要首次在无人现场时测试。
2. 在管理窗选择一块非主屏外接显示器，打开“单次断开测试…”，核对目标、保留屏及两项现场确认，再由自己点击最终确认。
3. 执行/恢复阶段保留进度面板；等待临时布局核验结束。45 秒确认面板显示在仍活动的原主屏，管理窗顶栏和菜单栏也显示倒计时。画面、旋转正常且排列符合临时预览后点 **“保留断开”**；不点击会在到期后尝试恢复。异常时点“立即恢复”。
4. 需要连接时选择该屏，点“连接这块屏幕”，核对并确认。屏幕布局恢复与其他 App 窗口回位是两件事，本应用不搬窗口。

如果恢复失败，停止重复测试；用目标屏 OSD 选择 Mac 输入，必要时仅重新插拔目标视频线。不要拔保留主屏或整个扩展坞。

1.0已移除输入源与校准入口；切换HDMI/DP请使用显示器实体菜单。旧校准记录保留。

## 验证与模拟

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" swift test --disable-sandbox --cache-path .build/cache --scratch-path .build
python3 scripts/test-recovery.py
python3 scripts/test-single-screen.py
python3 scripts/test-input.py
python3 scripts/test-audit.py
python3 scripts/test-temporary-layout.py
python3 scripts/test-modes.py
python3 scripts/test-rotation.py
```

先构建再运行 Python 测试；所有进程测试强制 `simulation=true`，不执行真实显示写入。SwiftPM 的 `--disable-sandbox` 只用于构建子进程，不更改系统安全设置。

退出其他 OmniDisplay 实例后，可查看模拟界面：

```sh
./scripts/build.sh --simulation
open "dist.noindex/OmniDisplay Simulation.app" --args --demo 4 --data-dir "$PWD/artifacts/demo"
```

模拟版使用独立名称、bundle ID、偏好、进程锁和 `Simulation` 数据子目录；即使不带参数打开也只会模拟。正式版拒绝 `--demo`，从搜索启动会沿用上次正式数据目录。`--demo` 可选择不同屏幕数量。测试夹具使用合成身份，保留多屏几何关系用于回归；模拟通过不是硬件兼容性证明。验证结果和已知限制见 [验收记录](docs/VALIDATION.md)。

1.0.1本地及公开副本各190项Swift单测（184核心+6UI布局/交互）、72项纯simulation检查通过，Release与App/helper严格签名通过。旋转真实执行尚未验收。

## 本地数据与隐私

默认数据目录为 `~/Library/Application Support/OmniDisplay`，保存布局、身份缓存、端口记录及事务审计。诊断数据可能包含屏幕 UUID、序列号、开机标识及本地路径。**提交 issue 前请脱敏，不要直接上传整个数据目录、原始日志或桌面截图。** 本仓库不包含现场原始日志、许可文件、用户配置、真实身份夹具或构建缓存。

## 许可证与来源

沿用项目现有 MIT 许可证，公开署名为 GitHub 账号 `exception63`。aspace、displayplacer、m1ddc 的静态参考及原始许可证列于 [第三方说明](THIRD_PARTY_NOTICES.md)，构建时随 App 打包。未运行下载的上游程序，未复制 GPL 源码。

正式安装位置为 `/Applications/OmniDisplay.app`。构建与备份位于不索引目录，Spotlight只保留正式入口。历代修复及现场限制统一见[验收记录](docs/VALIDATION.md)。
