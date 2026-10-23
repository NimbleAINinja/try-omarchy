// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OmarchyVMHelper",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "omarchy-vm-helper", targets: ["OmarchyVMHelper"]),
        .library(name: "TryOmarchyKitClient", targets: ["TryOmarchyKitClient"]),
    ],
    targets: [
        .target(name: "TryOmarchyKitClient", swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(name: "OmarchyVMHelper", dependencies: ["TryOmarchyKitClient"]),
        .testTarget(name: "OmarchyVMHelperTests", dependencies: ["OmarchyVMHelper", "TryOmarchyKitClient"]),
    ],
    swiftLanguageModes: [.v5]
)
