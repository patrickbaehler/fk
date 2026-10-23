// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Fontwerk",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Fontwerk",
            path: "Sources/Fontwerk"
        )
    ]
)
