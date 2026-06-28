// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ClipboardHistoryHUD",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "clipboard-history-hud",
            targets: ["ClipboardHistoryHUD"]
        )
    ],
    targets: [
        .executableTarget(
            name: "ClipboardHistoryHUD",
            path: "Sources/ClipboardHistoryHUD",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
