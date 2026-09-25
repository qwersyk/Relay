// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Relay", platforms: [.macOS(.v14)], products: [
    .executable(name: "Relay", targets: ["RelayApp"]),
    .executable(name: "relay-cli", targets: ["RelayCLI"])
], targets: [
    .target(name: "RelayCore"),
    .executableTarget(name: "RelayApp", dependencies: ["RelayCore"]),
    .executableTarget(name: "RelayCLI", dependencies: ["RelayCore"]),
    .testTarget(name: "RelayCoreTests", dependencies: ["RelayCore"])
], swiftLanguageModes: [.v5])
