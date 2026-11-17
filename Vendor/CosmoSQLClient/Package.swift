// swift-tools-version: 5.9
import PackageDescription

// Cópia local do CosmoSQLClient-Swift 1.6.4 (MIT), reduzida aos módulos
// CosmoSQLCore e CosmoMSSQL. O patch em MSSQLConnection.sendPacket usa
// pacotes TDS de 4 KiB, que todo SQL Server aceita.
let package = Package(
    name: "CosmoSQLClient",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "CosmoSQLCore", targets: ["CosmoSQLCore"]),
        .library(name: "CosmoMSSQL", targets: ["CosmoMSSQL"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.25.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.3"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .target(
            name: "CosmoSQLCore",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "CosmoMSSQL",
            dependencies: [
                .target(name: "CosmoSQLCore"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOTLS", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: swiftSettings
        ),
    ]
)

var swiftSettings: [SwiftSetting] { [] }
