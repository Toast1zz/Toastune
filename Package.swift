// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Toastune",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Toastune", targets: ["Toastune"])],
    targets: [
        .executableTarget(name: "Toastune", exclude: ["Resources"], linkerSettings: [.linkedFramework("OSAKit")]),
        .testTarget(name: "ToastuneTests", dependencies: ["Toastune"])
    ]
)
