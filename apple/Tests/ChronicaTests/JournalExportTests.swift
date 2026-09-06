import XCTest
import TranscriberCore
@testable import Chronica

/// Поведение экспорта журнала: единый документ (дела + окна + транскрипция
/// поканально), детерминированный JSON, Markdown, имя файла. Чистые функции.
final class JournalExportTests: XCTestCase {
    /// Детерминированный UTC-ISO для стабильных ассертов (без зависимости от зоны).
    private func utcISO(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    private func sampleDoc() -> JournalDocument {
        let base = Date(timeIntervalSince1970: 1_700_000_000) // фикс. момент
        let act = Activity(id: 3, startAt: base, endAt: base.addingTimeInterval(120),
                           app: "Xcode", title: "Engine.swift", summary: "Правит движок",
                           observations: 2)
        let obs = [
            ScreenObservation(ts: base, app: "Xcode", windowTitle: "Engine.swift", summary: "Открыл файл"),
            ScreenObservation(ts: base.addingTimeInterval(60), app: "Xcode", windowTitle: "Engine.swift", summary: ""),
        ]
        let interval = IntervalRecord(
            id: 42,
            startAt: "2026-07-02T14:30:00+03:00",
            endAt: "2026-07-02T14:30:45+03:00",
            durationS: 45,
            channels: [
                ChannelText(channelId: "mic", text: "привет мир", words: 2, language: "ru"),
                ChannelText(channelId: "remote", text: "", words: 0, language: "en"),
            ]
        )
        return JournalExport.build(
            from: base, to: base.addingTimeInterval(3600), exportedAt: base,
            activities: [ActivityWithObservations(activity: act, observations: obs)],
            intervals: [interval],
            iso: utcISO
        )
    }

    func testBuildMapsActivitiesWithWindows() {
        let doc = sampleDoc()
        XCTAssertEqual(doc.product, "Chronica")
        XCTAssertEqual(doc.activities.count, 1)
        let a = doc.activities[0]
        XCTAssertEqual(a.id, 3)
        XCTAssertEqual(a.app, "Xcode")
        XCTAssertEqual(a.observationCount, 2)
        XCTAssertEqual(a.windows.count, 2, "открытые окна = наблюдения во времени")
        XCTAssertEqual(a.windows[0].window, "Engine.swift")
    }

    func testBuildMapsTranscriptionPerChannelLikeApi() {
        let doc = sampleDoc()
        XCTAssertEqual(doc.transcription.count, 1)
        let iv = doc.transcription.intervals[0]
        XCTAssertEqual(iv.id, 42)
        XCTAssertEqual(iv.startAt, "2026-07-02T14:30:00+03:00", "строки времени интервала — как из ядра")
        XCTAssertEqual(iv.channels.count, 2, "все каналы сохранены, как в API")
        XCTAssertEqual(iv.channels[0].channelId, "mic")
        XCTAssertEqual(iv.channels[0].text, "привет мир")
        XCTAssertEqual(iv.channels[0].words, 2)
        XCTAssertEqual(iv.channels[0].language, "ru")
    }

    func testJsonIsDeterministicAndRoundTrips() {
        let doc = sampleDoc()
        let a = JournalExport.json(doc)
        let b = JournalExport.json(doc)
        XCTAssertEqual(a, b, "sortedKeys → стабильный вывод")
        let decoded = try? JSONDecoder().decode(JournalDocument.self, from: Data(a.utf8))
        XCTAssertEqual(decoded, doc, "JSON round-trips")
        // Ключевые поля структуры присутствуют.
        XCTAssertTrue(a.contains("\"channels\""))
        XCTAssertTrue(a.contains("\"windows\""))
        XCTAssertTrue(a.contains("\"transcription\""))
    }

    func testMarkdownHasSectionsAndPerChannelLines() {
        let md = JournalExport.markdown(sampleDoc())
        // Заголовки локализованы: сверяем с ключами каталога, а не с русским
        // текстом. Плюрализация «1 интервал / 2 интервала / 5 интервалов»
        // приходит из plural-варианта каталога.
        XCTAssertTrue(md.contains("## " + L("export.md.activities", 1)))
        XCTAssertTrue(md.contains("## " + L("export.md.transcription", 1)))
        XCTAssertTrue(md.contains("Xcode — Engine.swift"))
        XCTAssertTrue(md.contains("**\(Channels.label("mic"))** (`ru`): привет мир"))
        XCTAssertFalse(md.contains("**\(Channels.label("remote"))**"),
                       "пустой канал не печатается")
    }

    func testMarkdownEmptyDocReadsGracefully() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let doc = JournalExport.build(from: base, to: base, exportedAt: base,
                                      activities: [], intervals: [], iso: utcISO)
        let md = JournalExport.markdown(doc)
        XCTAssertTrue(md.contains(L("export.md.activities.empty")))
        XCTAssertTrue(md.contains(L("export.md.transcription.empty")))
    }

    func testHhmmExtraction() {
        XCTAssertEqual(JournalExport.hhmm("2026-07-02T14:30:00+03:00"), "14:30")
        XCTAssertEqual(JournalExport.hhmm("2026-07-02T09:05:00Z"), "09:05")
        XCTAssertEqual(JournalExport.hhmm("no-time-here"), "no-time-here")
    }

    func testSuggestedFilename() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let d = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 UTC
        XCTAssertEqual(JournalExport.suggestedFilename(from: d, format: .json, calendar: cal),
                       "chronica-journal-2023-11-14.json")
        XCTAssertEqual(JournalExport.suggestedFilename(from: d, format: .markdown, calendar: cal),
                       "chronica-journal-2023-11-14.md")
    }
}
