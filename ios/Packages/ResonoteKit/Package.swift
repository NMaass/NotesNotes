// swift-tools-version: 6.2
import PackageDescription

// Shared core for the Resonote app, widget extension, and share extension.
// macOS is declared only so `swift test` runs on a Mac without the iOS simulator.
let package = Package(
    name: "ResonoteKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "ResonoteKit", targets: ["ResonoteKit"]),
    ],
    targets: [
        .target(
            name: "ResonoteKit",
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ]
        ),
        .testTarget(
            name: "ResonoteKitTests",
            dependencies: ["ResonoteKit"]
        ),
    ]
)
