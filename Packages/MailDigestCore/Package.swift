// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MailDigestCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MailDigestCore", targets: ["MailDigestCore"]),
    ],
    dependencies: [
        // Q99: the only non-Foundation dependency; pinned exactly because it parses untrusted mail HTML.
        .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.14.4"),
    ],
    targets: [
        .target(name: "MailDigestCore", dependencies: [.product(name: "SwiftSoup", package: "SwiftSoup")]),
        .executableTarget(name: "EvalCLI", dependencies: ["MailDigestCore"]),
        .testTarget(
            name: "MailDigestCoreTests",
            dependencies: ["MailDigestCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
