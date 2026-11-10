// swift-tools-version: 6.0
import PackageDescription

// The Rust core is linked as a static library (core/, `cargo build
// --release`). scripts/build-mac.sh passes its directory with -L.
let package = Package(
    name: "Wroopmark",
    platforms: [.macOS("26.0")],
    targets: [
        .systemLibrary(name: "CWroopmark", path: "Sources/CWroopmark"),
        .executableTarget(
            name: "Wroopmark",
            dependencies: ["CWroopmark"],
            path: "Sources/Wroopmark",
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .testTarget(
            name: "WroopmarkTests",
            dependencies: ["Wroopmark"],
            path: "Tests/WroopmarkTests",
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
    ]
)
