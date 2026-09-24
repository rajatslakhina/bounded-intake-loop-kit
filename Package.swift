// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BoundedIntakeLoop",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "BoundedIntakeLoop", targets: ["BoundedIntakeLoop"])
    ],
    targets: [
        .target(
            name: "BoundedIntakeLoop",
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .testTarget(
            name: "BoundedIntakeLoopTests",
            dependencies: ["BoundedIntakeLoop"]
        )
    ]
)
