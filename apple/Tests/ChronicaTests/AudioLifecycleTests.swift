import XCTest
import ScreenCaptureKit
import TranscriberCore
@testable import Chronica

/// Тестовые double'ы lifecycle-аудио. Реальные AVAudio/ScreenCaptureKit/TCC не
/// нужны: проверяем только rollback, retry и bounded ожидание.
@MainActor
final class AudioLifecycleTests: XCTestCase {

    func testCaptureManagerRollsBackPartialStartInReverseOrder() {
        let eventLog = EventLog()
        let mic = TestAudioSource(name: "mic", eventLog: eventLog)
        let system = TestAudioSource(name: "system", eventLog: eventLog, startError: TestError.failed)
        let manager = CaptureManager(
            micFactory: { mic },
            systemFactory: { system })

        XCTAssertThrowsError(try manager.start(captureMic: true, captureSystem: true, generation: 1))
        XCTAssertFalse(manager.running)
        XCTAssertFalse(mic.isRunning)
        XCTAssertFalse(system.isRunning)
        XCTAssertEqual(eventLog.values, ["mic.start", "system.start", "system.stop", "mic.stop"])
        XCTAssertEqual(mic.stopCalls, 1)
        XCTAssertEqual(system.stopCalls, 1)
    }

    func testCaptureManagerRetryAfterFailureStartsFreshSourcesAndStopIsIdempotent() throws {
        var micSources: [TestAudioSource] = []
        var systemSources: [TestAudioSource] = []
        var systemAttempt = 0
        let manager = CaptureManager(
            micFactory: {
                let source = TestAudioSource(name: "mic")
                micSources.append(source)
                return source
            },
            systemFactory: {
                systemAttempt += 1
                let source = TestAudioSource(
                    name: "system",
                    startError: systemAttempt == 1 ? TestError.failed : nil)
                systemSources.append(source)
                return source
            })

        XCTAssertThrowsError(try manager.start(captureMic: true, captureSystem: true, generation: 1))
        XCTAssertFalse(manager.running)
        XCTAssertEqual(micSources.count, 1)
        XCTAssertEqual(systemSources.count, 1)
        XCTAssertEqual(micSources[0].stopCalls, 1)

        try manager.start(captureMic: true, captureSystem: true, generation: 2)
        XCTAssertTrue(manager.running)
        XCTAssertEqual(micSources.count, 2)
        XCTAssertEqual(systemSources.count, 2)
        XCTAssertTrue(micSources[1].isRunning)
        XCTAssertTrue(systemSources[1].isRunning)
        XCTAssertFalse(micSources[0].isRunning)

        manager.stop()
        manager.stop()
        XCTAssertFalse(manager.running)
        XCTAssertEqual(micSources[1].stopCalls, 1)
        XCTAssertEqual(systemSources[1].stopCalls, 1)
    }

    func testEngineCaptureFailureStopsCoreAndRetryDoesNotDuplicateCapture() async throws {
        let core = TestCore()
        let capture = TestCapture()
        capture.failNextStart = true
        let engine = makeWatchdogEngine(core: core, captureFactory: { capture })

        engine.loadModelAndStart()
        await waitUntil {
            capture.startCalls == 1 && core.stopCalls == 1 && engine.state == .error
        }
        XCTAssertEqual(core.loadCalls, 1)
        XCTAssertEqual(core.startCalls, 1)
        XCTAssertEqual(core.stopCalls, 1)
        XCTAssertEqual(capture.stopCalls, 1)
        XCTAssertFalse(capture.running)
        XCTAssertEqual(engine.state, .error)
        XCTAssertEqual(engine.lastError,
                       L("error.audioPrefix", Engine.humanMessage(TestError.failed)),
                       "сбой захвата обязан быть помечен как аудио-ошибка")

        capture.failNextStart = false
        engine.loadModelAndStart()
        await waitUntil { engine.state == .recording }
        XCTAssertEqual(capture.startCalls, 2)
        XCTAssertEqual(core.loadCalls, 2)
        XCTAssertEqual(core.startCalls, 2)
        XCTAssertTrue(capture.running)

        engine.stop()
        await waitUntil { engine.state == .idle }
        let stopCallsAfterFirstStop = core.stopCalls
        engine.stop()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(core.stopCalls, stopCallsAfterFirstStop)
        XCTAssertFalse(capture.running)
    }

    func testEngineStopDuringStartBlocksRetryUntilStaleStartSettles() async throws {
        let entered = ThreadSafeFlag()
        let release = DispatchSemaphore(value: 0)
        let core = TestCore(startGate: release, startEntered: entered)
        let capture = TestCapture()
        let engine = makeWatchdogEngine(core: core, captureFactory: { capture })

        engine.loadModelAndStart()
        await waitUntil { entered.value }

        // The first detached start is still inside core.start(). Stop must
        // invalidate it, and an immediate retry must not launch a second
        // load/start task against the same core.
        engine.stop()
        XCTAssertEqual(engine.state, .idle)
        engine.loadModelAndStart()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(core.startCalls, 1)

        release.signal()
        await waitUntil { core.stopCalls == 1 && engine.state == .idle }

        // Once the stale operation has settled, retry starts a fresh session.
        engine.loadModelAndStart()
        await waitUntil { engine.state == .recording }
        XCTAssertEqual(core.startCalls, 2)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(core.stopCalls, 1)

        engine.stop()
        await waitUntil { engine.state == .idle }
        XCTAssertEqual(core.stopCalls, 2)
    }

    func testEngineStopDuringPreviousStopWaitPreventsStaleRetryStart() async throws {
        let stopEntered = ThreadSafeFlag()
        let releaseStop = DispatchSemaphore(value: 0)
        let core = TestCore(stopGate: releaseStop, stopEntered: stopEntered)
        let capture = TestCapture()
        capture.failNextStart = true
        let engine = makeWatchdogEngine(core: core, captureFactory: { capture })

        engine.loadModelAndStart()
        await waitUntil { engine.state == .error }
        await waitUntil { stopEntered.value }

        // Retry is waiting for the first failed session's core.stop(). Stop
        // during that wait must invalidate the retry before loadModel/start.
        capture.failNextStart = false
        engine.loadModelAndStart()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(core.startCalls, 1)
        engine.stop()
        releaseStop.signal()
        await waitUntil { engine.state == .idle }
        XCTAssertEqual(core.startCalls, 1)
        XCTAssertEqual(core.stopCalls, 1)
    }

    func testScreenCaptureStartHasBoundedTimeoutWithoutTCC() async {
        let cancelled = ThreadSafeFlag()
        let source = ScreenCaptureSource(
            startTimeout: 0.05,
            startOperation: {
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } catch {
                    cancelled.set()
                    throw error
                }
                return Optional<SCStream>.none
            })
        let began = Date()

        XCTAssertThrowsError(try source.start(channelId: "remote", sink: { _, _, _ in })) { error in
            guard case let AudioCaptureError.systemAudioUnavailable(reason) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(reason, L("error.audio.reason.sckTimeout", 0))
        }
        // Проверяем ОГРАНИЧЕННОСТЬ ожидания, а не его точную длительность:
        // порог заведомо ниже 2с, которые проспала бы операция без таймаута,
        // но с запасом на планировщик медленного раннера.
        XCTAssertLessThan(Date().timeIntervalSince(began), 1.5)
        await waitUntil { cancelled.value }
        XCTAssertFalse(source.isRunning)
        source.stop()
        source.stop()
    }

    func testScreenCaptureStartRejectsSuccessfulNilStream() {
        let source = ScreenCaptureSource(startTimeout: 0.2, startOperation: { nil })

        XCTAssertThrowsError(try source.start(channelId: "remote", sink: { _, _, _ in })) { error in
            guard case let AudioCaptureError.systemAudioUnavailable(reason) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(reason, L("error.audio.reason.sckNoStream"))
        }
        XCTAssertFalse(source.isRunning)
    }

    func testWatchdogStopsCaptureWhenMetricsFreeze() async throws {
        let watchdog = TestWatchdogClock()
        let core = TestCore()
        let capture = TestCapture()
        let engine = makeWatchdogEngine(core: core, captureFactory: { capture },
                                        watchdog: watchdog)

        engine.loadModelAndStart()
        await waitUntil { engine.state == .recording }
        // Пока часы стоят, сторож молчит: сессия успевает встать на ноги, а не
        // гибнет от того, что раннер задумался между двумя строчками теста.
        XCTAssertFalse(engine.pipelineStalled)

        // Ни одной метрики за время больше таймаута — вот это зависание.
        watchdog.advance(13)
        await waitUntil { engine.pipelineStalled }

        XCTAssertTrue(engine.needsRestart)
        XCTAssertEqual(engine.state, .error)
        XCTAssertFalse(capture.running)
        XCTAssertGreaterThanOrEqual(capture.stopCalls, 1)
        XCTAssertEqual(engine.lastError,
                       L("error.pipelineStalled", L("stall.noMetrics")))
    }

    func testWatchdogAcceptsFreshProgressWithoutFalseStall() async throws {
        let watchdog = TestWatchdogClock()
        let core = TestCore()
        let capture = TestCapture()
        let engine = makeWatchdogEngine(core: core, captureFactory: { capture },
                                        watchdog: watchdog)
        engine.loadModelAndStart()
        await waitUntil { engine.state == .recording }

        // Десять проверок сторожа. Каждая видит метрику возрастом 5 виртуальных
        // секунд — МЕНЬШЕ таймаута 12с, — а суммарно проходит 50с, вчетверо
        // больше таймаута. Если бы свежая метрика не считалась признаком жизни,
        // возраст перевалил бы за 12с и сторож соврал бы на третьем шаге.
        for index in 0..<10 {
            let wakeupsBefore = watchdog.wakeups
            engine.receive(.metrics(snapshot: Self.snapshot(elapsed: Float(index))))
            watchdog.advance(5)
            await waitForWatchdogCheck(watchdog, after: wakeupsBefore)
            XCTAssertFalse(engine.pipelineStalled,
                           "свежая метрика на шаге \(index) не должна читаться как зависание")
        }
        XCTAssertEqual(engine.state, .recording)

        // Контроль настройки: сторож всё это время был вооружён и живым —
        // стоит метрикам замолчать дольше таймаута, он срабатывает. Без этой
        // проверки «нет ложного зависания» доказывалось бы и выключенным
        // сторожем.
        watchdog.advance(13)
        await waitUntil { engine.pipelineStalled }
        engine.stop()
    }

    func testTransientQueueFullWarningKeepsRecordingAndCapture() async throws {
        let watchdog = TestWatchdogClock()
        let core = TestCore()
        let capture = TestCapture()
        let engine = makeWatchdogEngine(core: core, captureFactory: { capture },
                                        watchdog: watchdog)
        engine.loadModelAndStart()
        await waitUntil { engine.state == .recording }
        let generation = try XCTUnwrap(engine.sessionGenerationForTesting)

        engine.receive(.error(code: .internal, message: "ASR queue full; interval dropped"),
                       generation: generation)

        // Очередь тут же разгружается, и дальше пульс идёт с незаполненной
        // очередью. Виртуального времени проходит 50с — вчетверо больше
        // таймаута: разовое предупреждение не имеет права накопиться в стоп.
        for _ in 0..<10 {
            let wakeupsBefore = watchdog.wakeups
            engine.receive(.metrics(snapshot: Self.snapshot(elapsed: 0, queueDepth: 0)),
                           generation: generation)
            watchdog.advance(5)
            await waitForWatchdogCheck(watchdog, after: wakeupsBefore)
        }

        XCTAssertEqual(engine.state, .recording)
        XCTAssertTrue(capture.running)
        XCTAssertFalse(engine.pipelineStalled)
        XCTAssertFalse(engine.needsRestart)
        XCTAssertEqual(engine.lastError, L("error.queueDrop", 1))
        engine.stop()
    }

    func testSustainedQueueFullStopsCaptureAfterMonotonicDeadline() async throws {
        let watchdog = TestWatchdogClock()
        let core = TestCore()
        let capture = TestCapture()
        let engine = makeWatchdogEngine(core: core, captureFactory: { capture },
                                        watchdog: watchdog)
        engine.loadModelAndStart()
        await waitUntil { engine.state == .recording }
        let generation = try XCTUnwrap(engine.sessionGenerationForTesting)
        engine.receive(.error(code: .internal, message: "ASR queue full; interval dropped"),
                       generation: generation)

        // Пульс продолжает идти (метрика свежая, возраст 0), но очередь всё
        // это время забита под завязку. Это зависание ASR, а не пропажа
        // heartbeat'а воркера, — и ловится оно по своему сроку.
        watchdog.advance(13)
        engine.receive(.metrics(snapshot: Self.snapshot(elapsed: 0, queueDepth: 4)),
                       generation: generation)

        await waitUntil { engine.pipelineStalled }
        XCTAssertTrue(engine.needsRestart)
        XCTAssertFalse(capture.running)
        XCTAssertEqual(engine.lastError,
                       L("error.pipelineStalled", L("stall.queueSaturated")),
                       "причина обязана быть «очередь», а не «нет метрик»")
    }

    func testWatchdogUsesMonotonicClockInsteadOfWallClock() async throws {
        var wall = Date()
        let watchdog = TestWatchdogClock()
        let core = TestCore()
        let capture = TestCapture()
        let engine = makeWatchdogEngine(core: core, captureFactory: { capture },
                                        watchdog: watchdog, clock: { wall })
        engine.loadModelAndStart()
        await waitUntil { engine.state == .recording }

        // Скачок СТЕННЫХ часов (перевод времени, возврат из сна) не должен
        // выглядеть зависанием: монотонные часы не сдвинулись. Дожидаемся
        // именно факта проверки сторожем, а не «прошло сколько-то времени».
        let wakeupsBefore = watchdog.wakeups
        wall = wall.addingTimeInterval(86_400)
        await waitForWatchdogCheck(watchdog, after: wakeupsBefore)
        XCTAssertFalse(engine.pipelineStalled)

        // А ход МОНОТОННЫХ часов за таймаут — уже зависание.
        watchdog.advance(13)
        await waitUntil { engine.pipelineStalled }
    }

    func testStaleStateEventCannotOverwriteActiveRecording() async throws {
        let core = TestCore()
        let capture = TestCapture()
        let engine = makeWatchdogEngine(core: core, captureFactory: { capture })
        engine.loadModelAndStart()
        await waitUntil { engine.state == .recording }

        // Both an untagged late idle and an explicitly old generation are
        // rejected while the new session is active.
        engine.receive(.stateChanged(state: .idle))
        engine.receive(.stateChanged(state: .idle), generation: 0)
        XCTAssertEqual(engine.state, .recording)
        engine.stop()
        await waitUntil { engine.state == .idle }

        engine.loadModelAndStart()
        await waitUntil { engine.state == .recording }
        // A delayed idle from the first session must not switch the second
        // session back to idle.
        engine.receive(.stateChanged(state: .idle))
        XCTAssertEqual(engine.state, .recording)
        engine.stop()
    }

    func testVoiceActivityBumpsRevisionAndFeedIsResetOnNewSession() async throws {
        let core = TestCore()
        let capture = TestCapture()
        let engine = makeWatchdogEngine(core: core, captureFactory: { capture })
        engine.loadModelAndStart()
        await waitUntil { engine.state == .recording }
        let before = engine.activityRevision
        engine.receive(.voiceActivity(channelId: Engine.micChannel,
                                      at: Fmt.queryBound(Date().addingTimeInterval(1))))
        XCTAssertGreaterThan(engine.activityRevision, before)

        let when = Fmt.queryBound(Date().addingTimeInterval(1))
        engine.receive(.intervalCommitted(interval: IntervalRecord(
            id: 1, startAt: when, endAt: when, durationS: 1, channels: [])))
        XCTAssertEqual(engine.liveFeed.count, 1)
        engine.stop()
        await waitUntil { engine.state == .idle }

        engine.loadModelAndStart()
        await waitUntil { engine.state == .recording }
        XCTAssertTrue(engine.liveFeed.isEmpty)
        engine.stop()
    }

    func testCoreSinkDropsFramesOutsideActiveSession() async throws {
        let core = TestCore()
        let capture = TestCapture()
        let engine = makeWatchdogEngine(core: core, captureFactory: { capture })
        engine.pushFrame(channel: Engine.micChannel, pcm: [1], sampleRate: 16_000, channels: 1)
        XCTAssertEqual(core.pushCalls, 0)

        engine.loadModelAndStart()
        await waitUntil { engine.state == .recording }
        engine.pushFrame(channel: Engine.micChannel, pcm: [1], sampleRate: 16_000, channels: 1)
        XCTAssertEqual(core.pushCalls, 1)
        engine.stop()
        await waitUntil { engine.state == .idle }
        engine.pushFrame(channel: Engine.micChannel, pcm: [1], sampleRate: 16_000, channels: 1)
        XCTAssertEqual(core.pushCalls, 1)
    }

    func testAsyncCaptureFailureUsesSameStallPathAndRestartSeam() async throws {
        let core = TestCore()
        let capture = TestCapture()
        var restarted = false
        // Зависание тут приходит от СБОЯ ЗАХВАТА, а не по сроку: виртуальные
        // часы сторожа так и остаются на нуле.
        let engine = makeWatchdogEngine(core: core, captureFactory: { capture },
                                        restartHandler: { restarted = true })
        engine.loadModelAndStart()
        await waitUntil { engine.state == .recording }
        capture.emitFailure()
        await waitUntil { engine.pipelineStalled }
        engine.restartApplication()
        XCTAssertTrue(restarted)
    }

    func testDelayedOldGenerationCallbacksAreIgnoredAfterRestart() async throws {
        let core = TestCore()
        let capture = TestCapture()
        let engine = makeWatchdogEngine(core: core, captureFactory: { capture })
        engine.loadModelAndStart()
        await waitUntil { engine.state == .recording }
        let oldGeneration = try XCTUnwrap(engine.sessionGenerationForTesting)
        engine.receive(.metrics(snapshot: Self.snapshot(elapsed: 1)), generation: oldGeneration)

        engine.stop()
        await waitUntil { engine.state == .idle }
        engine.loadModelAndStart()
        await waitUntil { engine.state == .recording }
        let newGeneration = try XCTUnwrap(engine.sessionGenerationForTesting)
        engine.receive(.metrics(snapshot: Self.snapshot(elapsed: 2)), generation: newGeneration)
        let currentElapsed = engine.metrics?.currentIntervalElapsedS

        // Late events and audio from the previous session carry its token and
        // must not mutate the new session.
        engine.receive(.error(code: .internal, message: "DSP thread stalled"),
                       generation: oldGeneration)
        engine.receive(.metrics(snapshot: Self.snapshot(elapsed: 99)), generation: oldGeneration)
        capture.emitFailure(generation: oldGeneration)
        engine.pushFrame(channel: Engine.micChannel, pcm: [1], sampleRate: 16_000,
                         channels: 1, generation: oldGeneration)

        XCTAssertEqual(engine.state, .recording)
        XCTAssertFalse(engine.pipelineStalled)
        XCTAssertEqual(engine.metrics?.currentIntervalElapsedS, currentElapsed)
        XCTAssertEqual(core.pushCalls, 0)
        engine.stop()
    }

    func testRelaunchSeamIsIdempotentAndFailureKeepsCurrentProcess() async throws {
        var launchCount = 0
        var completion: ((Bool) -> Void)?
        let core = TestCore()
        let capture = TestCapture()
        let watchdog = TestWatchdogClock()
        let engine = makeWatchdogEngine(core: core, captureFactory: { capture },
                                        watchdog: watchdog,
                                        relaunchHandler: { callback in
                                            launchCount += 1
                                            completion = callback
                                        })
        // Нужно состояние «конвейер встал»: сначала дожидаемся живой сессии,
        // потом СОЗДАЁМ зависание сдвигом виртуальных часов.
        engine.loadModelAndStart()
        await waitUntil { engine.state == .recording }
        watchdog.advance(13)
        await waitUntil { engine.pipelineStalled }

        engine.restartApplication()
        engine.restartApplication()
        XCTAssertEqual(launchCount, 1)
        completion?(false)
        await waitUntil { engine.lastError == L("error.relaunchFailed") }
        XCTAssertTrue(engine.needsRestart)

        engine.restartApplication()
        XCTAssertEqual(launchCount, 2)
        completion?(true)
    }

    // MARK: события вне сессии (прогресс загрузки модели)

    func testModelProgressReachesUIWhileIdleButSessionEventsDoNot() async throws {
        let core = TestCore()
        let capture = TestCapture()
        let engine = makeWatchdogEngine(core: core, captureFactory: { capture })

        // Простой: сессии нет, но скачивание модели идёт и обязано быть видно.
        engine.receive(.modelProgress(status: Self.modelStatus(id: "parakeet", pct: 42)),
                       generation: 7)
        XCTAssertEqual(engine.modelProgress["parakeet"]?.progressPct, 42)
        // Ошибка вне сессии (например, сбой скачивания) тоже доходит.
        engine.receive(.error(code: .internal, message: "no space left on device"),
                       generation: 7)
        XCTAssertEqual(engine.lastError, "no space left on device")
        // Сессионное событие с чужим поколением — нет.
        engine.receive(.metrics(snapshot: Self.snapshot(elapsed: 5)), generation: 7)
        XCTAssertNil(engine.metrics)
    }

    func testModelProgressIsAcceptedDuringRecordingRegardlessOfGeneration() async throws {
        let core = TestCore()
        let capture = TestCapture()
        let engine = makeWatchdogEngine(core: core, captureFactory: { capture })
        engine.loadModelAndStart()
        await waitUntil { engine.state == .recording }

        engine.receive(.modelProgress(status: Self.modelStatus(id: "whisper", pct: 10)),
                       generation: 999)
        XCTAssertEqual(engine.modelProgress["whisper"]?.progressPct, 10)
        XCTAssertEqual(engine.state, .recording)
        engine.stop()
    }

    // MARK: разрешение микрофона

    func testMicPermissionRequestDoesNotBlockStartAndResumesAfterGrant() async throws {
        let core = TestCore()
        let capture = TestCapture()
        let permission = TestMicPermission(status: .notDetermined)
        let engine = makeWatchdogEngine(core: core, captureFactory: { capture },
                                        micPermission: permission)

        engine.loadModelAndStart()
        // Диалог TCC ещё висит: ни ядро, ни захват не стартовали, но вызов
        // вернул управление (главный поток не блокируется).
        XCTAssertEqual(permission.requestCalls, 1)
        XCTAssertEqual(core.startCalls, 0)
        XCTAssertEqual(capture.startCalls, 0)

        permission.resolve(granted: true)
        await waitUntil { engine.state == .recording }
        XCTAssertEqual(capture.startCalls, 1)
        engine.stop()
    }

    func testDeniedMicPermissionShowsActionableErrorInsteadOfStarting() async throws {
        let core = TestCore()
        let capture = TestCapture()
        let permission = TestMicPermission(status: .denied)
        let engine = makeWatchdogEngine(core: core, captureFactory: { capture },
                                        micPermission: permission)

        engine.loadModelAndStart()
        XCTAssertEqual(engine.state, .error)
        XCTAssertEqual(core.startCalls, 0)
        XCTAssertEqual(capture.startCalls, 0)
        XCTAssertEqual(engine.lastError, L("error.audio.micDenied"))
        XCTAssertEqual(permission.requestCalls, 0)
    }

    // MARK: сон / пробуждение

    func testSleepStopsCaptureAndWakeRearmsTheSameSession() async throws {
        let core = TestCore()
        let capture = TestCapture()
        let engine = makeWatchdogEngine(core: core, captureFactory: { capture }, wakeRetryDelayS: 0.01)
        engine.loadModelAndStart()
        await waitUntil { engine.state == .recording }
        let generation = try XCTUnwrap(engine.sessionGenerationForTesting)

        engine.suspendForSleep()
        XCTAssertFalse(capture.running)
        XCTAssertTrue(engine.isSuspendedForSleep)
        // Ядро НЕ останавливаем: иначе хвост текущего интервала теряется.
        XCTAssertEqual(core.stopCalls, 0)
        XCTAssertEqual(engine.state, .recording)

        engine.resumeAfterWake()
        await waitUntil { !engine.isSuspendedForSleep && capture.running }
        XCTAssertEqual(capture.startCalls, 2)
        XCTAssertEqual(engine.sessionGenerationForTesting, generation)
        XCTAssertEqual(engine.state, .recording)
        XCTAssertFalse(engine.pipelineStalled)
        engine.stop()
    }

    func testWakeRetriesThenRestartsSessionInsteadOfStickingInRestartState() async throws {
        let core = TestCore()
        let capture = TestCapture()
        let engine = makeWatchdogEngine(core: core, captureFactory: { capture }, wakeRetryDelayS: 0.01)
        engine.loadModelAndStart()
        await waitUntil { engine.state == .recording }

        engine.suspendForSleep()
        // Устройство после пробуждения поднимается не сразу: все попытки
        // ре-арма падают, и Engine обязан явно перезапустить сессию.
        capture.failStartsRemaining = 3
        engine.resumeAfterWake()
        await waitUntil(timeout: 5) { engine.state == .recording && capture.running }
        XCTAssertFalse(engine.isSuspendedForSleep)
        XCTAssertFalse(engine.needsRestart)
        XCTAssertEqual(core.startCalls, 2)
        engine.stop()
    }

    func testSuspendIsIgnoredWhenNotRecording() {
        let core = TestCore()
        let capture = TestCapture()
        let engine = makeWatchdogEngine(core: core, captureFactory: { capture })
        engine.suspendForSleep()
        XCTAssertFalse(engine.isSuspendedForSleep)
        engine.resumeAfterWake()
        XCTAssertEqual(engine.state, .idle)
    }

    // MARK: тумблеры источников

    func testSourceToggleDuringRecordingRequiresRestartAndIsHonestAboutIt() async throws {
        let core = TestCore()
        let capture = TestCapture()
        let engine = makeWatchdogEngine(core: core, captureFactory: { capture })
        engine.loadModelAndStart()
        await waitUntil { engine.state == .recording }
        XCTAssertFalse(engine.sourceChangeRequiresRestart)
        XCTAssertNil(engine.sourceChangeHint)

        engine.captureSystem = false
        XCTAssertTrue(engine.sourceChangeRequiresRestart)
        XCTAssertNotNil(engine.sourceChangeHint)
        // Возврат к набору активной сессии снимает подсказку.
        engine.captureSystem = true
        XCTAssertFalse(engine.sourceChangeRequiresRestart)

        engine.captureMic = false
        XCTAssertTrue(engine.sourceChangeRequiresRestart)
        engine.stop()
        await waitUntil { engine.state == .idle }
        // Вне записи менять источники можно свободно.
        XCTAssertFalse(engine.sourceChangeRequiresRestart)
        engine.captureMic = true
        XCTAssertFalse(engine.sourceChangeRequiresRestart)
    }

    // MARK: асинхронный старт системного источника

    func testAsyncSystemSourceFailureDegradesWithoutStoppingMicSession() async throws {
        let mic = TestAudioSource(name: "mic")
        let system = TestAsyncAudioSource(startError: TestError.failed)
        let manager = CaptureManager(micFactory: { mic }, systemFactory: { system })
        var degraded = 0
        var fatal = 0
        manager.degradationHandler = { _, _ in degraded += 1 }
        manager.failureHandler = { _, _ in fatal += 1 }

        try manager.start(captureMic: true, captureSystem: true, generation: 1)
        // Микрофон уже пишет: старт не ждал ScreenCaptureKit.
        XCTAssertTrue(manager.running)
        XCTAssertTrue(mic.isRunning)

        await waitUntil { degraded == 1 }
        XCTAssertEqual(fatal, 0)
        XCTAssertTrue(manager.running)
        XCTAssertTrue(mic.isRunning)
        manager.stop()
    }

    func testAsyncSystemSourceFailureIsFatalWhenItIsTheOnlySource() async throws {
        let system = TestAsyncAudioSource(startError: TestError.failed)
        let manager = CaptureManager(micFactory: { TestAudioSource(name: "mic") },
                                     systemFactory: { system })
        var degraded = 0
        var fatal = 0
        manager.degradationHandler = { _, _ in degraded += 1 }
        manager.failureHandler = { _, _ in fatal += 1 }

        try manager.start(captureMic: false, captureSystem: true, generation: 1)
        await waitUntil { fatal == 1 }
        XCTAssertEqual(degraded, 0)
        manager.stop()
    }

    func testAsyncSystemSourceStartedAfterStopIsClosed() async throws {
        let system = TestAsyncAudioSource(startDelayNs: 60_000_000)
        let manager = CaptureManager(micFactory: { TestAudioSource(name: "mic") },
                                     systemFactory: { system })
        try manager.start(captureMic: true, captureSystem: true, generation: 1)
        manager.stop()
        await waitUntil { system.stopCalls >= 1 }
        XCTAssertFalse(system.isRunning)
    }

    private static func modelStatus(id: String, pct: Float) -> ModelStatus {
        ModelStatus(id: id, label: id, family: "parakeet", runtime: "sherpa",
                    installed: false, downloadedBytes: 1, totalBytes: 100,
                    progressPct: pct, downloading: true, lastError: "")
    }

    private static func snapshot(elapsed: Float, queueDepth: UInt32 = 0,
                                 droppedIntervals: UInt32 = 0) -> MetricsSnapshot {
        let source = SourceMetrics(channelId: Engine.micChannel, enabled: true,
                                   status: "listening", queueSize: 0,
                                   droppedChunks: 0, busy: false, lastRtf: 0,
                                   lagEstimateS: 0, words: 0, lastText: "",
                                   lastLanguage: "", speechSeconds: elapsed)
        return MetricsSnapshot(stateRunning: true, stateLoading: false,
                               stateStopping: false, modelLoaded: true,
                               modelName: "test", startedAt: "", lastWriteAt: "",
                               totalWords: 0, totalIntervals: 0, bgQueueDepth: queueDepth,
                               bgQueueCapacity: 4, currentIntervalElapsedS: elapsed,
                               currentIntervalStartAt: "", channelsSilent: false,
                               sources: [source], cpuPercent: 0, cpuP50: 0,
                               cpuP90: 0, memoryRssBytes: 0,
                               memoryRssPeakBytes: 0, lastError: "",
                               droppedIntervals: droppedIntervals)
    }

    /// `Engine`, у которого ВРЕМЯ СТОРОЖА виртуальное.
    ///
    /// Все тесты класса создают движок только так. Часы по умолчанию стоят,
    /// поэтому сторож не может сработать «сам» — ни на быстрой машине, ни на
    /// раннере, который завис на полминуты между двумя строчками теста. Тест,
    /// которому нужен стук сторожа, заводит свой `TestWatchdogClock` и двигает
    /// его `advance` на нужное число ВИРТУАЛЬНЫХ секунд.
    ///
    /// `watchdogTimeoutS` тоже задаётся в виртуальных секундах, поэтому дефолт
    /// оставлен продовым (12с): подгонять его под скорость машины больше незачем.
    @MainActor
    private func makeWatchdogEngine(
        core: TranscriberCore? = nil,
        captureFactory: (() -> CaptureControlling)? = nil,
        watchdog: TestWatchdogClock = TestWatchdogClock(),
        watchdogTimeoutS: TimeInterval = 12,
        clock: @escaping () -> Date = Date.init,
        restartHandler: (() -> Void)? = nil,
        relaunchHandler: ((@escaping (Bool) -> Void) -> Void)? = nil,
        micPermission: MicPermissionProviding? = nil,
        wakeRetryDelayS: TimeInterval = 1.5
    ) -> Engine {
        makeIsolatedEngine(core: core,
                           captureFactory: captureFactory,
                           watchdogTimeoutS: watchdogTimeoutS,
                           watchdogPollS: 0.01,
                           clock: clock,
                           monotonicClock: { watchdog.now },
                           watchdogSleep: { _ in await watchdog.sleep() },
                           restartHandler: restartHandler,
                           relaunchHandler: relaunchHandler,
                           micPermission: micPermission,
                           wakeRetryDelayS: wakeRetryDelayS)
    }

    /// Ждёт, пока сторож ВЫПОЛНИТ хотя бы одну проверку после текущего момента.
    ///
    /// Счётчик снимается синхронно, вместе с изменением виртуальных часов,
    /// поэтому дождавшаяся проверка гарантированно видела новое время. Это
    /// ожидание ФАКТА (асинхронная задача сделала шаг), а не «пока натикает».
    private func waitForWatchdogCheck(_ watchdog: TestWatchdogClock,
                                      after wakeups: Int) async {
        await waitUntil { watchdog.wakeups > wakeups }
    }

    /// Ожидание УСЛОВИЯ с дедлайном (а не фиксированная пауза). Дедлайн — лишь
    /// верхняя граница терпения к планировщику: исход к этому моменту уже
    /// предопределён виртуальными часами, ждём только завершения задач.
    private func waitUntil(
        timeout: TimeInterval = 5,
        _ predicate: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("condition timed out")
    }
}

private enum TestError: Error { case failed }

private final class EventLog {
    var values: [String] = []
}

/// Виртуальные монотонные часы сторожа конвейера.
///
/// Возраст метрик и насыщения очереди `Engine` считает по ЭТИМ часам, а они
/// стоят на месте, пока тест не позовёт `advance`. Отсюда главное свойство:
/// сколько бы реальных секунд ни съел медленный раннер, сторож не может
/// объявить зависание сам по себе — а когда тест двигает время за таймаут,
/// сторож обязан сработать независимо от скорости машины.
///
/// Опрос при этом остаётся настоящей асинхронной задачей: `sleep()` — короткая
/// реальная пауза между проверками. Её длительность на РЕЗУЛЬТАТ не влияет
/// (решение принимается по виртуальным часам), она задаёт только то, как
/// быстро тест дождётся уже предопределённого исхода. `wakeups` позволяет
/// дождаться именно факта очередной проверки, а не «прошло N миллисекунд».
private final class TestWatchdogClock: @unchecked Sendable {
    /// Шаг реального опроса. Мелкий — чтобы тесты не ждали, но не нулевой,
    /// чтобы цикл сторожа не крутился вхолостую на главном акторе.
    private static let pollNs: UInt64 = 2_000_000

    private let lock = NSLock()
    private var nowNs: UInt64 = 0
    private var wakeupCount = 0

    /// Показание виртуальных монотонных часов (наносекунды).
    var now: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return nowNs
    }

    /// Сколько раз сторож уходил спать. Счётчик растёт ПЕРЕД паузой, а очередная
    /// проверка идёт сразу после неё, поэтому рост счётчика с N до N+1 означает
    /// «проверка №N выполнена целиком».
    var wakeups: Int {
        lock.lock(); defer { lock.unlock() }
        return wakeupCount
    }

    /// Двигает виртуальное время вперёд на `seconds`.
    func advance(_ seconds: TimeInterval) {
        lock.lock(); nowNs &+= UInt64(seconds * 1_000_000_000); lock.unlock()
    }

    /// Seam вместо `Task.sleep` в цикле сторожа.
    func sleep() async {
        // Счётчик двигаем отдельным СИНХРОННЫМ методом: брать `NSLock` прямо в
        // async-функции нельзя (в Swift 6 это ошибка).
        noteWakeup()
        try? await Task.sleep(nanoseconds: Self.pollNs)
    }

    private func noteWakeup() {
        lock.lock(); wakeupCount += 1; lock.unlock()
    }
}

private final class ThreadSafeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func set() {
        lock.lock(); storage = true; lock.unlock()
    }
}

private final class TestAudioSource: AudioSource {
    let name: String
    private let eventLog: EventLog?
    let startError: Error?
    private(set) var startCalls = 0
    private(set) var stopCalls = 0
    private(set) var isRunning = false

    init(name: String, eventLog: EventLog? = nil, startError: Error? = nil) {
        self.name = name
        self.eventLog = eventLog
        self.startError = startError
    }

    func start(channelId: String, sink: @escaping ([Int16], UInt32, UInt8) -> Void) throws {
        _ = (channelId, sink)
        startCalls += 1
        appendEvent("\(name).start")
        if let startError { throw startError }
        isRunning = true
    }

    func stop() {
        stopCalls += 1
        appendEvent("\(name).stop")
        isRunning = false
    }

    private func appendEvent(_ event: String) {
        eventLog?.values.append(event)
    }
}

/// Асинхронно стартующий источник (как системный звук в production).
private final class TestAsyncAudioSource: AudioSource, AsyncStartAudioSource, @unchecked Sendable {
    private let lock = NSLock()
    private let startError: Error?
    private let startDelayNs: UInt64
    private var running = false
    private var stops = 0

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    var stopCalls: Int {
        lock.lock(); defer { lock.unlock() }
        return stops
    }

    init(startError: Error? = nil, startDelayNs: UInt64 = 0) {
        self.startError = startError
        self.startDelayNs = startDelayNs
    }

    func start(channelId: String, sink: @escaping ([Int16], UInt32, UInt8) -> Void) throws {
        _ = (channelId, sink)
        if let startError { throw startError }
        lock.lock(); running = true; lock.unlock()
    }

    func startAsync(channelId: String,
                    sink: @escaping ([Int16], UInt32, UInt8) -> Void) async throws {
        _ = (channelId, sink)
        if startDelayNs > 0 { try? await Task.sleep(nanoseconds: startDelayNs) }
        if let startError { throw startError }
        markRunning()
    }

    private func markRunning() {
        lock.lock(); running = true; lock.unlock()
    }

    func stop() {
        lock.lock(); stops += 1; running = false; lock.unlock()
    }
}

/// Разрешение микрофона под контролем теста: `resolve` играет роль ответа
/// пользователя в системном диалоге.
@MainActor
private final class TestMicPermission: MicPermissionProviding {
    private(set) var status: MicPermissionStatus
    private(set) var requestCalls = 0
    private var pending: ((Bool) -> Void)?

    init(status: MicPermissionStatus) {
        self.status = status
    }

    func request(_ completion: @escaping (Bool) -> Void) {
        requestCalls += 1
        pending = completion
    }

    func resolve(granted: Bool) {
        status = granted ? .authorized : .denied
        let completion = pending
        pending = nil
        completion?(granted)
    }
}

@MainActor
private final class TestCapture: CaptureControlling, CaptureFailureReporting {
    var running = false
    var failNextStart = false
    /// Сколько ближайших стартов должны упасть (моделирует устройство,
    /// которое ещё не поднялось после пробуждения).
    var failStartsRemaining = 0
    var failureHandler: ((Error, UInt) -> Void)?
    private(set) var startCalls = 0
    private(set) var stopCalls = 0

    func start(captureMic: Bool, captureSystem: Bool, generation: UInt) throws {
        _ = (captureMic, captureSystem)
        startCalls += 1
        if failStartsRemaining > 0 {
            failStartsRemaining -= 1
            throw TestError.failed
        }
        if failNextStart {
            failNextStart = false
            throw TestError.failed
        }
        running = true
        activeGeneration = generation
    }

    func stop() {
        stopCalls += 1
        activeGeneration = nil
        running = false
    }

    func emitFailure(generation: UInt? = nil) {
        failureHandler?(TestError.failed, generation ?? activeGeneration ?? 0)
    }

    private var activeGeneration: UInt?
}

private final class TestCore: TranscriberCore {
    private let lock = NSLock()
    private let startGate: DispatchSemaphore?
    private let startEntered: ThreadSafeFlag?
    private let stopGate: DispatchSemaphore?
    private let stopEntered: ThreadSafeFlag?
    private var blocksFirstStart: Bool
    private var blocksFirstStop: Bool
    private(set) var loadCalls = 0
    private(set) var startCalls = 0
    private(set) var stopCalls = 0
    private(set) var pushCalls = 0

    init(startGate: DispatchSemaphore? = nil, startEntered: ThreadSafeFlag? = nil,
         stopGate: DispatchSemaphore? = nil, stopEntered: ThreadSafeFlag? = nil) {
        self.startGate = startGate
        self.startEntered = startEntered
        self.stopGate = stopGate
        self.stopEntered = stopEntered
        self.blocksFirstStart = startGate != nil
        self.blocksFirstStop = stopGate != nil
        super.init(noPointer: TranscriberCore.NoPointer())
    }

    required init(unsafeFromRawPointer pointer: UnsafeMutableRawPointer) {
        self.startGate = nil
        self.startEntered = nil
        self.stopGate = nil
        self.stopEntered = nil
        self.blocksFirstStart = false
        self.blocksFirstStop = false
        super.init(unsafeFromRawPointer: pointer)
    }

    override func loadModel() throws {
        lock.lock(); loadCalls += 1; lock.unlock()
    }

    /// Событие прогресса модели дергает `refreshModels()`; настоящий FFI-вызов
    /// на тестовом ядре без указателя недопустим.
    override func listModels() -> [ModelStatus] { [] }

    override func start() throws {
        lock.lock()
        startCalls += 1
        let shouldBlock = blocksFirstStart
        blocksFirstStart = false
        lock.unlock()
        if shouldBlock {
            startEntered?.set()
            startGate?.wait()
        }
    }

    override func stop() throws {
        lock.lock()
        stopCalls += 1
        let shouldBlock = blocksFirstStop
        blocksFirstStop = false
        lock.unlock()
        if shouldBlock {
            stopEntered?.set()
            stopGate?.wait()
        }
    }

    override func pushAudioFrame(channelId: String, pcm: [Int16], sampleRate: UInt32, channels: UInt8) {
        _ = (channelId, pcm, sampleRate, channels)
        lock.lock(); pushCalls += 1; lock.unlock()
    }
}
