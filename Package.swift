// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "EdgeDragPrototype",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "EdgeDragPrototype", targets: ["EdgeDragPrototype"]),
    ],
    targets: [
        .executableTarget(
            name: "EdgeDragPrototype",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
    ]
)
