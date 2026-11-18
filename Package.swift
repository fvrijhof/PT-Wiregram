// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Wiregram",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Wiregram",
            path: "Sources/Wiregram"
        )
    ]
)
