import XCTest
@testable import Chronica

/// Поведенческие тесты сборщика контекста экрана: сессионизация наблюдений в
/// «дела», perceptual-hash кадра, промпт. Без I/O.
final class ScreenContextTests: XCTestCase {
    private func obs(_ t: TimeInterval, app: String = "Xcode",
                     title: String = "Engine.swift", summary: String = "Пишет код") -> ScreenObservation {
        ScreenObservation(ts: Date(timeIntervalSince1970: t), app: app,
                          windowTitle: title, summary: summary)
    }

    // MARK: Sessionizer

    func testFirstObservationStartsActivity() {
        let d = Sessionizer.merge(last: nil, obs: obs(100), gap: 180)
        guard case .start(let a) = d else { return XCTFail("expected start") }
        XCTAssertEqual(a.app, "Xcode")
        XCTAssertEqual(a.startAt, a.endAt)
        XCTAssertEqual(a.observations, 1)
    }

    func testSameContextWithinGapExtends() {
        let first = Activity(id: 7, startAt: Date(timeIntervalSince1970: 100),
                             endAt: Date(timeIntervalSince1970: 100),
                             app: "Xcode", title: "Engine.swift", summary: "Пишет код")
        let d = Sessionizer.merge(last: first, obs: obs(160, summary: "Правит Engine"), gap: 180)
        guard case .extend(let a) = d else { return XCTFail("expected extend") }
        XCTAssertEqual(a.id, 7, "id блока сохраняется")
        XCTAssertEqual(a.endAt, Date(timeIntervalSince1970: 160))
        XCTAssertEqual(a.observations, 2)
        XCTAssertEqual(a.summary, "Правит Engine", "непустое описание обновляет блок")
        XCTAssertEqual(a.startAt, first.startAt)
    }

    func testEmptySummaryKeepsPrevious() {
        let first = Activity(id: 1, startAt: Date(timeIntervalSince1970: 100),
                             endAt: Date(timeIntervalSince1970: 100),
                             app: "Xcode", title: "Engine.swift", summary: "Пишет код")
        let d = Sessionizer.merge(last: first, obs: obs(130, summary: ""), gap: 180)
        guard case .extend(let a) = d else { return XCTFail("expected extend") }
        XCTAssertEqual(a.summary, "Пишет код", "пропуск LLM (кадр не менялся) не стирает описание")
    }

    func testAppChangeStartsNewActivity() {
        let first = Activity(id: 1, startAt: Date(timeIntervalSince1970: 100),
                             endAt: Date(timeIntervalSince1970: 100),
                             app: "Xcode", title: "Engine.swift", summary: "")
        let d = Sessionizer.merge(last: first, obs: obs(130, app: "Safari", title: "Habr"), gap: 180)
        guard case .start(let a) = d else { return XCTFail("expected start") }
        XCTAssertEqual(a.app, "Safari")
    }

    func testGapExceededStartsNewActivityEvenIfSameContext() {
        let first = Activity(id: 1, startAt: Date(timeIntervalSince1970: 100),
                             endAt: Date(timeIntervalSince1970: 100),
                             app: "Xcode", title: "Engine.swift", summary: "")
        let d = Sessionizer.merge(last: first, obs: obs(100 + 400), gap: 180)
        guard case .start = d else { return XCTFail("expected start after gap") }
    }

    func testTitleBackfilledWhenFirstWasEmpty() {
        let first = Activity(id: 1, startAt: Date(timeIntervalSince1970: 100),
                             endAt: Date(timeIntervalSince1970: 100),
                             app: "Xcode", title: "", summary: "")
        let d = Sessionizer.merge(last: first, obs: obs(130, title: "Engine.swift"), gap: 180)
        guard case .extend(let a) = d else { return XCTFail("expected extend (empty title is similar)") }
        XCTAssertEqual(a.title, "Engine.swift")
    }

    func testTitlesSimilar() {
        XCTAssertTrue(Sessionizer.titlesSimilar("Engine.swift", "Engine.swift"))
        XCTAssertTrue(Sessionizer.titlesSimilar("Engine.swift — Edited", "Engine.swift"), "префикс")
        XCTAssertTrue(Sessionizer.titlesSimilar("", "что угодно"), "пустой не рвёт блок")
        XCTAssertTrue(Sessionizer.titlesSimilar("PR #42 — transcriber", "PR #42 review transcriber"),
                      "перекрытие токенов")
        XCTAssertFalse(Sessionizer.titlesSimilar("Engine.swift", "Хабр — новости"))
    }

    // MARK: FrameHash

    func testIdenticalFramesHaveZeroDistance() {
        let luma = (0..<64).map { UInt8($0 * 4) }
        XCTAssertEqual(FrameHash.hamming(FrameHash.aHash(luma64: luma),
                                         FrameHash.aHash(luma64: luma)), 0)
    }

    func testSmallChangeStaysUnderThreshold() {
        let luma = (0..<64).map { UInt8($0 * 4) }
        var tweaked = luma
        tweaked[0] = 255 // «часы в углу мигнули»
        let d = FrameHash.hamming(FrameHash.aHash(luma64: luma),
                                  FrameHash.aHash(luma64: tweaked))
        XCTAssertLessThan(d, FrameHash.unchangedThreshold)
    }

    func testInvertedFrameIsFarOverThreshold() {
        let luma = (0..<64).map { UInt8($0 < 32 ? 0 : 255) }
        let inverted = luma.map { UInt8(255 - Int($0)) }
        let d = FrameHash.hamming(FrameHash.aHash(luma64: luma),
                                  FrameHash.aHash(luma64: inverted))
        XCTAssertGreaterThanOrEqual(d, 32)
    }

    // MARK: VisionPrompt

    func testPromptIncludesContext() {
        let p = VisionPrompt.build(app: "Xcode", windowTitle: "Engine.swift")
        XCTAssertTrue(p.contains("Xcode"))
        XCTAssertTrue(p.contains("Engine.swift"))
        // Просим ровно 1–2 предложения — иначе модель пишет эссе.
        XCTAssertTrue(p.contains("1–2"))
    }

    func testPromptOmitsEmptyTitle() throws {
        let withTitle = VisionPrompt.build(app: "Finder", windowTitle: "Downloads")
        let withoutTitle = VisionPrompt.build(app: "Finder", windowTitle: "")
        XCTAssertTrue(withTitle.contains("Downloads"))
        // Блока про заголовок окна не должно быть вовсе (не пустые кавычки).
        let marker = try L10nTestSupport.string("vision.prompt.window",
                                                language: Bundle.appLanguage)
            .replacingOccurrences(of: "%@", with: "")
        XCTAssertFalse(withoutTitle.contains(marker.trimmingCharacters(in: .punctuationCharacters)),
                       "пустой заголовок не должен добавлять блок про окно")
    }

    /// Язык промпта следует языку интерфейса, а не системной локали.
    func testPromptFollowsInterfaceLanguage() {
        XCTAssertEqual(VisionPrompt.language, Bundle.appLanguage)
        XCTAssertFalse(VisionPrompt.build(app: "Finder", windowTitle: "").isEmpty)
    }
}
