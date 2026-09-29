// swift-tools-version: 5.9
import Foundation
import PackageDescription

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let dlibInstallLib = packageDir.appendingPathComponent("Vendor/dlib-install/lib/libdlib.a")
let dlibInstallInclude = packageDir.appendingPathComponent("Vendor/dlib-install/include")
let hasVendorDlib = FileManager.default.fileExists(atPath: dlibInstallLib.path)

var dlibBridgeCXX: [CXXSetting] = [
    .headerSearchPath("include"),
    // dlib requires C++14+; SPM C++ targets default to an older dialect without this flag.
    .unsafeFlags(["-std=c++17"], .when(platforms: [.macOS])),
    // Vendor libdlib.a is always CMake Release; compile bridge + header templates the same way in debug.
    .unsafeFlags(["-O3", "-DNDEBUG"], .when(platforms: [.macOS], configuration: .debug)),
]
var dlibBridgeLinker: [LinkerSetting] = []
if hasVendorDlib {
    dlibBridgeCXX.append(.headerSearchPath("../Vendor/dlib-install/include", .when(platforms: [.macOS])))
    dlibBridgeLinker = [
        .linkedFramework("Accelerate"),
        .unsafeFlags([
            dlibInstallLib.path,
        ], .when(platforms: [.macOS])),
    ]
}

let packageTargets: [Target] = [
    .target(
        name: "ProwserDlibBridgeCore",
        path: "ProwserDlibBridgeCore",
        publicHeadersPath: "include",
        cxxSettings: dlibBridgeCXX,
        linkerSettings: dlibBridgeLinker
    ),
    .target(
        name: "ProwserDlibBridge",
        dependencies: ["ProwserDlibBridgeCore"],
        path: "ProwserDlibBridge"
    ),
    .executableTarget(
        name: "Prowser",
        dependencies: [
            "ProwserDlibBridge",
            .product(name: "WebP", package: "Swift-WebP"),
            .product(name: "libwebp", package: "libwebp-Xcode"),
        ],
        path: "Prowser",
        exclude: ["Resources/Info.plist", "Resources/Prowser.entitlements"],
        resources: [
            .process("Resources/Assets"),
            .process("Resources/image_recognition_models.json"),
            .process("Resources/dlib_face_models.json"),
            .process("Resources/waltzremote_search_models.cer"),
        ],
        linkerSettings: [
            .linkedFramework("Photos"),
            .linkedFramework("Accelerate"),
            .unsafeFlags([
                "-Xlinker", "-sectcreate",
                "-Xlinker", "__TEXT",
                "-Xlinker", "__info_plist",
                "-Xlinker", "Prowser/Resources/Info.plist",
            ]),
        ]
    ),
    .executableTarget(
        name: "FaceDetectBench",
        dependencies: ["ProwserDlibBridge"],
        path: "Tools/FaceDetectBench",
        linkerSettings: [
            .linkedFramework("Accelerate"),
        ]
    ),
]

let package = Package(
    name: "Prowser",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Prowser", targets: ["Prowser"]),
        .executable(name: "FaceDetectBench", targets: ["FaceDetectBench"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ainame/Swift-WebP.git", from: "0.5.0"),
        .package(url: "https://github.com/SDWebImage/libwebp-Xcode.git", from: "1.5.0"),
    ],
    targets: packageTargets
)
