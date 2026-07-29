// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ScreenHarborCore",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(name: "SharedModels", targets: ["SharedModels"]),
        .library(name: "SharedProtocol", targets: ["SharedProtocol"]),
        .library(name: "SharedUtilities", targets: ["SharedUtilities"]),
        .library(name: "CaptureEngine", targets: ["CaptureEngine"]),
        .library(name: "EncodeEngine", targets: ["EncodeEngine"]),
        .library(name: "TransportWebRTC", targets: ["TransportWebRTC"]),
        .library(name: "InputControl", targets: ["InputControl"]),
        .library(name: "Permissions", targets: ["Permissions"]),
        .library(name: "Discovery", targets: ["Discovery"]),
        .library(name: "Diagnostics", targets: ["Diagnostics"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.15.0")
    ],
    targets: [
        .target(name: "SharedModels"),
        // Vendored opus 1.4 (Xiph) C codec, float build. SIMD/fixed-point/test/demo
        // sources are excluded; the kept sources are pure portable C. Hung off
        // SharedProtocol (below) because both the host encode path and the client decode
        // path already import SharedProtocol and every app links it — so the codec links
        // transitively into all three apps with no Xcode-project changes.
        .target(
            name: "Copus",
            exclude: ["celt/arm", "celt/x86", "silk/arm", "silk/x86", "celt/opus_custom_demo.c"],
            publicHeadersPath: "include",
            cSettings: [
                .define("HAVE_CONFIG_H"),
                .define("OPUS_WILL_BE_SLOW"),
                .headerSearchPath("."),
                .headerSearchPath("celt"),
                .headerSearchPath("silk"),
                .headerSearchPath("silk/float")
            ]
        ),
        .target(name: "SharedProtocol", dependencies: ["SharedModels", "Copus"]),
        // Tiny ObjC helpers (NSException catch / AVAudioPlayerNode start). Kept as its
        // own target because SwiftPM rejects mixed-language sources in one target.
        .target(
            name: "RDObjCSupport",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("AVFAudio"),
                .linkedFramework("Foundation")
            ]
        ),
        .target(name: "SharedUtilities", dependencies: ["SharedModels", "RDObjCSupport"]),
        .target(name: "CaptureEngine", dependencies: ["SharedModels"]),
        .target(name: "EncodeEngine", dependencies: ["SharedModels"]),
        .target(name: "TransportWebRTC", dependencies: ["SharedModels", "SharedProtocol", "SharedUtilities"]),
        .target(name: "InputControl", dependencies: ["SharedModels"]),
        .target(name: "Permissions", dependencies: ["SharedModels"]),
        .target(name: "Discovery", dependencies: ["SharedModels", "SharedProtocol", "SharedUtilities", "TransportWebRTC", "Permissions"]),
        .target(name: "Diagnostics", dependencies: ["SharedModels"]),
        .target(name: "HostWidgetShared"),
        .target(name: "SharedUI"),
        .executableTarget(
            name: "HostApp",
            dependencies: [
                "SharedModels",
                "SharedProtocol",
                "SharedUtilities",
                "CaptureEngine",
                "EncodeEngine",
                "TransportWebRTC",
                "InputControl",
                "Permissions",
                "Discovery",
                "Diagnostics",
                "HostWidgetShared",
                "SharedUI"
            ],
            exclude: [
                "Assets.xcassets"
            ],
            resources: [
                .process("Localizable.xcstrings"),
                .process("PrivacyInfo.xcprivacy")
            ]
        ),
        .target(
            name: "ClientiOS",
            dependencies: [
                "SharedModels",
                "SharedProtocol",
                "SharedUtilities",
                "TransportWebRTC",
                "Discovery",
                "Diagnostics",
                "Permissions",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/ClientiOS",
            exclude: [
                "AnnotationOverlayStore.swift",
                "AppIntents.swift",
                "AppLockService.swift",
                "AppLockView.swift",
                "Assets.xcassets",
                "BackgroundKeepaliveService.swift",
                "BluetoothInputController.swift",
                "BluetoothInputStatusView.swift",
                "ClientiOSApp.swift",
                "Components",
                "DesignSystem",
                "KeyboardOverlayView.swift",
                "LiveActivityService.swift",
                "Onboarding",
                "PrivacyInfo.xcprivacy",
                "ReceivedFileSaveSheet.swift",
                "RemoteInteractionViewModel.swift",
                "ScreenAIToolsView.swift",
                "SessionNotesStore.swift",
                "StreamingPaywallView.swift",
                "TerminalModeView.swift",
                "Views",
                "VoiceDictationService.swift"
            ],
            sources: [
                "AppHaptics.swift",
                "BonjourWakeService.swift",
                "ClientAppEnvironment.swift",
                "ClientAudioRenderer.swift",
                "ClientClipboardSyncManager.swift",
                "ClientFileTransferManager.swift",
                "ClientHostBlockedState.swift",
                "ClientReconnectCoordinator.swift",
                "ClientSessionCoordinator.swift",
                "ClientSettingsSyncService.swift",
                "ClientTerminalSessionManager.swift",
                "ClientTrustedHostsViewModel.swift",
                "CrashSafeStartupDiagnostics.swift",
                "DisplayLayoutViewModel.swift",
                "HostsListViewModel.swift",
                "Models/Display.swift",
                "Models/Host.swift",
                "Models/Session.swift",
                "RemoteDisplayViewModel.swift",
                "SessionScreenshotService.swift",
                "SessionStatsViewModel.swift",
                "VideoFrameDecoderView.swift",
                "WakeCoordinator.swift",
                "WakeOnLANService.swift"
            ],
            resources: [
                .process("Localizable.xcstrings")
            ]
        ),
        .testTarget(
            name: "ScreenHarborCoreTests",
            dependencies: [
                "SharedModels",
                "SharedProtocol",
                "SharedUtilities",
                "CaptureEngine",
                "Discovery",
                "Diagnostics",
                "EncodeEngine",
                "TransportWebRTC",
                "InputControl",
                "Permissions",
                "HostApp",
                "ClientiOS"
            ],
            path: "Tests/RemoteDesktopToolTests"
        )
    ]
)
