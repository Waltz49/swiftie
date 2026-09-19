// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Prowser",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Prowser", targets: ["Prowser"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ainame/Swift-WebP.git", from: "0.5.0"),
        .package(url: "https://github.com/SDWebImage/libwebp-Xcode.git", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "Prowser",
            dependencies: [
                .product(name: "WebP", package: "Swift-WebP"),
                .product(name: "libwebp", package: "libwebp-Xcode"),
            ],
            path: "Prowser",
            exclude: ["Resources/Info.plist", "Resources/Prowser.entitlements"],
            resources: [
                .process("Resources/Assets"),
                .process("Resources/image_recognition_models.json"),
                .process("Resources/waltzremote_search_models.cer"),
            ],
            linkerSettings: [
                .linkedFramework("Photos"),
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Prowser/Resources/Info.plist",
                ]),
            ]
        ),
        .testTarget(
            name: "ProwserTests",
            dependencies: ["Prowser"],
            path: "ProwserTests"
        ),
    ]
)
