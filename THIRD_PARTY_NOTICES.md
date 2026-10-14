# Third-party references

OmniDisplay retains its existing MIT license. These MIT projects informed static API/protocol review; OmniDisplay uses its own wrappers and recovery policy, with no runtime dependency on their executables. Their original license notices are preserved in this repository and copied into the app Resources by the build script.

| Project | Reviewed revision | Notice |
|---|---|---|
| [aspace](https://github.com/asumaran/aspace) | `e862175d928d12ef3b8c95850deb59fc7ac81d3d` | [MIT / Alfredo Sumaran](References/aspace/LICENSE) |
| [displayplacer](https://github.com/jakehilborn/displayplacer) | `c23026eb3d73000eb1a14b45d82fd6dd08c921f5` | [MIT / Jake Hilborn](References/displayplacer/LICENSE) |
| [m1ddc](https://github.com/waydabber/m1ddc) | `04d949794102eb8df01ad3681afff6464a3eede2` | [MIT / Waydabber](References/m1ddc/LICENSE) |

The review covered display enable/disable declarations and UUID caching, display rotation declarations, and Apple Silicon IOAV DDC transport. The reference programs were not executed. Their compatibility reports are not evidence that OmniDisplay works on another macOS version or device.

MonitorControl's public Arm64DDC source was also consulted to cross-check Get VCP reply format and checksum rules; its matching implementation was not copied. GPL implementations, including SimpleDisplay and ddcutil, are not incorporated.

Private system symbols are dynamically detected and encapsulated in CoreGraphicsBackend, OmniRotation and OmniDDC. Availability checks do not prove recovery capability. Native glass uses the SDK's public SwiftUI `glassEffect(_:in:)` with an availability fallback; the macOS 27 status-item interface also has an older-system fallback.
