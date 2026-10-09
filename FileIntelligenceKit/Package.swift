// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FileIntelligenceKit",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "FileIntelligenceKit", targets: ["FileIntelligenceKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", .upToNextMajor(from: "6.29.0")),
    ],
    targets: [
        .target(
            name: "FileIntelligenceKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "FileIntelligenceKitTests",
            dependencies: [
                "FileIntelligenceKit",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
    ]
)
