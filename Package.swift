// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Ata",
    // 14.2: Core Audio process taps, for recording system audio without Screen Recording.
    platforms: [.macOS("14.2")],
    dependencies: [
        // On-device speaker diarization and voice embeddings for "who said what".
        // traits: [] leaves out FluidAudio's default NemoTextProcessing trait, an
        // 87 MB prebuilt library used only for text-to-speech, which Ata never does.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: []),
    ],
    targets: [
        .executableTarget(name: "Ata",
                          dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
                          path: "Sources/Ata"),
        .testTarget(name: "AtaTests", dependencies: ["Ata"], path: "Tests/AtaTests"),
    ],
    swiftLanguageModes: [.v5]
)
