// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "dsh-control",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "dsh-control", targets: ["dsh-control"])],
    targets: [
        .target(name: "CSessionZstd"),
        .target(name: "DSHControlCore", dependencies: ["CSessionZstd"]),
        .executableTarget(name: "dsh-control", dependencies: ["DSHControlCore"]),
        .testTarget(name: "DSHControlCoreTests", dependencies: ["DSHControlCore"]),
    ],
    swiftLanguageModes: [.v6]
)
