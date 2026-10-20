// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ContainerStack",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Pinned to the exact release matching the installed container-apiserver.
        // Client and daemon ship in lockstep; do not use `from:` here.
        // Move with scripts/bump-container.sh: it keeps containerization at the
        // version apple/container requires, and PlatformInstaller.pinnedVersion in step.
        .package(url: "https://github.com/apple/container.git", exact: "1.3.1"),
        .package(url: "https://github.com/apple/containerization.git", exact: "0.42.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.1"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        // Matches Don't Miss: one updater mechanism across both apps.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "ContainerStack",
            dependencies: [
                .product(name: "ContainerAPIClient", package: "container"),
                .product(name: "ContainerResource", package: "container"),
                .product(name: "ContainerPersistence", package: "container"),
                .product(name: "ContainerPlugin", package: "container"),
                .product(name: "TerminalProgress", package: "container"),
                .product(name: "ContainerizationExtras", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Yams", package: "Yams"),
                .product(name: "ContainerBuild", package: "container"),
                .product(name: "ContainerCommands", package: "container"),
                .product(name: "ContainerImagesService", package: "container"),
                .product(name: "MachineAPIClient", package: "container"),
                .product(name: "NIO", package: "swift-nio"),
            ],
            path: "Sources/ContainerStack",
            swiftSettings: [.swiftLanguageMode(.v5)],
            // Sparkle ships as a framework inside Contents/Frameworks, and
            // SwiftPM does not add a loader path for it: without this the app
            // builds and signs fine, then dies at launch with "Library not
            // loaded: @rpath/Sparkle.framework". Same setting Don't Miss uses.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        )
    ]
)
