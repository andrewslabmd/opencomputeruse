// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "OpenComputerUse", platforms: [.macOS(.v15)], products: [
    .executable(name: "OpenComputerUse", targets: ["OpenComputerUse"]),
    .executable(name: "ocu-helper", targets: ["ComputerUseHelper"])
], targets: [
    .executableTarget(name: "OpenComputerUse", path: "apps/macos"),
    .executableTarget(name: "ComputerUseHelper", path: "packages/native"),
    .testTarget(name: "SnapshotAttributeTests", dependencies: ["ComputerUseHelper"], path: "tests/native")
], swiftLanguageModes: [.v5])
