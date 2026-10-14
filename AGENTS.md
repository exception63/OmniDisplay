# OmniDisplay

Read README.md and docs/VALIDATION.md before changing behavior. Keep the native SwiftUI/macOS architecture.

- Automated agents must not disconnect physical screens, switch inputs, change main display, rotate displays, reboot or log out to test. Use read-only inspection and simulation.
- Real writes require a user-selected target and explicit in-app confirmation, a request-bound single-use permit and a ready recovery helper. No global unlock, batch remote/office mode, or moving other apps' windows.
- Never disable the last retained physical screen. Reject ambiguous identity/topology and mirroring. Preserve layout/rotation; recovery must not disable newly attached screens.
- UUID is primary. The same-boot unique-fingerprint fallback is recovery-only, for missing UUIDs; different nonempty UUIDs or ambiguous fingerprints must fail closed. Never use that fallback for disable/input switching.
- After safety changes run swift test and all four scripts/test-*.py simulation suites. Do not mistake simulated success or private-symbol availability for hardware validation.
- Do not run downloaded upstream programs, incorporate GPL implementations, install drivers, or request unrelated permissions.
- Keep diagnostics, real display identifiers, local configuration and personal paths out of commits. Update docs/VALIDATION.md with measured evidence and explicit untested boundaries.
