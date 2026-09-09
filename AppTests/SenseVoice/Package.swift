// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "SenseVoiceValidation", platforms: [.macOS(.v13)],
    targets: [.executableTarget(name: "SenseVoiceValidation", path: "Sources")])
