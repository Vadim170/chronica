import XCTest
import TranscriberCore
@testable import Chronica

/// Тесты чистых функций Истории. Запущенное ядро не требуется — работаем на
/// сконструированных IntervalRecord/ChannelText и HistoryEntry.
final class HistoryLogicTests: XCTestCase {

    // MARK: helpers

    private func channel(_ text: String, words: UInt32, id: String = "mic", lang: String = "ru") -> ChannelText {
        ChannelText(channelId: id, text: text, words: words, language: lang)
    }

    private func record(id: Int64, channels: [ChannelText]) -> IntervalRecord {
        IntervalRecord(id: id, startAt: "2026-06-19T10:00:00",
                       endAt: "2026-06-19T10:00:38", durationS: 38, channels: channels)
    }

    private func entry(words: UInt32, text: String, id: Int64 = 1) -> HistoryEntry {
        HistoryEntry(id: id, startAt: "2026-06-19T10:00:00", endAt: "2026-06-19T10:00:38",
                     durationS: 38, totalWords: words, fullText: text)
    }

    // MARK: entries(from:)

    func testEntriesSumsWordsAndJoinsNonEmptyText() {
        let rec = record(id: 7, channels: [
            channel("Привет", words: 1, id: "mic"),
            channel("", words: 0, id: "system"),
            channel("мир", words: 1, id: "remote"),
        ])
        let e = HistoryLogic.entries(from: [rec])
        XCTAssertEqual(e.count, 1)
        XCTAssertEqual(e[0].id, 7)
        XCTAssertEqual(e[0].totalWords, 2)
        XCTAssertEqual(e[0].fullText, "Привет мир")
    }

    // MARK: isNonEmpty (#4)

    func testIsNonEmptyTrueWhenWordsAndText() {
        XCTAssertTrue(HistoryLogic.isNonEmpty(entry(words: 3, text: "какой-то текст")))
    }

    func testIsNonEmptyFalseWhenZeroWordsAndEmptyText() {
        XCTAssertFalse(HistoryLogic.isNonEmpty(entry(words: 0, text: "")))
    }

    func testIsNonEmptyFalseWhenWordsButEmptyText() {
        // Граничный: счётчик >0, но текста нет → считаем пустым.
        XCTAssertFalse(HistoryLogic.isNonEmpty(entry(words: 5, text: "   ")))
    }

    func testIsNonEmptyFalseWhenTextButZeroWords() {
        // Граничный: текст есть, но words==0 → пустой (нужны оба условия).
        XCTAssertFalse(HistoryLogic.isNonEmpty(entry(words: 0, text: "есть текст")))
    }

    // MARK: nonEmpty (#4)

    func testNonEmptyFiltersMixedArray() {
        let mixed = [
            entry(words: 2, text: "оставить", id: 1),
            entry(words: 0, text: "", id: 2),
            entry(words: 4, text: "и это тоже", id: 3),
            entry(words: 0, text: "только текст", id: 4),
        ]
        let kept = HistoryLogic.nonEmpty(mixed)
        XCTAssertEqual(kept.map(\.id), [1, 3])
    }

    // MARK: matches (#5)

    func testMatchesEmptyQueryAlwaysTrue() {
        XCTAssertTrue(HistoryLogic.matches(entry(words: 1, text: "что угодно"), query: ""))
        XCTAssertTrue(HistoryLogic.matches(entry(words: 1, text: "что угодно"), query: "   "))
    }

    func testMatchesCaseInsensitiveSubstring() {
        let e = entry(words: 2, text: "Hello World")
        XCTAssertTrue(HistoryLogic.matches(e, query: "hello"))
        XCTAssertTrue(HistoryLogic.matches(e, query: "WORLD"))
    }

    func testMatchesFalseWhenAbsent() {
        XCTAssertFalse(HistoryLogic.matches(entry(words: 2, text: "Hello World"), query: "пицца"))
    }

    func testMatchesSearchesAcrossJoinedChannels() {
        // Слово на границе двух дорожек, объединённых через пробел.
        let rec = record(id: 1, channels: [
            channel("первая дорожка", words: 2, id: "mic"),
            channel("вторая дорожка", words: 2, id: "system"),
        ])
        let e = HistoryLogic.entries(from: [rec])[0]
        XCTAssertTrue(HistoryLogic.matches(e, query: "вторая"))
        XCTAssertTrue(HistoryLogic.matches(e, query: "первая дорожка вторая"))
    }

    // MARK: preview (#5)

    func testPreviewShortTextReturnedWhole() {
        XCTAssertEqual(HistoryLogic.preview("Короткий текст", maxChars: 90), "Короткий текст")
    }

    func testPreviewLongTextTruncatedWithEllipsis() {
        let long = String(repeating: "a", count: 200)
        let p = HistoryLogic.preview(long, maxChars: 90)
        XCTAssertTrue(p.hasSuffix("…"))
        // 90 символов + многоточие.
        XCTAssertEqual(p.count, 91)
    }

    func testPreviewCollapsesWhitespaceAndNewlines() {
        XCTAssertEqual(HistoryLogic.preview("раз\n\nдва   три", maxChars: 90), "раз два три")
    }
}
