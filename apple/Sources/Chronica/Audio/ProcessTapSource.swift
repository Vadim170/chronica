import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

/// System-audio capture via the Core Audio process-tap API (macOS 14.4+).
///
/// Pipeline:
///   1. `CATapDescription` for a global, stereo mixdown of all processes.
///   2. `AudioHardwareCreateProcessTap` → a tap object.
///   3. An aggregate device that wraps the tap (`kAudioAggregateDeviceTapListKey`),
///      created with `AudioHardwareCreateAggregateDevice`.
///   4. `AudioDeviceCreateIOProcIDWithBlock` + `AudioDeviceStart` to receive the
///      tap's audio in an IO block, which we convert to Int16 and forward.
///
/// Requires the "System Audio Recording" TCC permission. In an unsigned/dev
/// build the prompt may not appear and creation will fail with an OSStatus —
/// we surface that as a user-facing error instead of crashing.
/// Core Audio's process-tap API has no delegate for asynchronous tap
/// invalidation. The IO proc therefore has no synthetic failure callback;
/// the Engine watchdog remains the fallback when callbacks stop arriving.
@available(macOS 14.4, *)
final class ProcessTapSource: AudioSource, AudioSourceFailureReporting {
    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var sink: (([Int16], UInt32, UInt8) -> Void)?
    private var scratch = [Int16]()
    private var tapFormat: AudioStreamBasicDescription?
    private(set) var isRunning = false
    var failureHandler: ((Error) -> Void)?

    func start(channelId: String, sink: @escaping ([Int16], UInt32, UInt8) -> Void) throws {
        guard !isRunning else { return }
        self.sink = sink

        // 1. Tap description: capture every process (empty exclude list),
        //    mixed down to stereo, muted from the local output behaviour we
        //    don't need (we only read it).
        let tapDescription = CATapDescription(stereoMixdownOfProcesses: [])
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = .unmuted
        tapDescription.isPrivate = true

        // 2. Create the tap.
        var newTap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(tapDescription, &newTap)
        guard status == noErr, newTap != kAudioObjectUnknown else {
            cleanup()
            throw AudioCaptureError.osStatus(stage: "AudioHardwareCreateProcessTap", code: status)
        }
        tapID = newTap

        // Read the tap's stream format so we know rate/channels for the IO block.
        tapFormat = try readTapFormat(tapID)

        // 3. Aggregate device wrapping the tap.
        let aggUID = "chronica.aggregate.\(tapDescription.uuid.uuidString)"
        let tapUID = tapDescription.uuid.uuidString
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Chronica System Capture",
            kAudioAggregateDeviceUIDKey as String: aggUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: tapUID,
                    kAudioSubTapDriftCompensationKey as String: true,
                ]
            ],
        ]

        var newAggregate = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregate)
        guard status == noErr, newAggregate != kAudioObjectUnknown else {
            cleanup()
            throw AudioCaptureError.osStatus(stage: "AudioHardwareCreateAggregateDevice", code: status)
        }
        aggregateID = newAggregate

        // 4. IO proc block. Keep the realtime work minimal: convert and sink.
        let ioBlock: AudioDeviceIOBlock = { [weak self] _, inInputData, _, _, _ in
            guard let self, let sink = self.sink, let fmt = self.tapFormat else { return }
            self.handleInput(inInputData, format: fmt, sink: sink)
        }

        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil, ioBlock)
        guard status == noErr, let procID else {
            cleanup()
            throw AudioCaptureError.osStatus(stage: "AudioDeviceCreateIOProcIDWithBlock", code: status)
        }
        ioProcID = procID

        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            cleanup()
            throw AudioCaptureError.osStatus(stage: "AudioDeviceStart", code: status)
        }

        isRunning = true
    }

    func stop() {
        cleanup()
        isRunning = false
    }

    // MARK: - Realtime input

    private func handleInput(_ bufferList: UnsafePointer<AudioBufferList>,
                             format: AudioStreamBasicDescription,
                             sink: ([Int16], UInt32, UInt8) -> Void) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard abl.count > 0 else { return }
        let channels = Int(format.mChannelsPerFrame)
        guard channels > 0 else { return }

        let isFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isInt16 = !isFloat && format.mBitsPerChannel == 16

        // Tap audio is non-interleaved Float32 in practice (one buffer per
        // channel), but handle the interleaved case too.
        let buf0 = abl[0]
        if abl.count == channels {
            // Non-interleaved: abl.count buffers, one channel each.
            let frames = Int(buf0.mDataByteSize) / MemoryLayout<Float>.size
            guard frames > 0 else { return }
            let total = frames * channels
            if scratch.count < total { scratch = [Int16](repeating: 0, count: total) }
            scratch.withUnsafeMutableBufferPointer { dst in
                for c in 0..<channels {
                    guard let raw = abl[c].mData else { continue }
                    if isFloat {
                        let src = raw.assumingMemoryBound(to: Float.self)
                        for f in 0..<frames { dst[f * channels + c] = PCMConvert.clampToInt16(src[f]) }
                    } else if isInt16 {
                        let src = raw.assumingMemoryBound(to: Int16.self)
                        for f in 0..<frames { dst[f * channels + c] = src[f] }
                    }
                }
            }
            sink(Array(scratch[0..<total]), UInt32(format.mSampleRate), UInt8(channels))
        } else {
            // Interleaved: single buffer, all channels.
            guard let raw = buf0.mData else { return }
            if isFloat {
                let count = Int(buf0.mDataByteSize) / MemoryLayout<Float>.size
                guard count > 0 else { return }
                if scratch.count < count { scratch = [Int16](repeating: 0, count: count) }
                let src = raw.assumingMemoryBound(to: Float.self)
                scratch.withUnsafeMutableBufferPointer { dst in
                    for i in 0..<count { dst[i] = PCMConvert.clampToInt16(src[i]) }
                }
                sink(Array(scratch[0..<count]), UInt32(format.mSampleRate), UInt8(channels))
            } else if isInt16 {
                let count = Int(buf0.mDataByteSize) / MemoryLayout<Int16>.size
                guard count > 0 else { return }
                if scratch.count < count { scratch = [Int16](repeating: 0, count: count) }
                let src = raw.assumingMemoryBound(to: Int16.self)
                scratch.withUnsafeMutableBufferPointer { dst in
                    for i in 0..<count { dst[i] = src[i] }
                }
                sink(Array(scratch[0..<count]), UInt32(format.mSampleRate), UInt8(channels))
            }
        }
    }

    // MARK: - Helpers

    private func readTapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd)
        guard status == noErr, asbd.mChannelsPerFrame > 0, asbd.mSampleRate > 0 else {
            throw AudioCaptureError.osStatus(stage: "kAudioTapPropertyFormat", code: status)
        }
        return asbd
    }

    private func cleanup() {
        if aggregateID != kAudioObjectUnknown {
            if let procID = ioProcID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
                ioProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        tapFormat = nil
        sink = nil
    }
}
