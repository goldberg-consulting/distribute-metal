// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DistributeMetal",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "DistributeMetal", targets: ["DistributeMetal"])
    ],
    targets: [
        .executableTarget(
            name: "DistributeMetal",
            path: ".",
            exclude: [
                "Package.swift",
                "Info.plist"
            ],
            sources: [
                "App",
                "Views",
                "ViewModels",
                "Models",
                "Services",
                "Utilities"
            ],
            resources: [],
            swiftSettings: [
                .define("DEBUG", .when(configuration: .debug))
            ]
        )
    ]
)
