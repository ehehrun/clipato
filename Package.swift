// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Clipato",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Clipato", targets: ["Clipato"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(
            name: "CWebP",
            path: "Vendor/libwebp",
            exclude: ["COPYING", "PATENTS", "AUTHORS", "README.clipato.md"],
            sources: ["src/enc", "src/dsp", "src/utils", "sharpyuv"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("."), .define("WEBP_USE_THREAD")]
        ),
        .target(
            name: "ClipatoCore",
            dependencies: ["CWebP"],
            swiftSettings: [.unsafeFlags(["-Xfrontend", "-disable-reflection-names"], .when(configuration: .release))]
        ),
        .executableTarget(name: "Clipato", dependencies: ["ClipatoCore", "CSQLite"], resources: [.process("Resources"), .copy("Skills")]),
        .testTarget(name: "ClipatoCoreTests", dependencies: ["ClipatoCore"]),
        .testTarget(name: "ClipatoTests", dependencies: ["Clipato", "CSQLite"])
    ],
    swiftLanguageModes: [.v5]
)
