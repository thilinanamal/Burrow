// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Burrow",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Burrow",
            path: "Sources/Burrow"
        )
    ]
)
