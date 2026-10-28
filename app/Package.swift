// swift-tools-version: 6.2
// The Splash Mac app: a window and a menu bar item around `splash serve`.
// `make app` builds it and assembles Splash.app around the packaged runtime.

import PackageDescription

let package = Package(
    name: "Splash",
    platforms: [.macOS("26.4")],
    targets: [
        // The Chat's transcript is a web page, in Transcript/.
        .executableTarget(name: "Splash", path: "Sources/Splash", resources: [.copy("Transcript")]),
        .testTarget(name: "SplashTests", dependencies: ["Splash"], path: "Tests/SplashTests"),
    ]
)
