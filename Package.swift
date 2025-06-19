// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SnapOrthoBackend",
    platforms: [
       .macOS(.v13)
    ],
    dependencies: [
        // 💧 A server-side Swift web framework.
        .package(url: "https://github.com/vapor/vapor.git", from: "4.115.0"),
        // 🗄 An ORM for SQL and NoSQL databases.
        .package(url: "https://github.com/vapor/fluent.git", from: "4.9.0"),
        // 🐘 Fluent driver for Postgres.
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.8.0"),
        // 🔵 Non-blocking, event-driven networking for Swift. Used for custom executors.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(
                    url: "https://github.com/supabase/supabase-swift.git",
                    from: "2.0.0"
                ),
        .package(url: "https://github.com/vapor/apns.git",   from: "4.2.0")


        


    ],
    targets: [
        .executableTarget(
            name: "SnapOrthoBackend",
            dependencies: [
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Supabase", package: "supabase-swift"),
                .product(name: "VaporAPNS", package: "apns")


            ],
            resources: [
                            .copy("Public")
                        ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "SnapOrthoBackendTests",
            dependencies: [
                .target(name: "SnapOrthoBackend"),
                .product(name: "VaporTesting", package: "vapor"),
            ],
            swiftSettings: swiftSettings
        )
    ]
)

var swiftSettings: [SwiftSetting] { [
    .enableUpcomingFeature("ExistentialAny"),
] }
