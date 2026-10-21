// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Ata",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Ata", path: "Sources/Ata"),
        .testTarget(name: "AtaTests", dependencies: ["Ata"], path: "Tests/AtaTests"),
    ]
)
