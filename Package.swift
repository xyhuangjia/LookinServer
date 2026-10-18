// swift-tools-version:5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "LookinServer",
    platforms: [
        // 与 podspec 对齐（iOS/tvOS 15.6、macOS 14.0）；SPM 平台版本只支持 major 粒度，故取 15/14
        .iOS(.v15), .tvOS(.v15), .macOS(.v14)
    ],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "LookinServer",
            targets: ["LookinServer"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        // .package(url: /* package url */, from: "1.0.0"),
        .package(url: "https://github.com/robbiehanson/CocoaAsyncSocket", from: "7.0.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "LookinServer",
            dependencies: [
                .target(name: "LookinServerSwift"),
                .product(name: "CocoaAsyncSocket", package: "CocoaAsyncSocket"),
            ],
            path: "Src/Main",
            publicHeadersPath: "",
            cSettings: [
                .headerSearchPath("**"),
                .headerSearchPath("Server"),
                .headerSearchPath("Server/Category"),
                .headerSearchPath("Server/Connection"),
                .headerSearchPath("Server/Connection/RequestHandler"),
                .headerSearchPath("Server/HTTP"),
                .headerSearchPath("Server/Inspect"),
                .headerSearchPath("Server/Others"),
                .headerSearchPath("Server/Perspective"),
                .headerSearchPath("Shared"),
                .headerSearchPath("Shared/Category"),
                .headerSearchPath("Shared/Message"),
                .headerSearchPath("Shared/Peertalk"),
                .headerSearchPath("Shared/Channel"),
                .headerSearchPath("Shared/Channel/Bonjour"),
            ],
            cxxSettings: [
                .define("SHOULD_COMPILE_LOOKIN_SERVER", to: "1", .when(configuration: .debug)),
                .define("SPM_LOOKIN_SERVER_ENABLED", to: "1", .when(configuration: .debug)),
                // 与 LookinShared.podspec 的 Wireless 子规格保持一致：macOS（Lookin 客户端）也需要
                // 链接 Channel 符号，平台差异由源码内部守卫处理
                .define("LOOKIN_SERVER_WIRELESS", to: "1"),
            ]
        ),
        .target(
            name: "LookinServerSwift",
            dependencies: [.target(name: "LookinServerBase")],
            path: "Src/Swift",
            cxxSettings: [
                .define("SHOULD_COMPILE_LOOKIN_SERVER", to: "1", .when(configuration: .debug)),
                .define("SPM_LOOKIN_SERVER_ENABLED", to: "1", .when(configuration: .debug))
            ],
            swiftSettings: [
                .define("SHOULD_COMPILE_LOOKIN_SERVER", .when(configuration: .debug)),
                .define("SPM_LOOKIN_SERVER_ENABLED", .when(configuration: .debug))
            ]
        ),
        .target(
            name: "LookinServerBase",
            dependencies: [],
            path: "Src/Base",
            publicHeadersPath: "",
            cxxSettings: [
                .define("SHOULD_COMPILE_LOOKIN_SERVER", to: "1", .when(configuration: .debug))
            ]
        )
    ]
)
