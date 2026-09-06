[English](README.md) · [Русский](README.ru.md)

# Chronica

A local work-context collector for macOS: it transcribes your microphone and your system audio continuously, on device, and optionally keeps a text journal of what you were working on.

[![CI](https://github.com/Vadim170/chronica/actions/workflows/ci.yml/badge.svg)](https://github.com/Vadim170/chronica/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)](#requirements)

![Chronica menu-bar popover](docs/screenshots/popover-idle.png)

> The application interface is localized in **English and Russian** and follows your system language. The documents under `docs/` are written in Russian; this README and [README.ru.md](README.ru.md) are the English/Russian entry points.

## What it does

- **Transcribes two audio tracks at once** — your microphone (`mic`) and the system output (`remote`, i.e. the other side of a call, a video, a meeting) — and stores the result as timestamped intervals in SQLite.
- **Runs entirely on device.** Audio never leaves the machine. There is no telemetry, no analytics, no crash reporting and no auto-update.
- **Keeps an optional screen journal** (off by default): every so often it takes a still frame, a local vision model running in [Ollama](https://ollama.com) describes what work is going on, and only the *text* is kept — never the image.
- **Gives you the data back**: a searchable journal in the app, JSON/Markdown export for any period, an optional local HTTP API, and a `chronica` binary that reads the same database without the app running.
- **Lives in the menu bar** as a background agent — no Dock icon, no window in your way.

## Privacy

The short version: everything is processed and stored on your Mac. The long version is [`docs/PRIVACY.md`](docs/PRIVACY.md).

### What leaves the machine, and when

| Destination | When | Details |
|---|---|---|
| `huggingface.co` | Only when you press **Download** for a model | ASR weights (Parakeet / Whisper) and the 1.8 MB Silero VAD file, fetched over HTTPS and verified by sha256 where the digest is known |
| Ollama (`http://127.0.0.1:11434` by default) | Only while the screen journal is enabled | One HTTP request per tick with a downscaled JPEG of the screen and a short prompt. The address is a free-text setting — see the warning below |
| Local HTTP API (`127.0.0.1:8765` by default) | Only if you enable it in Settings | Serves your own data to your own machine. It refuses to start on a non-loopback address without a Bearer token |
| Anything else | Never | No telemetry, no analytics, no crash reports, no update checks, no account |

> **The Ollama address is yours to choose, and yours to be responsible for.** The default is loopback, and nothing is validated: if you point it at a remote host, screenshots will be sent there in base64 over plain HTTP.

### What is stored, and where

Everything lives under `~/Library/Application Support/Chronica/`.

| Path | Content |
|---|---|
| `store/transcriber.sqlite` | Transcript text per interval and channel, interval boundaries, voice-activity events |
| `store/screen.sqlite` | Screen journal: app name, window title, the model's text description, timestamps. **No images.** Kept for 90 days by default |
| `store/logs/core.log` | Rust panics and the native runtimes' stderr, for crash diagnostics. Rotated at 2 MB. Transcripts are never written here |
| `Models/` | ASR weights you downloaded |

### How to delete everything

```bash
# 1. Quit Chronica from the menu bar.
rm -rf ~/Library/Application\ Support/Chronica     # databases, logs, models
defaults delete io.github.vadim170.chronica        # settings
defaults delete app.transcriber.mac                # settings of the pre-rename build
rm -rf /Applications/Chronica.app
# 2. Revoke the permissions in System Settings → Privacy & Security →
#    Microphone / Screen & System Audio Recording.
```

## Requirements

- **macOS 14.0 or newer.** System-audio capture uses the Core Audio process-tap API, which needs **macOS 14.4+**; on 14.0–14.3 it falls back to ScreenCaptureKit.
- **Apple Silicon.** Releases are built for `arm64` only.
- **~640 MiB of disk** for the default Parakeet model (Whisper variants range from tens of MiB up to ~1.5 GiB).
- **RAM**: roughly 1.2–1.7 GB while recording, with a peak around 2.6 GB while the model loads (measured on an M4). Idle, with recording stopped, the agent sits at ~50 MB.
- The screen journal additionally needs [Ollama](https://ollama.com) installed and running.

## Install

1. Download `Chronica-<version>.dmg` from [Releases](https://github.com/Vadim170/chronica/releases) and drag the app to `/Applications`. **0.1.0 is signed ad-hoc only and is not notarized** — read the note below before you launch it.
2. Launch it. Chronica appears in the menu bar (there is no Dock icon).
3. On first run the popover shows exactly one thing to do: download the default model, *Parakeet TDT 0.6b v3 (int8)*, with its size and a progress bar. The Silero VAD file comes along with it automatically. The full list lives in the **Models** section.
4. Press the record button. macOS will ask for **Microphone** access, and for **Screen & System Audio Recording** for the system-audio track. If you decline the microphone, the popover offers a shortcut to the right settings pane instead of failing silently.
5. That is it. The popover shows the live feed; the **Journal** section shows history.

> **About the 0.1.0 signature.** This first release is signed ad-hoc, not with a Developer ID certificate, and is not notarized by Apple — signed, notarized releases will follow once one is in place. Gatekeeper blocks the first launch as a result: depending on your macOS version you'll see *"Chronica.app is damaged and can't be opened"* or *"Apple cannot check it for malicious software"*, and right-click → Open no longer works around this on macOS 15+. Two one-time fixes, once the app is in `/Applications`:
>
> - **Terminal:** `xattr -dr com.apple.quarantine /Applications/Chronica.app`, then double-click the app as usual.
> - **Without a terminal:** try to open it once (it will fail), then go to **System Settings → Privacy & Security** and click **Open Anyway** next to the Chronica entry.
>
> A `.sha256` checksum sits next to the DMG on the Releases page if you want to verify the download, and you can always build Chronica yourself from source — see [`docs/BUILD.md`](docs/BUILD.md).

A Homebrew cask is planned but does not exist yet. There is no in-app updater — new versions come from Releases.

**Upgrading from a build made before the rename** (the app used to be called *Transcriber*)? The bundle id changed, so macOS sees a brand-new application: grant **Microphone** and **Screen & System Audio Recording** again on the first run. Your data folder and your settings are migrated automatically at startup; the stale **Transcriber** entry under System Settings → General → Login Items is left for you to delete by hand.

## Interface

| Recording in progress | Model manager |
|---|---|
| ![The Chronica popover while recording](docs/screenshots/popover-recording.png) | ![The Chronica model manager](docs/screenshots/models.png) |

The menu-bar popover is the everyday surface: state, the two source toggles, a 24-hour activity chart, the live feed and the record button. Behind it sits a single window with three sections — **Journal** (activities and transcript, with a period picker, export and search), **Models** and **Settings**; technical counters live in a separate **Diagnostics** window.

**Language.** The interface ships in English and Russian and follows the system language, including the plural forms of counters and the localized date and number formats. To run Chronica in a different language than the rest of the system, use **System Settings → General → Language & Region → Applications** and add Chronica with the language you want. The screen journal asks the local vision model for descriptions *in the interface language*, so the journal never fills up with entries in a language you do not read.

## Models

Weights are never bundled: the app downloads them on your command into `~/Library/Application Support/Chronica/Models/`, resuming interrupted files and checking sha256 where the digest is known.

| Model | Size on disk | Runtime | Notes |
|---|---|---|---|
| **Parakeet TDT 0.6b v3 (int8)** — default | ~640 MiB (4 files) | sherpa-onnx | Multilingual, includes Russian and English. Language is detected automatically |
| Whisper `large-v3-turbo-q5_0` | ~547 MiB | whisper.cpp (Metal) | The recommended Whisper alternative |
| Whisper — 33 ggml variants in total | tens of MiB … ~1.5 GiB | whisper.cpp (Metal) | `tiny`/`base`/`small`/`medium`/`large`, `.en` and quantized ids |
| Silero VAD | 1.8 MB | sherpa-onnx | Hidden from the list; installed automatically with any ASR model |

Switching models requires restarting the recording session (the **Apply** button does it for you). Interval length, the silence threshold, the VAD threshold and the language are applied live, without a restart.

## Screen journal (optional)

Off by default. When you turn it on in Settings:

1. Once a minute by default (selectable: 1 / 2 / 5 / 10 minutes) Chronica captures one still frame with ScreenCaptureKit, downscales it to ~1024 pt and encodes it as JPEG.
2. A 64-bit average hash is compared with the previous frame. If the picture has not changed and the frontmost app and window title are the same, the vision model is **not called at all** — the current activity block is simply extended.
3. Otherwise the JPEG goes to Ollama on localhost, and the model returns one or two sentences about the work in progress.
4. Only text is written to `screen.sqlite`: app name, window title, the description, and timestamps — the frame itself is dropped right after the request. Observations are sessionized into activity blocks with a start and an end, and are kept for 90 days by default (30 / 90 / 180 days or forever).
5. Ticks are skipped entirely while the screen is locked or you have been idle longer than the period.

Setup:

```bash
brew install ollama          # or download from ollama.com
ollama serve
ollama pull qwen3-vl:2b      # the default; any Ollama vision model works
```

The model name and the Ollama URL are settings. The model's own license applies to you directly — see [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

## Local HTTP API & CLI

The API is **disabled by default**. Enable it in Settings; it then listens on `127.0.0.1:8765`, wraps answers in a `{ "ok": …, "data" | "error" }` envelope (except the file-shaped ones you would save as-is), and refuses to start on a non-loopback address unless you set a Bearer token. Endpoints cover engine state, intervals, a stitched transcript, full-text search, voice-activity buckets and a journal export; `GET /api/v1/openapi.json` serves the machine-readable spec. Full reference: [`docs/API.md`](docs/API.md) and [`docs/openapi.json`](docs/openapi.json).

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  "http://127.0.0.1:8765/api/v1/transcript?from=2026-09-03&to=2026-09-04"
```

`chronica` reads the same SQLite file and does **not** need the app to be running — useful for scripts and for piping a day into an LLM. Commands: `today`, `transcript`, `search`, `stats`, `export`, `db` (plus `transcribe` in an ML-enabled build). Full reference: [`docs/DATA.md`](docs/DATA.md).

```bash
cd core && cargo build --release --bin chronica --no-default-features --features store
cp target/release/chronica /usr/local/bin/    # no ML runtime, no dylibs needed
chronica today
```

## Architecture

The engine is a reusable Rust crate; the platform shell only captures audio, hosts the ML runtimes and draws the UI.

```
  macOS shell (SwiftUI + AppKit, menu-bar agent)
    microphone ─ AVAudioEngine ────────────┐
    system audio ─ Core Audio process tap  │  push PCM (any rate / channel count)
                   (14.4+) or ScreenCaptureKit
                                           ▼
  ┌──────────────── Rust core: transcriber-core ─────────────────────────────┐
  │  resample → 16 kHz mono                                                  │
  │  Silero VAD (RMS fallback if the weights are missing)                    │
  │  interval cutting: 30 s … 5 min, cut inside a silence gap between words  │
  │  ASR: Parakeet TDT 0.6b v3 int8 (sherpa-onnx) | Whisper (whisper.cpp)    │
  │  SQLite store (+ FTS5 index) · metrics · events                          │
  │  optional local HTTP API (loopback) · chronica over the same DB   │
  └──────────────────────────────────────────────────────────────────────────┘
                                           │ events / metrics over UniFFI
                                           ▼
    popover: status · source toggles · 24 h activity · live feed · start/stop
             + first-run steps (download the model, grant microphone access)
    window:  Journal (activities | transcript, period, export, search)
             Models · Settings (general · screen journal · advanced → Diagnostics)

  optional, off by default — screen journal (macOS only):
    ScreenCaptureKit still frame → average hash (unchanged frames skip the model)
      → Ollama vision model on localhost → text only → screen.sqlite
```

The core never touches the microphone itself: the shell pushes PCM frames in through `push_audio_frame`, and the core resamples and processes them. The same core also drives an Android client through UniFFI Kotlin bindings — that client is experimental, not verified on a device, and has no releases.

## Build from source

Happy path on a Mac with Rust ≥ 1.80, Xcode 16+ / Swift 6 and `cmake` installed:

```bash
git clone https://github.com/Vadim170/chronica.git
cd chronica/apple
./Scripts/build-core.sh debug     # Rust core + UniFFI Swift bindings + link
swift run Chronica             # run from the terminal (dev)
./Scripts/install-debug.sh        # or: build a .app, ad-hoc sign it, launch it
```

Tests:

```bash
cd core  && cargo test
cd apple && swift test
```

Behavioral tests for both the core and the app run in CI on every push, together with `rustfmt`, `clippy -D warnings` and a release-packaging lint.

The build needs network access: `sherpa-rs` downloads prebuilt sherpa-onnx / ONNX Runtime binaries, and `whisper-rs` compiles whisper.cpp through `cmake`. To build without any ML runtime, use the mock core (`TRANSCRIBER_CORE_MOCK=1` with `FEATURES=store,api,download,mock-asr,ffi`). Packaging, signing, notarization, feature flags and the usual failure modes are covered in [`docs/BUILD.md`](docs/BUILD.md).

## Project layout

```
core/      Rust crate `transcriber-core` — the engine, plus the `chronica` binary
apple/     macOS app (SwiftUI + AppKit); Sources/, Tests/, Resources/, Scripts/
android/   Android client on the same core — experimental, work in progress: builds from source, not verified on a device, no releases
docs/      API.md · DATA.md · PRIVACY.md · BUILD.md · ROADMAP.md · STATUS.md · archive/
scripts/   check-versions.sh — keeps the three version strings in sync
.github/   CI and the signed-release workflow
```

**Platform support:** macOS is the only platform Chronica ships and is supported on — see [Requirements](#requirements) and [Install](#install) above. Android is experimental and work in progress: it builds from source against the same core, but is not verified on a device and comes with no releases or guarantees. iOS is planned, not started.

`docs/STATUS.md` is the engineering log — long, Russian, and honest about what has and has not been verified. `docs/archive/` holds superseded internal planning documents.

### Naming

The product used to be called **Transcriber**, and 0.1.0 carries the rename all the way through the user-visible surface: the bundle id is `io.github.vadim170.chronica`, the executable is `Chronica`, and the data folder is `~/Library/Application Support/Chronica/`. On the first launch after an upgrade the old folder is moved over in a single operation (a rename on the same volume, so the 640 MiB of model weights do not get copied) and the `pref.*` settings are copied out of the old preferences domain. If the move fails, nothing is lost: the app keeps using the old folder and shows the error.

Internal technical names are deliberately left as they are: the Rust crate is `transcriber-core`, the FFI module is `transcriber_core` / `TranscriberCore`, and the database file is `transcriber.sqlite`. Renaming them would recreate the whole FFI surface without changing anything a user can see.

## Third-party & licenses

Chronica itself is MIT — see [`LICENSE`](LICENSE). No model weights are distributed with the app.

**The default ASR model requires attribution:** *Parakeet TDT 0.6b v3, © NVIDIA, licensed under [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/)* — [nvidia/parakeet-tdt-0.6b-v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3), downloaded from the sherpa-onnx int8 export. If you redistribute Chronica together with these weights, or build on them, that attribution travels with you.

Everything else — ONNX Runtime, sherpa-onnx, whisper.cpp, ggml, Silero VAD, the Rust crates, the Whisper weights, Ollama and the vision model — is listed with its license in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

## Contributing · Security · License

- Pull requests are welcome — see [`CONTRIBUTING.md`](CONTRIBUTING.md) for branches, quality gates and the test style the project expects.
- Found a vulnerability? Please report it privately through GitHub Security Advisories — see [`SECURITY.md`](SECURITY.md). Do not open a public issue for it.
- Licensed under the MIT License. Copyright © 2026 Vadim Makarov.
