// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "swift-smtp",
    platforms: [
        // macOS 13 / iOS 16 are the floor for `Duration` and `Clock`.
        // Linux is unaffected by this declaration.
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "MIME", targets: ["MIME"]),
        .library(name: "SMTP", targets: ["SMTP"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.29.0"),
    ],
    targets: [
        // Message building only: no dependency at all.
        .target(name: "MIME"),
        .target(
            name: "SMTP",
            dependencies: [
                "MIME",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ]
        ),
        .testTarget(
            name: "MIMETests",
            dependencies: ["MIME"]
        ),
        .testTarget(
            name: "SMTPTests",
            dependencies: [
                "SMTP",
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .executableTarget(
            name: "SMTPDemo",
            dependencies: [
                "SMTP",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Demo/SMTPDemo"
        ),
    ],
    swiftLanguageModes: [.v6]
)
