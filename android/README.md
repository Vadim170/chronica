# Transcriber — Android client

A native Android (Kotlin + Jetpack Compose) client for the `transcriber-core`
Rust engine. It reuses the **same** Rust core as the macOS/iOS app through
**UniFFI 0.28** Kotlin bindings, loading the cross-compiled `.so` via JNA.

The core owns resampling, VAD, interval cutting, ASR, persistence (SQLite),
metrics and an optional local HTTP API. The Android app is a thin shell: it
captures microphone PCM, pushes frames into the core, and renders the events
the core emits.

```
android/
├── build-core.sh            # builds the .so + generates Kotlin bindings
├── settings.gradle.kts      # Kotlin-DSL Gradle project
├── build.gradle.kts
├── gradle.properties
├── local.properties         # sdk.dir (generated, git-ignored)
├── gradlew / gradle/        # Gradle wrapper (8.11.1)
└── app/
    ├── build.gradle.kts      # namespace app.transcriber.android, minSdk 29
    ├── proguard-rules.pro
    └── src/
        ├── main/
        │   ├── AndroidManifest.xml
        │   ├── jniLibs/arm64-v8a/                          # ← cross-compiled / prebuilt
        │   │   ├── libtranscriber_core.so                  #   Rust core (links sherpa C-API)
        │   │   ├── libsherpa-onnx-c-api.so                 #   k2-fsa prebuilt (ORT wrapper)
        │   │   └── libonnxruntime.so                       #   ONNX Runtime for Android
        │   ├── java/uniffi/transcriber_core/...kt          # ← generated bindings
        │   ├── java/app/transcriber/android/
        │   │   ├── EngineState.kt          # immutable UI state + pure reduce()
        │   │   ├── EngineBridge.kt         # wraps TranscriberCore; mic + remote channels
        │   │   ├── AudioCapture.kt         # mic AudioRecord → core "mic" channel
        │   │   ├── SystemAudioCapture.kt   # loopback AudioRecord → core "remote" channel (P5)
        │   │   ├── MediaProjectionService.kt # foreground service (mediaProjection) (P5)
        │   │   ├── RecordingService.kt     # foreground service (microphone), hardened (P4)
        │   │   ├── RecordingController.kt  # pure Idle/Recording/Paused state machine (P4)
        │   │   ├── MainViewModel.kt
        │   │   └── MainActivity.kt         # Compose dark-theme UI
        │   └── res/values/{strings,themes}.xml
        └── test/java/app/transcriber/android/
            ├── EngineStateReducerTest.kt     # reducer behaviour (11)
            ├── RecordingControllerTest.kt    # service state machine (15)
            └── SystemAudioCaptureTest.kt     # playback-capture usage selection (3)
```

## Prerequisites

- macOS, Apple Silicon; JDK 21; Android SDK at `~/Library/Android/sdk`.
- Android NDK `29.0.13599879` (set `ANDROID_NDK_HOME` if elsewhere).
- Rust toolchain (`. "$HOME/.cargo/env"`), plus:

```bash
cargo install cargo-ndk
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
```

## 1. Build the native library + Kotlin bindings

```bash
cd android
./build-core.sh                          # arm64-v8a (physical devices)
ABIS="arm64-v8a x86_64" ./build-core.sh  # also build the emulator ABI
```

`build-core.sh`:

1. **Host build** (`cargo build --features ffi`) to produce a dylib for the
   binding generator.
2. **Generates Kotlin bindings** into `app/src/main/java/uniffi/` via
   `cargo run --features ffi --bin uniffi-bindgen -- generate --library <dylib>
   --language kotlin --out-dir app/src/main/java`. They are regenerated every
   run so they never drift from the core's FFI surface.
3. **Cross-compiles the `.so`** with
   `cargo ndk -t <abi> -o app/src/main/jniLibs build --release --features ffi`
   (using NDK 29 via `ANDROID_NDK_HOME`).

### Cargo features used for Android — REAL ASR (ORT) now enabled

The build now uses **`--features ffi,sherpa`** (the default in `build-core.sh`).
`ffi` pulls the crate's default set — `store` (SQLite/rusqlite-bundled),
`api` (tiny_http), `download` (ureq + rustls/ring), `mock-asr` — and `sherpa`
adds the real ONNX Runtime ASR backend via `sherpa-rs`. All cross-compile
cleanly for `aarch64-linux-android` with NDK 29.

**How the ONNX Runtime gets built for Android (the P3 breakthrough).**
`sherpa-rs` 0.6 ships the `download-binaries` feature **on by default**. Its
`sherpa-rs-sys` `build.rs` has a dist table (`dist.json`) with an
`aarch64-linux-android` entry pointing at k2-fsa's official prebuilt release
`sherpa-onnx-v1.12.9-android.tar.bz2`. For an Android target the build script:

1. downloads that tarball (cached under `~/Library/Caches/sherpa-rs/<triple>/`),
2. sets `SHERPA_LIB_PATH` to it and links `libsherpa-onnx-c-api.so` +
   `libonnxruntime.so` dynamically (no CMake, no manual NDK build of ORT),
3. so `cargo ndk -t arm64-v8a build --release --features ffi,sherpa` "just
   works" out of the box in this environment — no env-var spelunking needed.

The resulting dependency chain is
`libtranscriber_core.so` → `libsherpa-onnx-c-api.so` → `libonnxruntime.so`
(verified via `llvm-readelf -d`: the core has a `DT_NEEDED` on
`libsherpa-onnx-c-api.so` and an undefined `SherpaOnnxCreateOfflineRecognizer`
symbol — i.e. it genuinely links the sherpa C-API, not the mock). At runtime
Android's linker resolves all three from the APK's `lib/arm64-v8a/` dir, so no
manual `System.loadLibrary` ordering is required.

**Caveat:** the two ORT/sherpa `.so` are NOT emitted by `cargo ndk -o`
(`build.rs` copies them into the *cargo target dir*, not the cargo-ndk output),
so `build-core.sh` copies them from `$CARGO_TARGET_DIR/<triple>/release/` into
`jniLibs/<abi>/` itself (step 4), and deletes the stray `libsherpa_rs-*.so`
cdylib by-product that cargo-ndk emits. The prebuilt ABIs in the tarball are
`arm64-v8a`, `armeabi-v7a`, `x86`, `x86_64`; an emulator build needs `x86_64`
in both `ABIS` and `app/build.gradle.kts`'s `abiFilters`.

**ASR routing.** The core routes Parakeet → coreml → sherpa → mock. CoreML is
Apple-only (absent on Android), so on Android Parakeet resolves to the **sherpa
(ONNX Runtime)** backend — real transcription. `mock-asr` is still compiled in
but only as the last-resort fallback if sherpa fails to initialise.

**Native lib sizes (arm64-v8a):** `libtranscriber_core.so` ~5.2 MB,
`libsherpa-onnx-c-api.so` ~4.3 MB, `libonnxruntime.so` ~15 MB. The debug APK is
~80 MB (was ~59 MB on the mock build; the +21 MB is the bundled ORT/sherpa).

**Model supply.** Parakeet TDT v3 int8 (~640 MB) is downloaded on-device by the
core's `model_manager` (ureq, cross-compiles fine) into `filesDir/models`; the
Compose model list shows per-model download status/progress and a Download
button (`EngineBridge.downloadModel` → `CoreEvent.ModelProgress`). The weights
are NOT shipped in the APK. Real transcription on a device additionally requires
the user to download the model and is **not verified in CI** (no device run
here); the linkage and packaging are verified.

**`--features ffi` (mock-only) build** is still supported for an ORT-free
artifact: `FEATURES="ffi" ./build-core.sh`.

## 2. Build the APK

```bash
cd android
./gradlew assembleDebug
# → app/build/outputs/apk/debug/app-debug.apk
```

Run unit tests (pure JVM, no device/native lib needed):

```bash
./gradlew testDebugUnitTest
```

Install on a connected arm64 device:

```bash
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

> The Gradle wrapper is pinned to **8.11.1** (compatible with AGP 8.7.3). The
> Android `abiFilters` is set to `arm64-v8a` only — add `x86_64` there **and**
> rebuild the `.so` for it (`ABIS="arm64-v8a x86_64" ./build-core.sh`) to run on
> an x86_64 emulator.

## Audio capture status

| Source            | Status      | Notes |
|-------------------|-------------|-------|
| **Microphone**    | ✅ working  | `AudioRecord` (16 kHz mono PCM16, `VOICE_RECOGNITION`) on a background thread → `pushAudioFrame("mic", …)`. Runtime `RECORD_AUDIO` permission requested from the UI. The core resamples internally. |
| **System audio**  | ✅ implemented | `MediaProjection` + `AudioPlaybackCaptureConfiguration` (API 29+) → `"remote"` channel. `SystemAudioCapture` builds a second `AudioRecord` over a `MediaProjection` (usages MEDIA/GAME/UNKNOWN, 16 kHz mono PCM16) and pushes via `EngineBridge.pushRemoteFrame`. `MediaProjectionService` (`foregroundServiceType=mediaProjection`) owns the projection token and observes the start-foreground-before-projection ordering required on Android 14+. Consent dialog launched from `MainActivity`. **Not device-verified.** |

> **System-audio caveat (also surfaced in the UI):** only audio from apps that
> allow playback capture is captured (apps opt out via
> `android:allowAudioPlaybackCapture` / `setAllowedCapturePolicy`). **Calls and
> DRM-protected content are blocked by Android at the system level.** This
> captures *media / screen audio*, not the remote party of a phone/VoIP call.

### Foreground recording service (P4)

`RecordingService` (`foregroundServiceType=microphone`) is the production owner
of recording robustness:

- **Persistent ongoing notification** with Start/Stop action buttons and a tap
  target that opens `MainActivity`.
- **Audio focus**: requests `AUDIOFOCUS_GAIN`; an incoming call
  (`AUDIOFOCUS_LOSS[_TRANSIENT]`) **pauses** capture and `AUDIOFOCUS_GAIN`
  **resumes** it — the engine session stays alive across the call.
- **Partial wake lock** (`transcriber:recording`) held while recording so the
  CPU keeps transcribing with the screen off; released on stop.
- **`START_STICKY` + `onTaskRemoved`**: swipe-away does not stop recording; a
  sticky restart with a null intent resumes.
- **Clean teardown**: `stopForeground(STOP_FOREGROUND_REMOVE)`, wake-lock
  release, audio-focus abandon.

All lifecycle *decisions* live in a pure, Android-free `RecordingController`
state machine (Idle / Recording / Paused) that returns side-effect descriptors
(`Action.AcquireWakeLock`, `StartCapture`, `PauseCapture`, …); the service
interprets them and fans capture start/stop/pause/resume out to the app via
`RecordingCallbacks` (wired by `MainViewModel` through a `LocalBinder`). This
keeps every interesting transition unit-testable on the JVM.

## How the bridge works

- **`EngineBridge`** builds the production `CoreConfig` (Parakeet model, auto
  language/acceleration, 30 s min / 300 s max interval, 2000 ms silence cut,
  `storagePath = filesDir`, `modelsPath = filesDir/models`, API off), owns the
  `TranscriberCore`, and implements `CoreEventListener`.
- Core events are folded into an immutable **`EngineState`** by the pure
  `reduce(prev, event)` function and published as a `StateFlow` for Compose.
  Keeping the reducer pure is what makes the logic unit-testable without the
  native library.

## Tests

**29 JVM unit tests** (`./gradlew testDebugUnitTest`), all behavioural, none
touching the native library / a device / an emulator:

- `EngineStateReducerTest` (11) — event-reducer behaviour: session transitions,
  newest-first/de-duplicated/capped transcript feed, RTF & word surfacing, error
  stickiness across clean metrics, model-progress upsert.
- `RecordingControllerTest` (15) — the recording state machine: start→recording
  (acquire wake lock + start capture), transient focus loss→pause, focus
  gain→resume, stop→release, idempotent double-start, stop-while-idle no-op,
  swipe-away does not stop, full incoming-call cycle.
- `SystemAudioCaptureTest` (3) — playback-capture usage selection: exact
  MEDIA/GAME/UNKNOWN set in order, no communication/ringtone usages (calls are
  not captured), no duplicates.

Tests that would need the real `.so` (constructing `TranscriberCore`,
`start`/`stop`, capture, real transcription) are out of scope for unit tests and
would be **instrumented tests on an arm64 device** — including verifying that
sherpa/ORT actually initialise and transcribe Parakeet, which is the one thing
not verified in this (headless) environment.

## Permissions

`RECORD_AUDIO`, `INTERNET` (model download / optional API),
`FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_MICROPHONE` (mic service),
`FOREGROUND_SERVICE_MEDIA_PROJECTION` (system-audio service),
`WAKE_LOCK` (keep transcribing with the screen off), and
`POST_NOTIFICATIONS` (Android 13+ runtime permission for the ongoing
foreground-service notification; requested on launch).
