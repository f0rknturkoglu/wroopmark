// swift-tools-version:5.10
import PackageDescription

// The Rust core is linked as a static library (core/, `cargo build
// --release`). scripts/build-mac.sh passes its directory with -L.
let package = Package(
    name: "Wroopmark",
    platforms: [.macOS(.v14)],
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
    ]
)
