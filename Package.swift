// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "OmniDisplay", platforms: [.macOS(.v14)], products: [
    .executable(name: "OmniDisplay", targets: ["OmniDisplay"]),
    .executable(name: "OmniRecovery", targets: ["OmniRecovery"]),
    .executable(name: "OmniDisplayCtl", targets: ["OmniDisplayCtl"])
], targets: [
    .target(name: "OmniRotation", publicHeadersPath: "include"),
    .target(name: "OmniDDC", publicHeadersPath: "include", linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreGraphics"), .linkedFramework("ColorSync")]),
    .target(name: "OmniCore", dependencies: ["OmniRotation", "OmniDDC"]),
    .executableTarget(name: "OmniDisplay", dependencies: ["OmniCore"]),
    .executableTarget(name: "OmniRecovery", dependencies: ["OmniCore"]),
    // 命令行 omnidisplay（装进 App 的 Helpers；目标名不能叫 omnidisplay，大小写不敏感的盘上会和 OmniDisplay 撞名）。
    .executableTarget(name: "OmniDisplayCtl", dependencies: ["OmniCore"]),
    .testTarget(name: "OmniDisplayUITests", dependencies: ["OmniDisplay"]),
    .testTarget(name: "OmniCoreTests", dependencies: ["OmniCore"], resources: [.copy("Fixtures")])
], swiftLanguageModes: [.v5])
