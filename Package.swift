// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "VeriCopy",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "VeriCopyCore"),
        .executableTarget(
            name: "VeriCopy",
            dependencies: ["VeriCopyCore"]
        ),
        .executableTarget(
            name: "vericopy-selftest",
            dependencies: ["VeriCopyCore"]
        ),
    ]
)
