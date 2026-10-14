// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "OmniDisplay", platforms: [.macOS(.v14)], products: [
    .executable(name: "OmniDisplay", targets: ["OmniDisplay"]),
    .executable(name: "OmniRecovery", targets: ["OmniRecovery"])
], targets: [
    .target(name: "OmniRotation", publicHeadersPath: "include"),
    .target(name: "OmniDDC", publicHeadersPath: "include", linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreGraphics"), .linkedFramework("ColorSync")]),
    .target(name: "OmniCore", dependencies: ["OmniRotation", "OmniDDC"]),
    .executableTarget(name: "OmniDisplay", dependencies: ["OmniCore"]),
    .executableTarget(name: "OmniRecovery", dependencies: ["OmniCore"]),
    .testTarget(name: "OmniDisplayUITests", dependencies: ["OmniDisplay"]),
    .testTarget(name: "OmniCoreTests", dependencies: ["OmniCore"], resources: [.copy("Fixtures")])
], swiftLanguageModes: [.v5])
