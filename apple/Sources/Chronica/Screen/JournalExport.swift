import Foundation
import TranscriberCore

// Экспорт журнала за период: ЕДИНЫЙ структурированный документ, включающий
//   1) дела (блоки работы) с открытыми окнами (наблюдения экрана во времени),
//   2) историю транскрипции ПОКАНАЛЬНО — та же форма, что отдаёт HTTP API
//      (`/api/intervals`: интервалы → каналы {channelId,text,words,language}).
//
// Здесь ТОЛЬКО чистая логика построения документа и сериализации (без I/O,
// без NSSavePanel) — покрыто юнит-тестами. UI (JournalView) собирает сырые
// данные из Engine/ScreenObserver и зовёт эти функции.

/// Дело + его наблюдения (открытые окна во времени), как их собрал UI.
struct ActivityWithObservations {
    var activity: Activity
    var observations: [ScreenObservation]
}

// MARK: - Экспортируемый документ (Codable, детерминированная сериализация)

struct JournalDocument: Codable, Equatable {
    var product: String
    var exportedAt: String
    var from: String
    var to: String
    var activities: [ActivityExport]
    var transcription: TranscriptionExport
}

struct ActivityExport: Codable, Equatable {
    var id: Int64
    var startAt: String
    var endAt: String
    var app: String
    var title: String
    var summary: String
    var observationCount: Int
    /// Открытые окна во времени внутри дела (журнал наблюдений экрана).
    var windows: [WindowExport]
}

struct WindowExport: Codable, Equatable {
    var ts: String
    var app: String
    var window: String
    var summary: String
}

struct TranscriptionExport: Codable, Equatable {
    var count: Int
    var intervals: [IntervalExport]
}

struct IntervalExport: Codable, Equatable {
    var id: Int64
    var startAt: String
    var endAt: String
    var durationS: Double
    /// Поканально — как в API (`ChannelText`).
    var channels: [ChannelExport]
}

struct ChannelExport: Codable, Equatable {
    var channelId: String
    var text: String
    var words: UInt32
    var language: String
}

// MARK: - Построение и сериализация

enum JournalExport {
    /// Формат файла экспорта.
    enum Format: String, CaseIterable { case json, markdown }

    /// ISO8601 по умолчанию (даты дел хранятся как Date; интервалы приходят из
    /// ядра уже строками RFC3339). Инъекция `iso` оставлена для детерминизма в
    /// тестах. Экспорт — редкая операция, форматтер создаётся по месту.
    static func defaultISO(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    /// Собирает единый документ. Даты дел форматируются через `iso`; строки
    /// времени интервалов берутся как есть (их формат задаёт ядро).
    static func build(
        from: Date,
        to: Date,
        exportedAt: Date,
        activities: [ActivityWithObservations],
        intervals: [IntervalRecord],
        iso: (Date) -> String = defaultISO
    ) -> JournalDocument {
        let acts = activities.map { item in
            ActivityExport(
                id: item.activity.id,
                startAt: iso(item.activity.startAt),
                endAt: iso(item.activity.endAt),
                app: item.activity.app,
                title: item.activity.title,
                summary: item.activity.summary,
                observationCount: item.activity.observations,
                windows: item.observations.map {
                    WindowExport(ts: iso($0.ts), app: $0.app, window: $0.windowTitle, summary: $0.summary)
                }
            )
        }
        let ivs = intervals.map { rec in
            IntervalExport(
                id: rec.id,
                startAt: rec.startAt,
                endAt: rec.endAt,
                durationS: rec.durationS,
                channels: rec.channels.map {
                    ChannelExport(channelId: $0.channelId, text: $0.text, words: $0.words, language: $0.language)
                }
            )
        }
        return JournalDocument(
            product: "Chronica",
            exportedAt: iso(exportedAt),
            from: iso(from),
            to: iso(to),
            activities: acts,
            transcription: TranscriptionExport(count: ivs.count, intervals: ivs)
        )
    }

    /// Детерминированный JSON (sortedKeys + pretty) — стабильный дифф/тесты.
    static func json(_ doc: JournalDocument) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(doc), let s = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return s
    }

    /// Человекочитаемый Markdown: дела с окнами, затем транскрипция поканально.
    /// Заголовки — на языке интерфейса (каталог строк).
    static func markdown(_ doc: JournalDocument) -> String {
        var s = "# " + L("export.md.title", doc.product) + "\n\n"
        s += "- " + L("export.md.period", doc.from, doc.to) + "\n"
        s += "- " + L("export.md.exportedAt", doc.exportedAt) + "\n\n"

        s += "## " + L("export.md.activities", doc.activities.count) + "\n\n"
        if doc.activities.isEmpty {
            s += L("export.md.activities.empty") + "\n\n"
        }
        for a in doc.activities {
            let title = a.title.isEmpty ? a.app : "\(a.app) — \(a.title)"
            s += "### \(hhmm(a.startAt))–\(hhmm(a.endAt)) · \(title)\n\n"
            if !a.summary.isEmpty { s += "\(a.summary)\n\n" }
            if !a.windows.isEmpty {
                s += L("export.md.windows", a.observationCount) + "\n"
                for w in a.windows {
                    let win = w.window.isEmpty ? w.app : "\(w.app) — \(w.window)"
                    s += "- \(hhmm(w.ts)) · \(win)"
                    if !w.summary.isEmpty { s += " — \(w.summary)" }
                    s += "\n"
                }
                s += "\n"
            }
        }

        s += "## " + L("export.md.transcription", doc.transcription.count) + "\n\n"
        if doc.transcription.intervals.isEmpty {
            s += L("export.md.transcription.empty") + "\n\n"
        }
        for iv in doc.transcription.intervals {
            let nonEmpty = iv.channels.filter { !$0.text.isEmpty }
            guard !nonEmpty.isEmpty else { continue }
            s += "### \(hhmm(iv.startAt))–\(hhmm(iv.endAt))\n\n"
            for c in nonEmpty {
                s += "**\(Channels.label(c.channelId))** (`\(c.language)`): \(c.text)\n\n"
            }
        }
        return s
    }

    /// Полезное имя файла для NSSavePanel: `chronica-journal-YYYY-MM-DD.<ext>`.
    ///
    /// Дата собирается из компонент ГРЕГОРИАНСКОГО календаря в зоне переданного
    /// (по умолчанию — системного): имя файла не должно зависеть ни от локали,
    /// ни от нестандартного календаря пользователя (иначе год «1447»).
    static func suggestedFilename(from: Date, format: Format, calendar: Calendar = .current) -> String {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let c = gregorian.dateComponents([.year, .month, .day], from: from)
        let day = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        let ext = format == .json ? "json" : "md"
        return "chronica-journal-\(day).\(ext)"
    }

    /// HH:MM из ISO/RFC3339-строки (`...THH:MM...`). Пустая строка — как есть.
    static func hhmm(_ iso: String) -> String {
        guard let tIndex = iso.firstIndex(of: "T") else { return iso }
        let after = iso.index(after: tIndex)
        let hm = iso[after...].prefix(5) // HH:MM
        return hm.count == 5 ? String(hm) : iso
    }
}
