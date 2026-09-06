import Foundation
import AVFoundation

/// Captures audio from a source and pushes PCM frames into the engine. The
/// engine's `pushFrame` resamples to 16k mono in the core, so capturers may
/// deliver any sample rate / channel count.
protocol AudioSource: AnyObject {
    /// Begin delivering frames for `channelId`. `sink` is the engine push.
    func start(channelId: String, sink: @escaping (_ pcm: [Int16], _ sampleRate: UInt32, _ channels: UInt8) -> Void) throws
    func stop()
    var isRunning: Bool { get }
}

/// Optional channel for sources that can fail asynchronously after start.
protocol AudioSourceFailureReporting: AnyObject {
    var failureHandler: ((Error) -> Void)? { get set }
}

/// Источник, умеющий стартовать БЕЗ блокировки вызывающего потока.
///
/// Нужен системному звуку: ScreenCaptureKit/TCC могут думать секунды, а
/// синхронный `AudioSource.start` вызывается с главного актора — раньше это
/// давало заметный фриз UI (ожидание семафора до 10 с).
protocol AsyncStartAudioSource: AudioSource {
    func startAsync(channelId: String,
                    sink: @escaping (_ pcm: [Int16], _ sampleRate: UInt32,
                                     _ channels: UInt8) -> Void) async throws
}

/// Статус разрешения на микрофон (seam поверх AVFoundation).
enum MicPermissionStatus: Equatable {
    case authorized
    case notDetermined
    case denied
}

/// Провайдер разрешения микрофона. Production — AVFoundation; тесты
/// подставляют детерминированную реализацию без TCC.
@MainActor
protocol MicPermissionProviding: AnyObject {
    var status: MicPermissionStatus { get }
    /// Запрашивает доступ. Completion вызывается на главном потоке.
    func request(_ completion: @escaping (Bool) -> Void)
}

/// Провайдер «доступ уже есть». Подставляется, когда захват подменён тестовым
/// double'ом: реального микрофона в таком прогоне нет, и статус TCC хоста
/// (Terminal/Xcode) не должен влиять на поведенческие тесты lifecycle.
@MainActor
final class GrantedMicPermission: MicPermissionProviding {
    var status: MicPermissionStatus { .authorized }
    func request(_ completion: @escaping (Bool) -> Void) { completion(true) }
}

/// Реальная реализация поверх `AVCaptureDevice`. Запрос доступа асинхронный:
/// главный поток не блокируется на время TCC-диалога.
@MainActor
final class SystemMicPermission: MicPermissionProviding {
    var status: MicPermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    func request(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }
}

/// Контракт аудиосессии, который использует `Engine`. Реальная реализация —
/// `CaptureManager`; отдельный протокол оставляет lifecycle тестируемым без
/// TCC-разрешений и физических устройств.
@MainActor
protocol CaptureControlling: AnyObject {
    var running: Bool { get }
    func start(captureMic: Bool, captureSystem: Bool, generation: UInt) throws
    func stop()
}

/// Optional failure channel kept separate from CaptureControlling so existing
/// test doubles remain source-compatible.
@MainActor
protocol CaptureFailureReporting: AnyObject {
    var failureHandler: ((Error, UInt) -> Void)? { get set }
}

/// Канал НЕфатальных проблем захвата: один источник не поднялся, но сессия
/// продолжается на оставшихся. Отделён от `failureHandler`, потому что тот
/// означает «конвейер мёртв, перезапустите приложение».
@MainActor
protocol CaptureDegradationReporting: AnyObject {
    var degradationHandler: ((Error, UInt) -> Void)? { get set }
}

/// Coordinates the mic + system-audio sources for a capture session.
/// OWNER: audio agent. The mic source uses AVAudioEngine; the system source
/// uses Core Audio process taps (macOS 14.4+) or ScreenCaptureKit, with a
/// BlackHole device fallback. This skeleton compiles and is wired to Engine;
/// the agent implements the concrete sources.
@MainActor
final class CaptureManager: CaptureControlling, CaptureFailureReporting,
                            CaptureDegradationReporting {
    private weak var engine: Engine?
    private let micFactory: () -> AudioSource
    private let systemFactory: () -> AudioSource
    private var micSource: AudioSource?
    private var systemSource: AudioSource?
    private(set) var running = false
    var failureHandler: ((Error, UInt) -> Void)?
    var degradationHandler: ((Error, UInt) -> Void)?
    private var activeGeneration: UInt?
    /// Незавершённый асинхронный старт системного источника.
    private var systemStartTask: Task<Void, Never>?

    /// Создаёт координатор захвата. Фабрики нужны только для поведенческих
    /// тестов rollback/retry; production использует реальные источники.
    init(
        engine: Engine? = nil,
        micFactory: @escaping () -> AudioSource = { MicSource() },
        systemFactory: @escaping () -> AudioSource = { SystemAudioSource() }
    ) {
        self.engine = engine
        self.micFactory = micFactory
        self.systemFactory = systemFactory
    }

    /// Start both sources, routing frames to the engine channels.
    func start(captureMic: Bool, captureSystem: Bool, generation: UInt) throws {
        let engine = self.engine
        // Повторный start уже активной сессии — no-op. Это также защищает от
        // повторной установки AVAudio tap при двойном клике/повторной попытке.
        guard !running else { return }

        // Добавляем источник в rollback-список ДО вызова start: конкретная
        // реализация могла успеть выделить ресурс и бросить ошибку.
        var started: [AudioSource] = []
        var pendingAsyncSystem: AsyncStartAudioSource?
        do {
            if captureMic {
                let src = micFactory()
                started.append(src)
                attachFailureHandler(to: src, generation: generation)
                try src.start(channelId: Engine.micChannel) { [weak engine] pcm, sr, ch in
                    engine?.pushFrame(channel: Engine.micChannel, pcm: pcm, sampleRate: sr,
                                      channels: ch, generation: generation)
                }
                micSource = src
            }
            if captureSystem {
                let src = systemFactory()
                attachFailureHandler(to: src, generation: generation)
                if let asyncSource = src as? AsyncStartAudioSource {
                    // Системный звук стартуем без блокировки главного потока;
                    // ошибка приходит отдельным каналом (см. `scheduleSystemStart`).
                    systemSource = src
                    pendingAsyncSystem = asyncSource
                } else {
                    started.append(src)
                    try src.start(channelId: Engine.remoteChannel) { [weak engine] pcm, sr, ch in
                        engine?.pushFrame(channel: Engine.remoteChannel, pcm: pcm, sampleRate: sr,
                                          channels: ch, generation: generation)
                    }
                    systemSource = src
                }
            }
            running = true
            activeGeneration = generation
        } catch {
            // Откат в обратном порядке запускает release зависимостей (сначала
            // system tap, затем mic tap) и гарантирует чистую retry-сессию.
            for source in started.reversed() {
                detachFailureHandler(from: source)
                source.stop()
            }
            micSource = nil
            systemSource = nil
            running = false
            throw error
        }
        if let pendingAsyncSystem {
            scheduleSystemStart(pendingAsyncSystem, generation: generation)
        }
    }

    /// Запускает системный источник вне синхронного пути старта.
    ///
    /// Сессия уже считается активной: микрофон пишет, а системный звук
    /// подключается, когда ScreenCaptureKit/Core Audio ответят. Ошибка старта
    /// — деградация (запись продолжается на микрофоне); если системный звук
    /// был ЕДИНСТВЕННЫМ источником, это уже полноценный сбой захвата.
    private func scheduleSystemStart(_ source: AsyncStartAudioSource, generation: UInt) {
        let engine = self.engine
        systemStartTask?.cancel()
        systemStartTask = Task { [weak self] in
            do {
                try await source.startAsync(channelId: Engine.remoteChannel) { [weak engine] pcm, sr, ch in
                    engine?.pushFrame(channel: Engine.remoteChannel, pcm: pcm, sampleRate: sr,
                                      channels: ch, generation: generation)
                }
            } catch {
                guard let self, self.activeGeneration == generation else {
                    source.stop()
                    return
                }
                self.systemStartTask = nil
                self.detachFailureHandler(from: source)
                source.stop()
                if self.systemSource === source { self.systemSource = nil }
                if self.micSource == nil {
                    self.failureHandler?(error, generation)
                } else {
                    self.degradationHandler?(error, generation)
                }
                return
            }
            // Сессию могли остановить, пока поднимался поток: тогда источник
            // уже отвязан и его нужно закрыть, а не оставлять «висеть».
            guard let self, self.activeGeneration == generation else {
                source.stop()
                return
            }
            self.systemStartTask = nil
        }
    }

    func stop() {
        // Idempotent: ссылки обнуляются после первого вызова, поэтому второй
        // stop не вызывает повторный removeTap/destroy aggregate device.
        activeGeneration = nil
        systemStartTask?.cancel()
        systemStartTask = nil
        if let source = systemSource {
            detachFailureHandler(from: source)
            source.stop()
        }
        systemSource = nil
        if let source = micSource {
            detachFailureHandler(from: source)
            source.stop()
        }
        micSource = nil
        running = false
    }

    private func attachFailureHandler(to source: AudioSource, generation: UInt) {
        guard let reporting = source as? AudioSourceFailureReporting else { return }
        reporting.failureHandler = { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.activeGeneration == generation else { return }
                self.failureHandler?(error, generation)
            }
        }
    }

    private func detachFailureHandler(from source: AudioSource) {
        (source as? AudioSourceFailureReporting)?.failureHandler = nil
    }
}

// MARK: - Errors

/// Errors surfaced by the concrete audio sources. Messages are user-facing and
/// localized (см. каталог строк), so the UI can present them directly.
enum AudioCaptureError: LocalizedError {
    case micPermissionDenied
    /// Разрешение ещё не спрашивали. Запрос делает Engine ДО старта захвата,
    /// асинхронно: блокировать главный поток семафором нельзя.
    case micPermissionNotDetermined
    case systemAudioUnavailable(reason: String)
    case engineStartFailed(underlying: Error)
    case inputDeviceLost(reason: String)
    case osStatus(stage: String, code: Int32)

    /// Глубокая ссылка на раздел «Конфиденциальность → Микрофон» Системных
    /// настроек — UI может открыть её одной кнопкой.
    static let micPrivacySettingsURL =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"

    var errorDescription: String? {
        switch self {
        case .micPermissionDenied:
            return L("error.audio.micDenied")
        case .micPermissionNotDetermined:
            return L("error.audio.micNotDetermined")
        case let .systemAudioUnavailable(reason):
            return L("error.audio.systemUnavailable", reason)
        case let .engineStartFailed(underlying):
            return L("error.audio.engineStart", underlying.localizedDescription)
        case let .inputDeviceLost(reason):
            return L("error.audio.inputLost", reason)
        case let .osStatus(stage, code):
            // Код печатаем СТРОКОЙ: числовой формат под локалью добавил бы
            // разделитель разрядов («-10 851»), а это не число, а идентификатор.
            return L("error.audio.osStatus", stage, String(code))
        }
    }
}

// MARK: - PCM conversion helpers

enum PCMConvert {
    /// Convert any interleaved/non-interleaved AVAudioPCMBuffer to interleaved
    /// Int16. The frames stay at the buffer's native sample rate and channel
    /// count — the core resamples downstream. `scratch` is reused across calls
    /// to avoid per-callback heap churn in the realtime thread.
    static func toInt16(_ buffer: AVAudioPCMBuffer, scratch: inout [Int16]) -> ([Int16], UInt32, UInt8)? {
        let format = buffer.format
        let channels = Int(format.channelCount)
        let frames = Int(buffer.frameLength)
        guard frames > 0, channels > 0 else { return nil }
        let total = frames * channels
        if scratch.count < total { scratch = [Int16](repeating: 0, count: total) }

        switch format.commonFormat {
        case .pcmFormatInt16:
            // Already Int16. Interleave if needed.
            guard let chans = buffer.int16ChannelData else { return nil }
            if format.isInterleaved {
                scratch.withUnsafeMutableBufferPointer { dst in
                    dst.baseAddress!.update(from: chans[0], count: total)
                }
            } else {
                scratch.withUnsafeMutableBufferPointer { dst in
                    for c in 0..<channels {
                        let src = chans[c]
                        for f in 0..<frames { dst[f * channels + c] = src[f] }
                    }
                }
            }
        case .pcmFormatFloat32:
            guard let chans = buffer.floatChannelData else { return nil }
            scratch.withUnsafeMutableBufferPointer { dst in
                if format.isInterleaved {
                    let src = chans[0]
                    for i in 0..<total { dst[i] = clampToInt16(src[i]) }
                } else {
                    for c in 0..<channels {
                        let src = chans[c]
                        for f in 0..<frames { dst[f * channels + c] = clampToInt16(src[f]) }
                    }
                }
            }
        default:
            return nil
        }
        return (Array(scratch[0..<total]), UInt32(format.sampleRate), UInt8(channels))
    }

    @inline(__always)
    static func clampToInt16(_ sample: Float) -> Int16 {
        let scaled = sample * 32767.0
        if scaled >= 32767.0 { return 32767 }
        if scaled <= -32768.0 { return -32768 }
        return Int16(scaled)
    }
}

// MARK: - Microphone source (AVAudioEngine)

/// Microphone capture via `AVAudioEngine`. Installs a tap on the input node and
/// forwards Int16 PCM (at the device's native rate/channels) to `sink`. The
/// core handles resampling to 16k mono.
final class MicSource: AudioSource, AudioSourceFailureReporting {
    private let engine = AVAudioEngine()
    private var tapInstalled = false
    private var scratch = [Int16]()
    private(set) var isRunning = false
    var failureHandler: ((Error) -> Void)?
    /// Сохраняем sink: при смене устройства ввода tap ставится заново.
    private var sink: (([Int16], UInt32, UInt8) -> Void)?
    /// Токен подписки на смену конфигурации движка (доставка на главную
    /// очередь, чтобы переустановка tap не гонялась со `stop()`).
    private var configObserver: NSObjectProtocol?

    func start(channelId: String, sink: @escaping ([Int16], UInt32, UInt8) -> Void) throws {
        guard !isRunning else { return }
        try Self.ensureMicPermission()
        self.sink = sink

        // Recover from route changes / hardware config changes by reinstalling
        // the tap with the NEW input format (см. `handleConfigChange`).
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.handleConfigChange()
        }

        do {
            try installTapAndStart()
        } catch {
            cleanup()
            self.sink = nil
            throw error
        }
        isRunning = true
    }

    func stop() {
        cleanup()
        sink = nil
        isRunning = false
    }

    /// Ставит tap на актуальный формат входа и запускает движок.
    /// Формат читается КАЖДЫЙ раз: у нового устройства другой rate/channels.
    private func installTapAndStart() throws {
        guard let sink else {
            throw AudioCaptureError.inputDeviceLost(reason: L("error.audio.reason.noSink"))
        }
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        // A zero sample rate means the input node has no usable device.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioCaptureError.systemAudioUnavailable(
                reason: L("error.audio.reason.micUnavailable"))
        }

        input.installTap(onBus: 0, bufferSize: 4800, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            if let (pcm, sr, ch) = PCMConvert.toInt16(buffer, scratch: &self.scratch) {
                sink(pcm, sr, ch)
            }
        }
        tapInstalled = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw AudioCaptureError.engineStartFailed(underlying: error)
        }
    }

    private func cleanup() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        NotificationCenter.default.removeObserver(self)
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
    }

    /// Смена устройства ввода (наушники, док, отключение микрофона).
    ///
    /// Формат `inputNode` при этом меняется, а старый tap остаётся привязан к
    /// прежнему формату — раньше движок просто перезапускался и захват тихо
    /// умирал. Теперь tap снимается, формат перечитывается, tap ставится
    /// заново; при неудаче честно сообщаем через `failureHandler`, чтобы
    /// watchdog Engine не ждал молча.
    private func handleConfigChange() {
        guard isRunning else { return }
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        do {
            try installTapAndStart()
        } catch {
            cleanup()
            isRunning = false
            let failure = (error as? AudioCaptureError)
                ?? AudioCaptureError.engineStartFailed(underlying: error)
            failureHandler?(failure)
        }
    }

    /// Проверяет разрешение микрофона БЕЗ блокировки потока.
    ///
    /// Сам запрос делает Engine (асинхронно) до старта захвата: раньше здесь
    /// висел `sema.wait()` на главном потоке, и весь UI замирал на время
    /// TCC-диалога.
    static func ensureMicPermission() throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            throw AudioCaptureError.micPermissionNotDetermined
        default:
            throw AudioCaptureError.micPermissionDenied
        }
    }
}

// MARK: - System audio source (path selection)

/// System audio capture. Chooses the best available backend:
///   * macOS 14.4+: Core Audio process tap (`ProcessTapSource`) — requires the
///     "System Audio Recording" TCC permission.
///   * macOS 13.0–14.3: ScreenCaptureKit (`ScreenCaptureSource`) — requires the
///     "Screen Recording" TCC permission.
/// If the primary backend throws at start, it falls back to the other one
/// (when available) before surfacing an error.
final class SystemAudioSource: AudioSource, AudioSourceFailureReporting, AsyncStartAudioSource {
    private var backend: AudioSource?
    var failureHandler: ((Error) -> Void)?
    var isRunning: Bool { backend?.isRunning ?? false }

    func start(channelId: String, sink: @escaping ([Int16], UInt32, UInt8) -> Void) throws {
        var lastError = tryProcessTap(channelId: channelId, sink: sink)
        if backend != nil { return }

        // Fallback (or primary on 13.x–14.3): ScreenCaptureKit.
        do {
            let sck = makeScreenCaptureSource()
            try sck.start(channelId: channelId, sink: sink)
            backend = sck
            return
        } catch {
            lastError = error
        }
        throw Self.startFailure(lastError)
    }

    /// Асинхронный путь старта (production): ScreenCaptureKit ожидается через
    /// `await`, поэтому главный поток не блокируется на время TCC/переговоров.
    func startAsync(channelId: String,
                    sink: @escaping ([Int16], UInt32, UInt8) -> Void) async throws {
        var lastError = tryProcessTap(channelId: channelId, sink: sink)
        if backend != nil { return }

        do {
            let sck = makeScreenCaptureSource()
            try await sck.startAsync(channelId: channelId, sink: sink)
            backend = sck
            return
        } catch {
            lastError = error
        }
        throw Self.startFailure(lastError)
    }

    /// Пробует Core Audio process tap (macOS 14.4+). Возвращает ошибку, если
    /// путь недоступен; при успехе `backend` уже выставлен.
    private func tryProcessTap(channelId: String,
                               sink: @escaping ([Int16], UInt32, UInt8) -> Void) -> Error? {
        guard #available(macOS 14.4, *) else { return nil }
        do {
            let tap = ProcessTapSource()
            tap.failureHandler = { [weak self] error in self?.reportFailure(error) }
            try tap.start(channelId: channelId, sink: sink)
            backend = tap
            return nil
        } catch {
            return error
        }
    }

    private func makeScreenCaptureSource() -> ScreenCaptureSource {
        let sck = ScreenCaptureSource()
        sck.failureHandler = { [weak self] error in self?.reportFailure(error) }
        return sck
    }

    private static func startFailure(_ error: Error?) -> Error {
        if let error = error as? AudioCaptureError { return error }
        return AudioCaptureError.systemAudioUnavailable(
            reason: error?.localizedDescription ?? L("error.audio.reason.noMechanism"))
    }

    func stop() {
        (backend as? AudioSourceFailureReporting)?.failureHandler = nil
        backend?.stop()
        backend = nil
    }

    /// Screen/Core Audio delegates may invoke this on arbitrary queues; hop
    /// before touching the handler owned by the MainActor CaptureManager.
    private func reportFailure(_ error: Error) {
        Task { @MainActor [weak self] in self?.failureHandler?(error) }
    }
}
