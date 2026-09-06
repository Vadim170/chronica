import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia

/// System-audio capture via ScreenCaptureKit. Used as the fallback path on
/// macOS 13.0–14.3 (and as a secondary path if the process tap fails).
///
/// We capture a tiny (2x2) video stream — SCStream requires a display target —
/// and enable audio capture. `excludesCurrentProcessAudio = true` is mandatory
/// to avoid feeding our own output back into the recording (echo).
///
/// Requires the "Screen Recording" TCC permission. In an unsigned/dev build the
/// permission prompt may not appear; `SCShareableContent` then fails and we
/// throw a user-facing error rather than crashing.
final class ScreenCaptureSource: NSObject, AudioSource, AudioSourceFailureReporting,
                                 AsyncStartAudioSource, SCStreamOutput, SCStreamDelegate {
    /// Тестовый seam для async setup. Production оставляет `nil` и выполняет
    /// настоящий ScreenCaptureKit setup; тесты могут вернуть `nil` без TCC.
    typealias StartOperation = @Sendable () async throws -> SCStream?

    /// Общий результат async setup. `@unchecked Sendable` оправдан тем, что
    /// доступ к каждому полю защищён одним NSLock, а SCStream останавливается
    /// при гонке с timeout.
    private final class StartState: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private var timedOut = false
        private var stream: SCStream?
        private var error: Error?
        /// Ожидающий async-путь. Резюмируется ровно один раз: либо завершением
        /// операции, либо таймером (кто первый снял continuation под локом).
        private var waiter: CheckedContinuation<Void, Never>?

        /// Returns false when the caller already timed out; in that case the
        /// caller owns cleanup of the returned stream.
        func finish(stream: SCStream?, error: Error?) -> Bool {
            lock.lock()
            guard !timedOut else { lock.unlock(); return false }
            done = true
            self.stream = stream
            self.error = error
            let waiter = self.waiter
            self.waiter = nil
            lock.unlock()
            waiter?.resume()
            return true
        }

        /// Асинхронно ждёт завершения операции не дольше `timeout` секунд.
        /// Возвращает `true`, если операция успела завершиться.
        func wait(timeout: TimeInterval) async -> Bool {
            let timer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0.01, timeout) * 1_000_000_000))
                self?.resumeWaiter()
            }
            // Работа с локом вынесена в синхронные методы: NSLock нельзя
            // держать через точку приостановки.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                register(waiter: continuation)
            }
            timer.cancel()
            return isFinished
        }

        /// Регистрирует ожидающего или сразу резюмирует его, если операция
        /// уже завершилась.
        private func register(waiter continuation: CheckedContinuation<Void, Never>) {
            lock.lock()
            if done {
                lock.unlock()
                continuation.resume()
                return
            }
            waiter = continuation
            lock.unlock()
        }

        private var isFinished: Bool {
            lock.lock(); defer { lock.unlock() }
            return done
        }

        private func resumeWaiter() {
            lock.lock()
            let waiter = self.waiter
            self.waiter = nil
            lock.unlock()
            waiter?.resume()
        }

        /// Marks an unfinished operation timed out. A completed operation wins
        /// the race and returns false so its result can still be consumed.
        func markTimedOut() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !done else { return false }
            timedOut = true
            return true
        }

        func result() -> (stream: SCStream?, error: Error?) {
            lock.lock(); defer { lock.unlock() }
            return (stream, error)
        }
    }

    private var stream: SCStream?
    private var sink: (([Int16], UInt32, UInt8) -> Void)?
    private let audioQueue = DispatchQueue(label: "chronica.sck.audio", qos: .userInitiated)
    private var scratch = [Int16]()
    private let lock = NSLock()
    private let startTimeout: TimeInterval
    private let injectedStartOperation: StartOperation?
    /// Retain the in-flight setup so timeout/stop can request cancellation.
    /// ScreenCaptureKit may still finish its operation later; `StartState`
    /// owns the race and stops any stream returned after timeout.
    private var startTask: Task<Void, Never>?
    private(set) var isRunning = false
    var failureHandler: ((Error) -> Void)?

    /// `startTimeout` ограничивает ожидание ScreenCaptureKit, чтобы sync
    /// `AudioSource.start` никогда не блокировал MainActor навсегда. Вызов без
    /// `startOperation` использует реальный SCK setup.
    init(startTimeout: TimeInterval = 10, startOperation: StartOperation? = nil) {
        self.startTimeout = max(0.01, startTimeout)
        self.injectedStartOperation = startOperation
        super.init()
    }

    /// Синхронный старт из протокола `AudioSource`: ограниченное ожидание на
    /// семафоре. Production ходит через `startAsync` (главный поток не
    /// блокируется); этот путь остаётся для вызывающих, у которых нет async
    /// контекста, и его границу проверяют тесты.
    func start(channelId: String, sink: @escaping ([Int16], UInt32, UInt8) -> Void) throws {
        guard !isRunning else { return }
        let sema = DispatchSemaphore(value: 0)
        let state = beginStart(sink: sink, signal: { sema.signal() })
        let timedOut = sema.wait(timeout: .now() + startTimeout) == .timedOut
        try finishStart(state: state, timedOut: timedOut)
    }

    /// Асинхронный старт: то же ограниченное ожидание, но через `await`.
    func startAsync(channelId: String,
                    sink: @escaping ([Int16], UInt32, UInt8) -> Void) async throws {
        guard !isRunning else { return }
        let state = beginStart(sink: sink, signal: {})
        let finished = await state.wait(timeout: startTimeout)
        try finishStart(state: state, timedOut: !finished)
    }

    /// Запускает SCK-setup вне вызывающего потока и отдаёт общее состояние
    /// гонки «завершилось / истёк таймаут».
    private func beginStart(sink: @escaping ([Int16], UInt32, UInt8) -> Void,
                            signal: @escaping @Sendable () -> Void) -> StartState {
        startTask?.cancel()
        startTask = nil
        self.sink = sink

        let state = StartState()
        let operation = injectedStartOperation ?? { [weak self] in
            guard let self else {
                throw AudioCaptureError.systemAudioUnavailable(
                    reason: L("error.audio.reason.sourceDeinit"))
            }
            return try await self.makeStream()
        }
        // Операция намеренно detached: синхронный путь ждёт её на семафоре, а
        // структурированная задача внутри main actor тогда бы залипла.
        startTask = Task.detached {
            do {
                let stream = try await operation()
                if !state.finish(stream: stream, error: nil) {
                    // Timeout won the race; don't leak a stream that completed
                    // after the caller had already returned an error.
                    if let stream { try? await stream.stopCapture() }
                }
            } catch {
                _ = state.finish(stream: nil, error: error)
            }
            signal()
        }
        return state
    }

    /// Общая обработка результата для sync/async путей.
    private func finishStart(state: StartState, timedOut: Bool) throws {
        if timedOut, state.markTimedOut() {
            startTask?.cancel()
            startTask = nil
            sink = nil
            throw AudioCaptureError.systemAudioUnavailable(
                reason: L("error.audio.reason.sckTimeout", Int(startTimeout)))
        }

        startTask = nil
        let result = state.result()
        if let startError = result.error {
            sink = nil
            if let e = startError as? AudioCaptureError { throw e }
            throw AudioCaptureError.systemAudioUnavailable(reason: startError.localizedDescription)
        }
        guard let stream = result.stream else {
            sink = nil
            throw AudioCaptureError.systemAudioUnavailable(
                reason: L("error.audio.reason.sckNoStream"))
        }
        self.stream = stream
        isRunning = true
    }

    func stop() {
        startTask?.cancel()
        startTask = nil
        isRunning = false
        let s = stream
        stream = nil
        sink = nil
        if let s {
            Task { try? await s.stopCapture() }
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let sink, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let pcmBuffer = makePCMBuffer(from: sampleBuffer) else { return }
        lock.lock()
        let result = PCMConvert.toInt16(pcmBuffer, scratch: &scratch)
        lock.unlock()
        if let (pcm, sr, ch) = result {
            sink(pcm, sr, ch)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        isRunning = false
        Task { @MainActor [weak self] in self?.failureHandler?(error) }
    }

    // MARK: - Helpers

    /// Реальный ScreenCaptureKit setup, вынесенный из sync bridge. Возвращает
    /// stream только после успешного `startCapture`; caller присваивает его
    /// `self.stream` под контролем timeout state.
    private func makeStream() async throws -> SCStream {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw AudioCaptureError.systemAudioUnavailable(
                reason: L("error.audio.reason.noDisplay"))
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true   // mandatory — avoid echo
        config.sampleRate = 48_000
        config.channelCount = 2
        // Minimal video footprint; SCStream needs a display target.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 6

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.audioQueue)
        try await stream.startCapture()
        return stream
    }

    /// Build an AVAudioPCMBuffer from a CMSampleBuffer's audio. SCK delivers
    /// Float32; the format descriptor tells us interleaving/rate/channels.
    private func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc) else { return nil }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return nil }
        var streamDesc = asbd.pointee
        guard let avFormat = AVAudioFormat(streamDescription: &streamDesc),
              let buffer = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: AVAudioFrameCount(frames))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)

        // Copy raw audio bytes into the PCM buffer's audioBufferList.
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames),
            into: buffer.mutableAudioBufferList)
        guard status == noErr else { return nil }
        return buffer
    }
}
