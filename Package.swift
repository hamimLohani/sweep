// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "sweep",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "sweep", targets: ["sweep"]),
        .library(name: "SweepCore", targets: ["SweepCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0")
    ],
    targets: [
        .target(
            name: "SweepCore",
            dependencies: [],
            exclude: ["Resources"]
        ),
        .executableTarget(
            name: "sweep",
            dependencies: [
                "SweepCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .executableTarget(
            name: "sweep-tests",
            dependencies: ["SweepCore"]
        )
    ]
)
