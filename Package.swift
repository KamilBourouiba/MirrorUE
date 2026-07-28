// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MirrorUE",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MirrorUE", targets: ["MirrorUEApp"]),
    ],
    targets: [
        .target(
            name: "DeviceKit",
            path: "Sources/DeviceKit"
        ),
        .target(
            name: "MediaKit",
            path: "Sources/MediaKit",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMediaIO"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Metal"),
            ]
        ),
        .target(
            name: "ControlKit",
            path: "Sources/ControlKit",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("AppKit"),
            ]
        ),
        .executableTarget(
            name: "MirrorUEApp",
            dependencies: ["DeviceKit", "MediaKit", "ControlKit"],
            path: "Sources/MirrorUEApp",
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("AVFoundation"),
            ]
        ),
    ]
)
