import XCTest
@testable import Chronica
@testable import TranscriberCore

/// Поведенческие тесты панели меню-бара на ПЕРВОМ запуске и в проблемных
/// состояниях: что показывается вместо кнопки «Начать запись» и какая одна
/// строка сообщает о проблеме. Ни ядро, ни микрофон, ни SwiftUI не нужны.
final class PopoverOnboardingTests: XCTestCase {

    private func model(_ id: String,
                       installed: Bool = true,
                       downloading: Bool = false,
                       progressPct: Float = 0,
                       family: String = "parakeet") -> ModelStatus {
        ModelStatus(id: id, label: id, family: family, runtime: "sherpa-onnx",
                    installed: installed, downloadedBytes: 0, totalBytes: 0,
                    progressPct: progressPct, downloading: downloading, lastError: "")
    }

    private let active = "parakeet-tdt-0.6b-v3-int8"

    // MARK: модель ещё не скачана

    func testAsksToDownloadWhenActiveModelIsNotInstalled() {
        let state = PopoverOnboarding.decide(
            models: [model(active, installed: false)],
            progress: [:], activeModelId: active,
            micStatus: .authorized, micRequired: true)
        XCTAssertEqual(state, .needsModel(modelId: active, progress: nil))
    }

    func testShowsDownloadProgressFromLiveSnapshot() {
        // Прогресс из событий свежее списка моделей — берём именно его.
        let state = PopoverOnboarding.decide(
            models: [model(active, installed: false)],
            progress: [active: model(active, installed: false,
                                     downloading: true, progressPct: 42)],
            activeModelId: active,
            micStatus: .authorized, micRequired: true)
        XCTAssertEqual(state, .needsModel(modelId: active, progress: 0.42))
    }

    func testMissingModelEntryAlsoAsksToDownload() {
        // Реестр есть, но активной модели в нём нет — тоже «нужно скачать».
        let state = PopoverOnboarding.decide(
            models: [model("large-v3-turbo", family: "whisper")],
            progress: [:], activeModelId: active,
            micStatus: .authorized, micRequired: true)
        XCTAssertEqual(state, .needsModel(modelId: active, progress: nil))
    }

    func testEmptyRegistryIsNotTreatedAsMissingModel() {
        // Ядро ещё не поднялось: список пуст. Пугать «нет модели» нельзя.
        let state = PopoverOnboarding.decide(
            models: [], progress: [:], activeModelId: active,
            micStatus: .authorized, micRequired: true)
        XCTAssertEqual(state, .ready)
    }

    func testMissingModelWinsOverDeniedMicrophone() {
        // Без модели запись невозможна в принципе — это и есть первый шаг.
        let state = PopoverOnboarding.decide(
            models: [model(active, installed: false)],
            progress: [:], activeModelId: active,
            micStatus: .denied, micRequired: true)
        XCTAssertEqual(state, .needsModel(modelId: active, progress: nil))
    }

    func testFinishedDownloadSwitchesPanelToRecordButton() {
        // После успешной загрузки Engine приводит снимок прогресса к записи
        // реестра. Панель обязана перестать предлагать скачивание.
        let state = PopoverOnboarding.decide(
            models: [model(active, installed: true)],
            progress: [active: model(active, installed: true, downloading: false)],
            activeModelId: active,
            micStatus: .authorized, micRequired: true)
        XCTAssertEqual(state, .ready)
    }

    func testVadProgressDoesNotAffectThePanel() {
        // Вместе с ASR-моделью ядро докачивает служебный Silero VAD. Его
        // прогресс не должен ни подменять прогресс активной модели, ни мешать
        // перейти к кнопке записи.
        let state = PopoverOnboarding.decide(
            models: [model(active, installed: true)],
            progress: ["silero-vad": model("silero-vad", installed: false,
                                           downloading: true, progressPct: 10,
                                           family: "vad")],
            activeModelId: active,
            micStatus: .authorized, micRequired: true)
        XCTAssertEqual(state, .ready)
    }

    // MARK: разрешение микрофона

    func testDeniedMicrophoneOffersSystemSettings() {
        let state = PopoverOnboarding.decide(
            models: [model(active)], progress: [:], activeModelId: active,
            micStatus: .denied, micRequired: true)
        XCTAssertEqual(state, .micDenied)
    }

    func testDeniedMicrophoneIsIgnoredWhenMicSourceIsOff() {
        // Пишем только системный звук — отказ в микрофоне не мешает.
        let state = PopoverOnboarding.decide(
            models: [model(active)], progress: [:], activeModelId: active,
            micStatus: .denied, micRequired: false)
        XCTAssertEqual(state, .ready)
    }

    func testNotDeterminedMicrophoneStaysReady() {
        // Системный запрос покажет сам Engine при старте — блокировать нечего.
        let state = PopoverOnboarding.decide(
            models: [model(active)], progress: [:], activeModelId: active,
            micStatus: .notDetermined, micRequired: true)
        XCTAssertEqual(state, .ready)
    }

    // MARK: доля загрузки

    func testDownloadFractionIsNilWhenNotDownloading() {
        XCTAssertNil(PopoverOnboarding.downloadFraction(model(active, installed: false)))
    }

    func testDownloadFractionIsClampedToUnitRange() {
        let over = model(active, installed: false, downloading: true, progressPct: 150)
        let under = model(active, installed: false, downloading: true, progressPct: -5)
        XCTAssertEqual(PopoverOnboarding.downloadFraction(over), 1)
        XCTAssertEqual(PopoverOnboarding.downloadFraction(under), 0)
    }
}

/// Единственная строка о проблеме под статусом записи.
final class SessionHealthTests: XCTestCase {

    func testNothingIsShownWhenEverythingIsFine() {
        XCTAssertNil(SessionHealth.note(stalled: false, suspendedForSleep: false, degraded: false))
    }

    func testStallWinsOverEverythingElse() {
        let note = SessionHealth.note(stalled: true, suspendedForSleep: true, degraded: true)
        XCTAssertEqual(note, L("health.stalled"))
        // Самая тяжёлая проблема обязана называть действие пользователя — в
        // обеих локализациях, иначе строка бесполезна.
        for language in L10nTestSupport.languages {
            let text = (try? L10nTestSupport.string("health.stalled", language: language)) ?? ""
            XCTAssertTrue(text.lowercased().contains("chronica"),
                          "\(language): строка не называет, что перезапустить")
        }
    }

    func testSleepIsReportedWhenNotStalled() {
        let note = SessionHealth.note(stalled: false, suspendedForSleep: true, degraded: true)
        XCTAssertEqual(note, SessionHealth.note(stalled: false, suspendedForSleep: true, degraded: false))
        XCTAssertNotNil(note)
    }

    func testDegradedCaptureIsReportedLast() {
        XCTAssertNotNil(SessionHealth.note(stalled: false, suspendedForSleep: false, degraded: true))
    }

    // MARK: потерянные интервалы (перегрузка)

    func testDroppedIntervalsAreReportedWhenNothingElseIsWrong() {
        // Запись продолжается, но часть речи в историю не попала — молчать об
        // этом нельзя, иначе пользователь считает журнал полным.
        let note = SessionHealth.note(stalled: false, suspendedForSleep: false,
                                      degraded: false, droppedIntervals: 2)
        XCTAssertEqual(note, L("health.dropped"))
    }

    func testNoDroppedIntervalsMeansNoNote() {
        XCTAssertNil(SessionHealth.note(stalled: false, suspendedForSleep: false,
                                        degraded: false, droppedIntervals: 0))
    }

    func testHeavierProblemsWinOverDroppedIntervals() {
        // Потери интервалов — самая лёгкая проблема: запись идёт. Остановленный
        // конвейер или недоступный источник важнее.
        for note in [SessionHealth.note(stalled: true, suspendedForSleep: false,
                                        degraded: false, droppedIntervals: 9),
                     SessionHealth.note(stalled: false, suspendedForSleep: true,
                                        degraded: false, droppedIntervals: 9),
                     SessionHealth.note(stalled: false, suspendedForSleep: false,
                                        degraded: true, droppedIntervals: 9)] {
            XCTAssertNotNil(note)
            XCTAssertNotEqual(note, L("health.dropped"))
        }
    }

    func testExactlyOneNoteAtATime() {
        // Контракт: функция возвращает ОДНУ строку, а не список — интерфейс
        // никогда не показывает два индикатора одновременно.
        let combos: [(Bool, Bool, Bool)] = [
            (true, true, true), (true, false, false),
            (false, true, false), (false, false, true),
        ]
        for (stalled, sleeping, degraded) in combos {
            let note = SessionHealth.note(stalled: stalled, suspendedForSleep: sleeping,
                                          degraded: degraded)
            XCTAssertNotNil(note)
            XCTAssertFalse(note!.contains("\n"), "строка состояния всегда одна")
        }
    }
}
