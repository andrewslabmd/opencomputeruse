// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "OpenComputerUse", platforms: [.macOS(.v15)], products: [
    .executable(name: "OpenComputerUse", targets: ["OpenComputerUse"]),
    .executable(name: "ocu-helper", targets: ["ComputerUseHelper"])
], dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4")
], targets: [
    // Record the real SDK (not the deployment target) so macOS draws the app with
    // the current system design instead of its compatibility appearance. Sparkle
    // is loaded from the bundle's Frameworks folder.
    .executableTarget(name: "OpenComputerUse", dependencies: [.product(name: "Sparkle", package: "Sparkle")], path: "apps/macos", linkerSettings: [
        .unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "macos", "-Xlinker", "15.0", "-Xlinker", "27.0",
                      "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
    ]),
    .executableTarget(name: "ComputerUseHelper", path: "packages/native"),
    .testTarget(name: "SnapshotAttributeTests", dependencies: ["ComputerUseHelper"], path: "tests/native")
], swiftLanguageModes: [.v5])
