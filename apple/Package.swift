// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Absolute path to this package, so the linker can find the prebuilt Rust
// static library copied into ./lib by Scripts/build-core.sh.
let pkgDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

// TRANSCRIBER_CORE_MOCK=1 — ядро собрано с mock-asr (без sherpa/whisper.cpp):
// не линкуем ML-рантаймы. Нужно для CI и разработки без ML-тулчейна
// (cmake/ORT). Прод-сборка build-core.sh выставляет это сама по FEATURES.
let mockCore = ProcessInfo.processInfo.environment["TRANSCRIBER_CORE_MOCK"] == "1"

let mlLinkFlags: [String] = mockCore ? [] : [
    // sherpa-onnx + ONNX Runtime (dynamic). Core built with
    // --features ffi,sherpa links these; rpath resolves them
    // from ./lib at runtime.
    "-lsherpa-onnx-c-api",
    "-lonnxruntime",
    // whisper.cpp + ggml (static, built by whisper-rs with the
    // metal feature; copied into ./lib by build-core.sh when
    // FEATURES includes `whispercpp`). Linked into the binary —
    // the metal shader is embedded in libggml-metal.a, so no
    // extra files need bundling in Contents/Frameworks.
    "-lwhisper",
    "-lggml",
    "-lggml-base",
    "-lggml-cpu",
    "-lggml-blas",
    "-lggml-metal",
]

let package = Package(
    name: "Chronica",
    // Базовый язык каталога строк (`Sources/Chronica/Resources/Localizable.xcstrings`).
    // Интерфейс локализован на английский и русский; язык выбирает система.
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Chronica", targets: ["Chronica"]),
    ],
    targets: [
        // C target whose name == the module the generated bindings import
        // (`import transcriber_coreFFI`). SwiftPM auto-generates the modulemap
        // from the header in include/.
        .target(
            name: "transcriber_coreFFI",
            path: "Sources/transcriber_coreFFI"
        ),
        // UniFFI-generated Swift bindings (transcriber_core.swift).
        .target(
            name: "TranscriberCore",
            dependencies: ["transcriber_coreFFI"],
            path: "Sources/TranscriberCore",
            // UniFFI 0.28 generates Swift-5-style code (mutable globals guarded
            // by the runtime). Build the bindings in language mode 5.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The menu-bar app.
        .executableTarget(
            name: "Chronica",
            dependencies: ["TranscriberCore"],
            path: "Sources/Chronica",
            // Каталог строк и продукты его компиляции (`{en,ru}.lproj/
            // Localizable.{strings,stringsdict}`) едут в ресурсный бандл
            // `Chronica_Chronica.bundle`; доступ — `Bundle.strings`
            // (см. Design/L10n.swift). Скрипты сборки .app копируют бандл в
            // `Contents/Resources`.
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(pkgDir)/lib",
                    "-ltranscriber_core",
                ] + mlLinkFlags + [
                    "-lc++",
                    "-Xlinker", "-rpath", "-Xlinker", "\(pkgDir)/lib",
                    // For the packaged .app the dylibs are copied to
                    // Contents/Frameworks; resolve them there too.
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                ]),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreML"),
                // Required by ggml-metal (Metal/MetalKit) and ggml-blas
                // (Accelerate) for the whisper.cpp Metal backend.
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
            ]
        ),
        // Behavioral unit tests (logic only — no UI snapshots). Tests the pure
        // "UI model selection → ModelSpec" mapping and state→label formatting.
        .testTarget(
            name: "ChronicaTests",
            dependencies: ["Chronica"],
            path: "Tests/ChronicaTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
