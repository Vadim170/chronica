import Foundation
import TranscriberCore

/// Запись интервала + предвычисленный полный текст для списка/поиска/превью.
///
/// Текст всех непустых дорожек объединён заранее (`fullText`), чтобы поиск и
/// превью в ленте журнала работали без повторных обращений к ядру.
struct HistoryEntry: Identifiable, Equatable {
    let id: Int64
    let startAt: String
    let endAt: String
    let durationS: Double
    let totalWords: UInt32
    /// Объединённый текст всех непустых дорожек (разделитель — пробел).
    let fullText: String
}

/// Чистые функции для ленты журнала — без зависимостей от UI/ядра в рантайме,
/// чтобы покрыть тестами без запущенного движка.
enum HistoryLogic {

    /// Собрать `HistoryEntry` из записей ядра.
    /// `totalWords` — сумма слов по всем дорожкам; `fullText` — текст
    /// непустых дорожек, объединённый через пробел.
    static func entries(from records: [IntervalRecord]) -> [HistoryEntry] {
        records.map { rec in
            let words = rec.channels.reduce(UInt32(0)) { $0 + $1.words }
            let text = rec.channels
                .map(\.text)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: " ")
            return HistoryEntry(
                id: rec.id,
                startAt: rec.startAt,
                endAt: rec.endAt,
                durationS: rec.durationS,
                totalWords: words,
                fullText: text
            )
        }
    }

    /// #4: интервал НЕ пустой, если суммарно >0 слов И есть непустой текст.
    ///
    /// Граничные случаи трактуем строго (нужны ОБА условия), чтобы из ленты
    /// уходили и «тишина», и артефакты, где счётчик слов и текст рассинхронны:
    /// `words>0`, но текст пуст → пусто; текст есть, но `words==0` → пусто.
    static func isNonEmpty(_ e: HistoryEntry) -> Bool {
        e.totalWords > 0 && !e.fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// #4: отфильтровать пустые интервалы.
    static func nonEmpty(_ entries: [HistoryEntry]) -> [HistoryEntry] {
        entries.filter(isNonEmpty)
    }

    /// #5: подходит ли интервал под поисковый запрос.
    /// Регистронезависимо, по объединённому тексту дорожек; пустой запрос
    /// (после обрезки пробелов) — подходит всё.
    static func matches(_ e: HistoryEntry, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        return e.fullText.localizedCaseInsensitiveContains(q)
    }

    /// #5: превью текста для строки списка.
    /// Схлопывает любые группы пробельных символов (включая переводы строк)
    /// в один пробел; если длиннее `maxChars` — обрезает и добавляет «…».
    static func preview(_ text: String, maxChars: Int = 90) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard maxChars > 0, collapsed.count > maxChars else { return collapsed }
        let cut = collapsed.prefix(maxChars).trimmingCharacters(in: .whitespaces)
        return cut + "…"
    }
}
