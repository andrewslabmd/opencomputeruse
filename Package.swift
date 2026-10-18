// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "OpenComputerUse", platforms: [.macOS(.v15)], products: [
    .executable(name: "OpenComputerUse", targets: ["OpenComputerUse"]),
    .executable(name: "ocu-helper", targets: ["ComputerUseHelper"])
], targets: [
    // Record the real SDK (not the deployment target) so macOS draws the app with
    // the current system design instead of its compatibility appearance.
    .executableTarget(name: "OpenComputerUse", path: "apps/macos", linkerSettings: [
        .unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "macos", "-Xlinker", "15.0", "-Xlinker", "27.0"])
    ]),
    .executableTarget(name: "ComputerUseHelper", path: "packages/native"),
    .testTarget(name: "SnapshotAttributeTests", dependencies: ["ComputerUseHelper"], path: "tests/native")
], swiftLanguageModes: [.v5])
