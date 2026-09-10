// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Prowser",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Prowser", targets: ["Prowser"]),
    ],
    targets: [
        .executableTarget(
            name: "Prowser",
            path: "Prowser",
            exclude: ["Resources/Info.plist"],
            resources: [
                .process("Resources/Assets"),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Prowser/Resources/Info.plist",
                ]),
            ]
        ),
    ]
)
