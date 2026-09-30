// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HoverLensKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HoverLensKit", targets: ["HoverLensKit"])
    ],
    targets: [
        .target(
            name: "HoverLensKit",
            dependencies: ["CTesseract"],
            // Tesseract models for the scripts Vision cannot read; built and pinned by
            // Scripts/build-tesseract.sh.
            resources: [.copy("Resources/tessdata")]
        ),
        // Static Leptonica + Tesseract, arm64 and x86_64, linked against nothing but
        // the SDK. Rebuild with Scripts/build-tesseract.sh.
        .binaryTarget(name: "CTesseract", path: "../Vendor/Tesseract.xcframework"),
        .testTarget(
            name: "HoverLensKitTests",
            dependencies: ["HoverLensKit"],
            resources: [.copy("Fixtures")]
        )
    ]
)
