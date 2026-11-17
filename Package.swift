// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "herd-db",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "herd-db", targets: ["HerdDB"]),
        .library(name: "HerdCore", targets: ["HerdCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
        .package(path: "Vendor/CosmoSQLClient"),
    ],
    targets: [
        .target(
            name: "HerdCore",
            dependencies: [
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "CosmoMSSQL", package: "CosmoSQLClient"),
                .product(name: "CosmoSQLCore", package: "CosmoSQLClient"),
            ]
        ),
        .executableTarget(
            name: "HerdDB",
            dependencies: ["HerdCore"]
        ),
        .testTarget(
            name: "HerdCoreTests",
            dependencies: ["HerdCore"]
        ),
    ]
)
