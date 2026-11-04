// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MailDigestCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MailDigestCore", targets: ["MailDigestCore"]),
    ],
    targets: [
        .target(name: "MailDigestCore"),
        .executableTarget(name: "EvalCLI", dependencies: ["MailDigestCore"]),
        .testTarget(
            name: "MailDigestCoreTests",
            dependencies: ["MailDigestCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
