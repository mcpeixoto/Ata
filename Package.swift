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
        // LAME 3.100, vendored: macOS can play MP3 but has no MP3 encoder. See Sources/CLame/README.md.
        .target(name: "CLame",
                path: "Sources/CLame",
                exclude: ["COPYING", "README.md"],
                cSettings: [.define("HAVE_CONFIG_H"), .headerSearchPath(".")]),
        .executableTarget(name: "Ata",
                          dependencies: ["CLame", .product(name: "FluidAudio", package: "FluidAudio")],
                          path: "Sources/Ata",
                          // FoundationModels (summaries on this Mac) only exists from macOS 26:
                          // a weak link lets Ata still launch on 14 and 15. CI checks it stays weak.
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels"])]),
        .testTarget(name: "AtaTests", dependencies: ["Ata"], path: "Tests/AtaTests"),
    ],
    swiftLanguageModes: [.v5]
)
