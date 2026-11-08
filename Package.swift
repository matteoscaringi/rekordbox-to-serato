// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RekordboxToSerato",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "RekordboxToSerato", targets: ["RekordboxToSerato"]),
    ],
    targets: [
        .target(name: "SyncCore"),
        .executableTarget(name: "RekordboxToSerato", dependencies: ["SyncCore"]),
        .executableTarget(name: "SyncSelfTest", dependencies: ["SyncCore"]),
    ]
)
