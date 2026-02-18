// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "MinuteWave",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MinuteWave", targets: ["AINoteTakerApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.1"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.8.0")
    ],
    targets: [
        .executableTarget(
            name: "AINoteTakerApp",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/AINoteTakerApp",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Security"),
                .linkedLibrary("sqlcipher"),
                .unsafeFlags(
                    [
                        "-Xlinker", "-rpath",
                        "-Xlinker", "@executable_path/../Frameworks",
                        "-Xlinker", "-rpath",
                        "-Xlinker", "/opt/homebrew/lib",
                        "-Xlinker", "-rpath",
                        "-Xlinker", "/usr/local/lib",
                        "-L", "/opt/homebrew/lib",
                        "-L", "/usr/local/lib",
                        "-Xlinker", "-sectcreate",
                        "-Xlinker", "__TEXT",
                        "-Xlinker", "__info_plist",
                        "-Xlinker", "Sources/AINoteTakerApp/Resources/AppInfo.plist"
                    ],
                    .when(platforms: [.macOS])
                )
            ]
        ),
        .testTarget(
            name: "AINoteTakerAppTests",
            dependencies: ["AINoteTakerApp"],
            path: "Tests/AINoteTakerAppTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
