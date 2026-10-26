// swift-tools-version: 6.4

import PackageDescription

// 远程 SPM 只认仓库根上的清单。源码仍留在子目录包，product 与 import 名不变。
// 依赖版本、语言模式和 defaultIsolation 必须与 packages/SVGAPlayer-swift/Package.swift 一致。
let package = Package(
    name: "SVGAPlayer-swift",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(
            name: "SVGAPlayer-swift",
            targets: ["SVGAPlayer_swift"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.39.0"),
    ],
    targets: [
        .target(
            name: "SVGAPlayer_swift",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "packages/SVGAPlayer-swift/Sources/SVGAPlayer_swift",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
                // 库默认 nonisolated；不要继承调用方或 demo 的 MainActor 隔离。
                .defaultIsolation(nil),
            ]
        ),
        .testTarget(
            name: "SVGAPlayer_swiftTests",
            dependencies: ["SVGAPlayer_swift"],
            path: "packages/SVGAPlayer-swift/Tests/SVGAPlayer_swiftTests",
            resources: [
                .copy("Fixtures"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
                .defaultIsolation(nil),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
