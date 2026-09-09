// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "SenseVoiceValidation", platforms: [.macOS(.v13)],
    dependencies: [.package(url: "https://github.com/k2-fsa/sherpa-onnx.git", exact: "1.13.7")],
    targets: [.executableTarget(name: "SenseVoiceValidation", dependencies: [.product(name: "sherpa-onnx", package: "sherpa-onnx")], path: "Sources")])
