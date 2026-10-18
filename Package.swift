// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DevCleaner",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "DevCleaner", targets: ["DevCleaner"])
    ],
    targets: [
        .executableTarget(
            name: "DevCleaner",
            path: "Sources/DevCleaner",
            exclude: ["Resources"]
        ),
        .testTarget(
            name: "DevCleanerTests",
            dependencies: ["DevCleaner"],
            path: "Tests/DevCleanerTests"
        )
    ]
)
