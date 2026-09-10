// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClipName",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClipName", targets: ["EchoRename"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "EchoRename",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            resources: [.copy("Resources")]
        ),
        .testTarget(name: "EchoRenameTests", dependencies: ["EchoRename"]),
    ]
)
