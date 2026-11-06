// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TunerX",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "TXCore", path: "Sources/TXCore"),
        .executableTarget(
            name: "TunerX",
            dependencies: ["TXCore"],
            path: "Sources/TunerX",
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Accelerate"),
                .linkedFramework("AVFoundation"),
            ]
        ),
    ]
)
