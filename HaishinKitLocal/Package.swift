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
        .library(name: "RTMPHaishinKit", targets: ["RTMPHaishinKit"]),
        .library(name: "SRTHaishinKit", targets: ["SRTHaishinKit"]),
        .library(name: "MoQTHaishinKit", targets: ["MoQTHaishinKit"]),
        .library(name: "RTCHaishinKit", targets: ["RTCHaishinKit"])
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
        .binaryTarget(
            name: "libdatachannel",
            url: "https://github.com/HaishinKit/libdatachannel-xcframework/releases/download/v0.24.0/libdatachannel.xcframework.zip",
            checksum: "52163eed2c9d652d913b20d1fd5a1925c5982b1dcdf335fd916c72ffa385bb26"
        ),
        .target(
            name: "HaishinKit",
            dependencies: ["Logboard"],
            path: "HaishinKit/Sources"
        ),
        .target(
            name: "RTMPHaishinKit",
            dependencies: ["HaishinKit"],
            path: "RTMPHaishinKit/Sources"
        ),
        .target(
            name: "SRTHaishinKit",
            dependencies: ["libsrt", "HaishinKit"],
            path: "SRTHaishinKit/Sources"
        ),
        .target(
            name: "MoQTHaishinKit",
            dependencies: ["HaishinKit"],
            path: "MoQTHaishinKit/Sources"
        ),
        .target(
            name: "RTCHaishinKit",
            dependencies: ["libdatachannel", "HaishinKit"],
            path: "RTCHaishinKit/Sources"
        )
    ]
)
