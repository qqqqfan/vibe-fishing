// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MoyuRelay",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "MoyuRelay", targets: ["MoyuRelay"]),
        .executable(name: "relayctl", targets: ["relayctl"]),
        .library(name: "RelayCore", targets: ["RelayCore"])
    ],
    targets: [
        .target(name: "RelayCore"),
        .executableTarget(name: "MoyuRelay", dependencies: ["RelayCore"]),
        .executableTarget(name: "relayctl", dependencies: ["RelayCore"]),
        .testTarget(name: "RelayCoreTests", dependencies: ["RelayCore"])
    ],
    swiftLanguageModes: [.v5]
)
