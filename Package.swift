// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "IconBuilder",
    platforms: [.macOS(.v14)],
    targets: [
        // Core: parsing, rendering, CMYK PDF export. No dependencies.
        .target(
            name: "IconBuilderCore"
        ),
        // The SwiftUI app.
        .executableTarget(
            name: "IconBuilder",
            dependencies: ["IconBuilderCore"]
        ),
        // Headless render harness used to validate compositing math.
        .executableTarget(
            name: "rendertool",
            dependencies: ["IconBuilderCore"]
        ),
        .testTarget(
            name: "IconBuilderCoreTests",
            dependencies: ["IconBuilderCore"]
        ),
    ]
)
