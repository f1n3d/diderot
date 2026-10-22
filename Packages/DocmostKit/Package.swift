// swift-tools-version: 6.2
import PackageDescription

// Platform-neutral app core: API client, models, content format, auth.
// No default MainActor isolation, so networking and decoding run in the `APIClient` actor.
let package = Package(
    name: "DocmostKit",
    platforms: [.iOS("27.0"), .macOS("26.0")],
    products: [
        .library(name: "DocmostKit", targets: ["DocmostKit"])
    ],
    targets: [
        .target(name: "DocmostKit"),
        .testTarget(
            name: "DocmostKitTests",
            dependencies: ["DocmostKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
