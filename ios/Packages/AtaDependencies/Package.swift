// swift-tools-version:6.2
import PackageDescription

// The iPhone app's Swift packages. An Xcode project can't set package traits, and
// FluidAudio's default trait links an 87 MB text-to-speech library Ata never uses,
// so the app depends on this package, which depends on FluidAudio with no traits,
// exactly as the Mac's Package.swift does. Keep the version in step with it.
let package = Package(
    name: "AtaDependencies",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "AtaDependencies", targets: ["AtaDependencies"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: []),
    ],
    targets: [
        .target(name: "AtaDependencies",
                dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
                path: "Sources/AtaDependencies"),
    ],
    swiftLanguageModes: [.v5]
)
