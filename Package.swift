// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "rpmac",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "rpmac",
            path: "Sources/rpmac"
        )
    ]
)
