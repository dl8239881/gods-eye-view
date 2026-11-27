// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "IntelKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "IntelKit", targets: ["IntelKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.12.0"),
    ],
    targets: [
        .target(
            name: "IntelKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "IntelKitTests",
            dependencies: ["IntelKit"],
            exclude: ["Fixtures"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
