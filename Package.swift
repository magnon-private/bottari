// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Bottari",
    platforms: [.macOS(.v12)],
    targets: [
        // macOS 에 내장된 libarchive 의 최소 선언부 (SDK 에 헤더가 없어 직접 선언)
        .target(name: "CArchive", path: "Sources/CArchive"),
        .target(
            name: "BottariCore",
            dependencies: ["CArchive"],
            path: "Sources/BottariCore",
            linkerSettings: [.linkedLibrary("archive")]
        ),
        .executableTarget(name: "Bottari", dependencies: ["BottariCore"], path: "Sources/Bottari"),
        .executableTarget(name: "bottaricli", dependencies: ["BottariCore"], path: "Sources/bottaricli"),
    ],
    swiftLanguageVersions: [.v5]
)
