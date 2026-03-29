// swift-tools-version: 5.9
// Lossly – Modern SwiftUI rewrite
//
// HOW TO USE
// ----------
// 1. In Xcode: File → Open… → select this Package.swift
//    Xcode will configure the project automatically.
//
// 2. REQUIRED: Add the CLI tool binaries to the app bundle.
//    In Xcode, select the "Lossly" target → Build Phases → Copy Files.
//    Set Destination to "Executables" and add:
//       • pngquant   (brew install pngquant  →  /opt/homebrew/bin/pngquant)
//       • posterizer (build from mediancut-posterizer submodule, or download)
//
// 3. Code Signing: In Signing & Capabilities, disable the sandbox OR
//    add the "Hardened Runtime" entitlement with "Allow Execution of JIT-compiled Code"
//    (not needed) plus the "com.apple.security.cs.allow-unsigned-executable-memory"
//    entitlement if required. For local use, just disable sandboxing.
//
// 4. Sparkle (optional): Add package dependency:
//    https://github.com/sparkle-project/Sparkle  version 2.x

import PackageDescription

let package = Package(
    name: "Lossly",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Lossly", targets: ["Lossly"])
    ],
    dependencies: [
        .package(url: "https://github.com/ryohey/Zoomable.git", branch: "main"),
        // Uncomment to add Sparkle auto-update:
        // .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "Lossly",
            dependencies: [
                .product(name: "Zoomable", package: "Zoomable"),
                // Uncomment if Sparkle is added:
                // .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: ".",
            exclude: [
                "Resources/Info.plist",
                "README.md",
                "build-tools.sh",
            ],
            sources: [
                "ImageAlphaApp.swift",
                "Models/Quantizer.swift",
                "Models/BackgroundStyle.swift",
                "Models/ImageDocument.swift",
                "Services/QuantizationService.swift",
                "Services/ImageOptimIntegration.swift",
                "Utilities/VisualEffectView.swift",
                "Utilities/HandCursorView.swift",
                "Views/ContentView.swift",
                "Views/SidebarView.swift",
                "Views/ImagePreviewView.swift",
                "Views/BackgroundPickerView.swift",
                "Views/SettingsView.swift",
            ],
            resources: [
                .copy("Resources/Textures"),
                // Bundle the pre-built CLI tools so they are placed in the
                // app's Resources directory and discoverable at runtime.
                .copy("Binaries/pngquant"),
                .copy("Binaries/posterizer"),
            ],
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=complete"]),
            ]
        ),
    ]
)
