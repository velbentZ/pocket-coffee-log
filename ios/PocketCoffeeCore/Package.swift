// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PocketCoffeeCore",
    defaultLocalization: "zh-Hans",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "PocketCoffeeCore",
            targets: ["PocketCoffeeCore"]
        ),
    ],
    targets: [
        .target(
            name: "PocketCoffeeCore",
            path: "Sources/PocketCoffeeCore"
        ),
        .testTarget(
            name: "PocketCoffeeCoreTests",
            dependencies: ["PocketCoffeeCore"],
            path: "Tests/PocketCoffeeCoreTests"
        ),
    ]
)
