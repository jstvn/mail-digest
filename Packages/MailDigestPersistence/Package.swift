// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MailDigestPersistence",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MailDigestPersistence", targets: ["MailDigestPersistence"]),
    ],
    dependencies: [
        .package(path: "../MailDigestCore"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.9.0"),
    ],
    targets: [
        .target(
            name: "MailDigestPersistence",
            dependencies: [
                .product(name: "MailDigestCore", package: "MailDigestCore"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "MailDigestPersistenceTests",
            dependencies: ["MailDigestPersistence"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
