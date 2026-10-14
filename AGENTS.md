# OmniDisplay

Read README.md and docs/VALIDATION.md before changing behavior. Keep the native SwiftUI/macOS architecture.

- Automated agents must not disconnect physical screens, switch inputs, change main display, rotate displays, reboot or log out to test. Use read-only inspection and simulation.
- Real writes require a user-selected target and explicit in-app confirmation, a request-bound single-use permit and a ready recovery helper. No global unlock, batch remote/office mode, or moving other apps' windows.
- Never disable the last retained physical screen. Reject ambiguous identity/topology and mirroring. Preserve layout/rotation; recovery must not disable newly attached screens.
- UUID is primary. The same-boot unique-fingerprint fallback is recovery-only, for missing UUIDs; different nonempty UUIDs or ambiguous fingerprints must fail closed. Never use that fallback for disable/input switching.
- After safety changes run swift test and all six scripts/test-*.py simulation suites. Do not mistake simulated success or private-symbol availability for hardware validation.
- Do not run downloaded upstream programs, incorporate GPL implementations, install drivers, or request unrelated permissions.
- Keep diagnostics, real display identifiers, local configuration and personal paths out of commits. Update docs/VALIDATION.md with measured evidence and explicit untested boundaries.

- 2026-10-14：允许单次断开中间屏后，剩余屏按预先验证的临时排列靠拢（主屏位置、旋转、相对顺序不变）；重连恢复独立保存的完整原排列。无法规划或出现并发调整时拒绝覆盖。此授权仅供用户在App主动测试，agent不执行。

- 2026-10-14新授权：开发办公室/远程多屏模式（独立完整基线、入口回退、单一helper保护）及每屏输入源选择；不复活旧不安全批量入口。仅用户在App确认后测试，agent仍不得执行真实写入。
