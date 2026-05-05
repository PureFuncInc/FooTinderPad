// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FooTinderPad",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "FooTinderPad",
            path: "Sources/FooTinderPad"
        ),
        .testTarget(
            name: "FooTinderPadTests",
            dependencies: ["FooTinderPad"],
            path: "Tests/FooTinderPadTests"
        ),
    ]
)
