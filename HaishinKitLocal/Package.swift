// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HaishinKit",
    platforms: [
        .iOS(.v15),
        .tvOS(.v15),
        .macCatalyst(.v15),
        .macOS(.v12),
        .visionOS(.v1)
    ],
    products: [
        .library(name: "HaishinKit", targets: ["HaishinKit"]),
        .library(name: "SRTHaishinKit", targets: ["SRTHaishinKit"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "Logboard",
            path: "LogboardStub/Sources/Logboard"
        ),
        .binaryTarget(
            name: "libsrt",
            url: "https://github.com/HaishinKit/libsrt-xcframework/releases/download/v1.5.4/libsrt.xcframework.zip",
            checksum: "76879e2802e45ce043f52871a0a6764d57f833bdb729f2ba6663f4e31d658c4a"
        ),
        .target(
            name: "HaishinKit",
            dependencies: ["Logboard"],
            path: "HaishinKit/Sources"
        ),
        .target(
            name: "SRTHaishinKit",
            dependencies: ["libsrt", "HaishinKit"],
            path: "SRTHaishinKit/Sources"
        )
    ]
)
