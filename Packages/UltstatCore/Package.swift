// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UltstatCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "UltstatCore", targets: ["UltstatCore"]),
        .executable(name: "ultstat-smc", targets: ["ultstat-smc"]),
    ],
    targets: [
        .target(
            name: "CSMC",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .target(name: "CPrivate", linkerSettings: [.linkedFramework("IOKit"), .linkedLibrary("IOReport")]),
        .target(
            name: "UltstatCore",
            dependencies: ["CSMC", "CPrivate"],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")],
            linkerSettings: [.linkedFramework("IOBluetooth")]
        ),
        .executableTarget(name: "ultstat-smc", dependencies: ["UltstatCore"]),
        .executableTarget(name: "ultstat-bench", dependencies: ["UltstatCore", "CPrivate"]),
        .testTarget(name: "UltstatCoreTests", dependencies: ["UltstatCore"]),
    ]
)
