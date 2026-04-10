// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VideoDownloader",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VideoDownloader", targets: ["VideoDownloader"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "VideoDownloader",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/VideoDownloader"
        )
    ]
)
