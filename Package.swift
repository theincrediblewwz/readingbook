// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReadingBook",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "ReadingBook", targets: ["ReadingBook"])],
    targets: [
        .target(name: "ReadingCore"),
        .executableTarget(name: "ReadingBook", dependencies: ["ReadingCore"]),
        .testTarget(name: "ReadingCoreTests", dependencies: ["ReadingCore"])
    ],
    swiftLanguageModes: [.v5]
)
