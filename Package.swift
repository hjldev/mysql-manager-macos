// swift-tools-version: 6.2
// Native macOS MySQL client. `./build.sh` builds the .app bundle.
import PackageDescription

let package = Package(
    name: "MySQLManagerNative",
    platforms: [.macOS(.v14)],
    targets: [
        // MySQL wire protocol client and the database operations the app uses
        .target(name: "MySQLKit", path: "Sources/MySQLKit"),
        .executableTarget(
            name: "MySQLManagerNative",
            dependencies: ["MySQLKit"],
            path: "Sources/App",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "MySQLKitTests", dependencies: ["MySQLKit"], path: "Tests/MySQLKitTests"),
    ]
)
