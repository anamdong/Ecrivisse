// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Ecrivisse",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Ecrivisse", targets: ["Ecrivisse"])
    ],
    targets: [
        .executableTarget(
            name: "Ecrivisse",
            path: "Sources/Ecrivisse"
        )
    ]
)
