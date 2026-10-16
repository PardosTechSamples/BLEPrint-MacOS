// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BLEPrint",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "CLzma", path: "Sources/CLzma"),
        .target(name: "BLEPrintCore", dependencies: ["CLzma"], path: "Sources/BLEPrintCore"),
        .executableTarget(name: "BLEPrint", dependencies: ["BLEPrintCore"], path: "Sources/BLEPrint"),
        .executableTarget(name: "bleprint-selftest", dependencies: ["BLEPrintCore"], path: "Sources/SelfTest"),
    ]
)
