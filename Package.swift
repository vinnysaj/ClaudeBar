// swift-tools-version: 6.0
import PackageDescription

// The Xcode project builds the release Mac app and its bundled `claudebar` from
// the ClaudeBarCore and ClaudeBarCLI products here; `swift build` is the dev loop
// on macOS and the only build on Linux.
let package = Package(
    name: "ClaudeBar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClaudeBarCore", targets: ["ClaudeBarCore"]),
        .library(name: "ClaudeBarCLI", targets: ["ClaudeBarCLI"]),
        .executable(name: "claudebar", targets: ["claudebar"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.0"),
        .package(url: "https://github.com/apple/swift-crypto", from: "5.0.0"),
        .package(url: "https://github.com/apple/swift-nio", from: "2.104.0"),
    ],
    targets: [
        .target(
            name: "ClaudeBarCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .target(
            name: "ClaudeBarCLI",
            dependencies: [
                "ClaudeBarCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(name: "claudebar", dependencies: ["ClaudeBarCLI"]),
        .testTarget(
            name: "ClaudeBarTests",
            dependencies: [
                "ClaudeBarCore",
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Tests/ClaudeBarTests"
        ),
    ]
)

#if os(macOS)
// Named apart from `claudebar`: on a case-insensitive disk the two binaries
// would overwrite each other in .build.
package.targets.append(
    .executableTarget(
        name: "ClaudeBarApp",
        dependencies: ["ClaudeBarCore"],
        exclude: ["Info.plist", "ClaudeBar.entitlements"],
        linkerSettings: [.linkedFramework("AppKit")]
    ))
#elseif os(Linux)
package.products.append(.executable(name: "claudebar-tray", targets: ["claudebar-tray"]))
package.targets += [
    .systemLibrary(
        name: "CAppIndicator",
        pkgConfig: "ayatana-appindicator3-0.1",
        providers: [.apt(["libayatana-appindicator3-dev"])]
    ),
    .executableTarget(name: "claudebar-tray", dependencies: ["ClaudeBarCore", "CAppIndicator"]),
]
#endif
