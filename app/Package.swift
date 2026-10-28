// swift-tools-version:6.0
// Sottovoce: hold a hotkey and speak; on release the audio is transcribed by the Sottovoce server and pasted
// into the focused text field.
import PackageDescription

let package = Package(
    name: "Sottovoce",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Sottovoce",
            path: "Sources/Sottovoce",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
