// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "MacShade",
    platforms: [.macOS(.v13)],
    targets: [.executableTarget(name: "MacShade")]
)
