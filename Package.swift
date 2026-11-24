// swift-tools-version:5.9
import Foundation
import PackageDescription

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "kbdance",
    // Core Audio process taps (system-audio capture) need macOS 14.2.
    platforms: [.macOS("14.2")],
    targets: [
        // Backlight control, audio capture and analysis, and the animation engine.
        .target(name: "KBDanceCore"),

        // Command-line tool.
        .executableTarget(
            name: "kbdance",
            dependencies: ["KBDanceCore"],
            linkerSettings: [
                // Embeds an Info.plist so macOS privacy dialogs can name kbdance and show why it needs audio.
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                              "-Xlinker", "\(root)/Resources/CLI-Info.plist"]),
            ]
        ),

        // Menu bar app. build-app.sh packages it as KeyboardDance.app.
        .executableTarget(name: "KeyboardDance", dependencies: ["KBDanceCore"]),

        .testTarget(name: "KBDanceCoreTests", dependencies: ["KBDanceCore"]),
    ]
)
