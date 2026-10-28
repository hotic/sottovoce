// swift-tools-version:6.0
// Sottovoce: hold a hotkey and speak; on release the audio is transcribed by the Sottovoce server and pasted
// into the focused text field.
import PackageDescription

let package = Package(
    name: "Sottovoce",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Updates for release builds: a signed appcast on GitHub Releases, EdDSA-checked downloads, in-place install
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
    ],
    targets: [
        .executableTarget(
            name: "Sottovoce",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Sottovoce",
            swiftSettings: [.swiftLanguageMode(.v5)],
            // build.sh puts Sparkle.framework in Contents/Frameworks
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        )
    ]
)
