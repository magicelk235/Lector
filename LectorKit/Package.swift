// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LectorKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LectorKit", targets: ["LectorKit"])
    ],
    targets: [
        .target(
            name: "LectorKit",
            dependencies: ["CTesseract", "COnnxRuntime"],
            // Tesseract models for the scripts Vision cannot read; built and pinned by
            // Scripts/build-tesseract.sh.
            resources: [.copy("Resources/tessdata")]
        ),
        // Static Leptonica + Tesseract, arm64 and x86_64, linked against nothing but
        // the SDK. Rebuild with Scripts/build-tesseract.sh.
        .binaryTarget(name: "CTesseract", path: "../Vendor/Tesseract.xcframework"),
        // ONNX Runtime 1.24.2 (MIT), Microsoft's own static build: arm64 and x86_64, no
        // dylibs, only system frameworks. Runs the offline Opus-MT translation models.
        .binaryTarget(
            name: "onnxruntime",
            url: "https://download.onnxruntime.ai/pod-archive-onnxruntime-c-1.24.2.zip",
            checksum: "f7100a992d2a8135168c8afd831e6a58b465349101982aa58b3e11d36e600b54"
        ),
        .target(name: "COnnxRuntime", dependencies: ["onnxruntime"], linkerSettings: [.linkedLibrary("c++")]),
        .testTarget(
            name: "LectorKitTests",
            dependencies: ["LectorKit"],
            resources: [.copy("Fixtures")]
        )
    ]
)
