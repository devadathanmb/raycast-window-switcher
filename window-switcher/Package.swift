// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WindowSwitcher",
    platforms: [
        .macOS(.v10_15)
    ],
    products: [
        .executable(
            name: "window-switcher",
            targets: ["WindowSwitcher"]
        )
    ],
    targets: [
        .executableTarget(
            name: "WindowSwitcher",
            path: "Sources/WindowSwitcher"
        )
    ]
)
