// swift-tools-version: 5.10
import PackageDescription
import AppleProductTypes

let package = Package(
    name: "LectureTranscriber",
    platforms: [.iOS("16.0")],
    products: [
        .iOSApplication(
            name: "課堂逐字稿",
            targets: ["AppModule"],
            bundleIdentifier: "com.peijungwu0302.lecturetranscriber",
            displayVersion: "1.6.0",
            bundleVersion: "11",
            appIcon: .asset("AppIcon"),
            supportedDeviceFamilies: [.pad, .phone],
            supportedInterfaceOrientations: [.portrait, .landscapeLeft, .landscapeRight],
            capabilities: [.microphone(purposeString: "錄製課堂聲音，在這台裝置上產生逐字稿。")]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/peijungwu0302-Wu/argmax-oss-swift-playground.git", exact: "1.1.4")
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            dependencies: [.product(name: "WhisperKit", package: "argmax-oss-swift-playground"),
                           .product(name: "SpeakerKit", package: "argmax-oss-swift-playground")],
            path: "Sources",
            resources: [.process("Assets.xcassets"), .copy("THIRD-PARTY-NOTICES.txt")]
        )
    ],
    swiftLanguageVersions: [.v5]
)
