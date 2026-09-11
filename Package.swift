// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Clix",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Clix", path: "Sources/Clix")
    ]
)
