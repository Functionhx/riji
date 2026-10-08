// swift-tools-version: 6.0
import PackageDescription

// 日迹的共享代码：RijiKit 是纯逻辑内核（模型、同步协议、存储、每日规则），
// RijiUI 是三个苹果平台共用的 SwiftUI 界面（纸与墨）。应用工程（apple/Riji）只是薄壳。
let package = Package(
    name: "RijiKit",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        .library(name: "RijiKit", targets: ["RijiKit"]),
        .library(name: "RijiUI", targets: ["RijiUI"]),
    ],
    targets: [
        .target(name: "RijiKit"),
        .target(name: "RijiUI", dependencies: ["RijiKit"]),
        .testTarget(name: "RijiKitTests", dependencies: ["RijiKit"]),
        .testTarget(name: "RijiUITests", dependencies: ["RijiUI", "RijiKit"]),
    ]
)
