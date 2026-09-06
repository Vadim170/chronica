import SwiftUI
import TranscriberCore

// MARK: - Typography helpers

extension Font {
    /// Section headline: 13 Semibold, used with tracking +0.5 and caps.
    static let sectionHeadline = Font.system(size: 13, weight: .semibold)
    /// Monospaced metric / timecode font (SF Mono 12).
    static let metric = Font.system(size: 12, design: .monospaced)
    static let metricSmall = Font.system(size: 11, design: .monospaced)
    /// KPI big number.
    static let kpiNumber = Font.system(size: 28, weight: .semibold, design: .rounded)
}

// MARK: - Section header

/// Small caps section label used across surfaces ("SOURCES", "LINES"...).
/// Текст приходит уже локализованным (`L("popover.sources")`).
struct SectionLabel: View {
    let text: String
    var trailing: AnyView? = nil
    init(_ text: String, trailing: AnyView? = nil) {
        self.text = text
        self.trailing = trailing
    }
    var body: some View {
        HStack {
            Text(text.uppercased())
                .font(.sectionHeadline)
                .tracking(0.5)
                .foregroundStyle(Theme.Color.textSecondary)
            Spacer(minLength: 0)
            if let trailing { trailing }
        }
    }
}

// MARK: - Card surface

/// Matte card surface for content windows.
struct Card<Content: View>: View {
    var padding: CGFloat = Theme.Space.l
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Theme.Color.surface1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.Color.hairline, lineWidth: 1)
            )
    }
}

// MARK: - Track dot

/// Цветная точка дорожки (микрофон / система). Чисто декоративная: подпись
/// дорожки всегда стоит рядом текстом, поэтому для VoiceOver точка скрыта.
struct TrackDot: View {
    let channelId: String
    var size: CGFloat = 7
    var body: some View {
        Circle()
            .fill(Theme.trackColor(channelId))
            .frame(width: size, height: size)
            .shadow(color: Theme.trackColor(channelId).opacity(0.5), radius: 3)
            .accessibilityHidden(true)
    }
}

// MARK: - Sparkline

/// Минимальный график-«спарклайн» (Path, самонормируется).
///
/// Декоративен по своей природе: точное значение всегда напечатано рядом
/// числом, поэтому по умолчанию скрыт от VoiceOver. Если график несёт
/// собственный смысл, вызывающий передаёт `accessibilityLabel`.
struct Sparkline: View {
    let values: [Double]
    var color: Color = Theme.Color.accent
    /// Осмысленная подпись для VoiceOver. `nil` — график скрыт как декорация.
    var accessibilityLabel: String? = nil

    var body: some View {
        GeometryReader { geo in
            let pts = points(in: geo.size)
            ZStack {
                if pts.count > 1 {
                    Path { p in
                        p.move(to: pts[0])
                        for pt in pts.dropFirst() { p.addLine(to: pt) }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: geo.size.height))
                        for pt in pts { p.addLine(to: pt) }
                        p.addLine(to: CGPoint(x: pts.last!.x, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.25), color.opacity(0.0)],
                                         startPoint: .top, endPoint: .bottom))
                }
            }
        }
        .accessibilityHidden(accessibilityLabel == nil)
        .accessibilityLabel(accessibilityLabel ?? "")
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let maxV = values.max() ?? 1
        let minV = values.min() ?? 0
        let range = max(maxV - minV, 0.0001)
        let stepX = size.width / CGFloat(values.count - 1)
        return values.enumerated().map { i, v in
            let y = size.height - CGFloat((v - minV) / range) * size.height
            return CGPoint(x: CGFloat(i) * stepX, y: y)
        }
    }
}

// MARK: - Inline error banner

struct ErrorBanner: View {
    let message: String
    var retry: (() -> Void)? = nil
    /// Подпись кнопки действия. `nil` — «Повторить»/"Retry" из каталога
    /// (локализованную строку нельзя положить в дефолт свойства структуры).
    var actionTitle: String? = nil
    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.Color.semWarning)
                .accessibilityHidden(true)
            Text(message)
                .font(.caption)
                .foregroundStyle(Theme.Color.textPrimary)
                .lineLimit(3)
            Spacer(minLength: 0)
            if let retry {
                Button(actionTitle ?? L("popover.retry"), action: retry)
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(Theme.Color.accent)
            }
        }
        .padding(Theme.Space.s)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Theme.Color.semWarning.opacity(0.12))
        )
    }
}

// MARK: - Shared formatting helpers

enum Fmt {
    /// Parse the core's ISO-8601 timestamps (with or without fractional secs).
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Локальный ISO-8601 со смещением зоны (например `2026-06-19T10:00:00+03:00`).
    ///
    /// Ядро хранит `voice_events.ts` и времена интервалов как RFC3339 со
    /// смещением локальной зоны, а SQLite сравнивает границы диапазона
    /// ЛЕКСИКОГРАФИЧЕСКИ (по строке). Если слать границы в UTC с суффиксом `Z`
    /// (как делает `isoPlain` с дефолтной GMT-зоной), строки `…+03:00` и `…Z`
    /// сортируются несогласованно, и сегодняшние события выпадают из диапазона —
    /// отсюда баг «нет голосовой активности». Поэтому для запросов диапазона
    /// (voiceActivity / intervals) ВСЕГДА используем эту строку: одинаковый
    /// формат и зона со стораджем → корректная лексическая фильтрация.
    static let isoLocal: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone.current
        return f
    }()

    // Создание DateFormatter относительно дорого, а компактная live-лента
    // форматирует одинаковый шаблон каждой видимой строки при каждом update.
    // Держим форматтеры весь срок жизни процесса; UI вызывает их на главном
    // акторе, сохраняя прежние локальную зону и локаль.
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    // Локаль берём системную (`Locale.current`): зашитая локаль игнорировала бы
    // региональные настройки пользователя.
    private static let dayTitleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("d MMMM")
        return f
    }()
    /// Короткое время «ЧЧ:ММ» — подписи графиков и диапазоны периода.
    private static let shortTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "HH:mm"
        return f
    }()
    /// Час «ЧЧ:00» для подписей почасового графика.
    private static let hourLabelFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "HH:00"
        return f
    }()
    /// День «дд.ММ» для подписей подневного графика.
    private static let dayLabelFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "dd.MM"
        return f
    }()

    /// Граница диапазона запроса в локальной зоне (для voiceActivity/intervals).
    static func queryBound(_ date: Date) -> String { isoLocal.string(from: date) }

    static func date(_ s: String) -> Date? {
        iso.date(from: s) ?? isoPlain.date(from: s)
    }

    static func time(_ s: String) -> String {
        guard let d = date(s) else { return "--:--" }
        return timeFormatter.string(from: d)
    }

    /// «ЧЧ:ММ:СС» по готовой дате (строки ленты журнала уже разобраны).
    static func time(_ date: Date) -> String { timeFormatter.string(from: date) }

    static func clock(_ seconds: Float) -> String {
        let t = Int(max(0, seconds))
        return String(format: "%02d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
    }

    static func dayKey(_ s: String) -> String {
        guard let d = date(s) else { return "—" }
        return dayKeyFormatter.string(from: d)
    }

    static func dayTitle(_ s: String) -> String {
        guard let d = date(s) else { return s }
        return dayTitle(d)
    }

    /// Заголовок дня по готовой дате («Сегодня» / «Вчера» / «19 июня»).
    static func dayTitle(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return L("fmt.today") }
        if Calendar.current.isDateInYesterday(date) { return L("fmt.yesterday") }
        return dayTitleFormatter.string(from: date)
    }

    /// Короткое время «ЧЧ:ММ».
    static func shortTime(_ date: Date) -> String { shortTimeFormatter.string(from: date) }

    /// Подпись бакета активности: «ЧЧ:00» для почасовой шкалы, «дд.ММ» для
    /// подневной. Неразобранная строка возвращается как есть.
    static func bucketLabel(_ ts: String, hourly: Bool) -> String {
        guard let d = date(ts) else { return ts }
        return hourly ? hourLabelFormatter.string(from: d) : dayLabelFormatter.string(from: d)
    }

    static func bytes(_ b: UInt64) -> String {
        if b == 0 { return "—" }
        return memBytes(b)
    }

    static func duration(_ s: Double) -> String {
        let t = Int(s.rounded())
        if t >= 60 { return String(format: "%d:%02d", t / 60, t % 60) }
        return "\(t) " + L("unit.seconds.short")
    }

    // MARK: - Пояснимые метрики (#4)

    /// CPU: «текущий · мед P50 · p90 P90», например «38% · мед 22% · p90 61%».
    /// Чистая функция (тестируема). Перцентили <0 трактуем как 0.
    static func cpuLine(current: Float, p50: Float, p90: Float) -> String {
        let c = Int(max(0, current).rounded())
        let m = Int(max(0, p50).rounded())
        let p = Int(max(0, p90).rounded())
        return "\(c)% · \(L("metric.median.short")) \(m)% · p90 \(p)%"
    }

    /// RAM: «текущий · пик», например «1.1 ГБ · пик 1.4 ГБ». Пик показываем
    /// только если он строго больше текущего (иначе дублирование бессмысленно).
    static func ramLine(current: UInt64, peak: UInt64) -> String {
        let cur = memBytes(current)
        guard peak > current else { return cur }
        return "\(cur) · \(L("metric.peak.short")) \(memBytes(peak))"
    }

    /// Форматирование байт памяти БЕЗ замены нуля на «—» (для RAM 0 Б валиден).
    /// Единица измерения локализована (МБ/ГБ ↔ MB/GB).
    static func memBytes(_ b: UInt64) -> String {
        let gb = Double(b) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f ", gb) + L("unit.gigabytes") }
        let mb = Double(b) / 1_048_576
        return String(format: "%.0f ", mb) + L("unit.megabytes")
    }

    /// Потерянное аудио в секундах: sum(droppedChunks)/16000, округление до
    /// целых секунд. Возвращает `nil`, если потерь нет (0) — показатель надо
    /// СКРЫТЬ совсем (#4), а не печатать «0».
    static func droppedAudioSeconds(_ totalDroppedSamples: UInt64,
                                    sampleRate: UInt64 = 16_000) -> Int? {
        guard totalDroppedSamples > 0, sampleRate > 0 else { return nil }
        // Округляем к ближайшей секунде, но никогда не до 0 при ненулевых потерях.
        let secs = Int((Double(totalDroppedSamples) / Double(sampleRate)).rounded())
        return max(1, secs)
    }

    /// Подпись «потеряно аудио: Xс» или `nil`, если потерь нет.
    static func droppedAudioLine(_ totalDroppedSamples: UInt64,
                                 sampleRate: UInt64 = 16_000) -> String? {
        guard let s = droppedAudioSeconds(totalDroppedSamples, sampleRate: sampleRate) else { return nil }
        return L("metric.droppedAudio", s)
    }

    /// Подпись «Потеряно интервалов: N» или `nil`, если потерь нет.
    ///
    /// Это ДРУГАЯ потеря, чем «потеряно аудио»: там сэмплы не попали в
    /// кольцевой буфер, здесь уже нарезанный интервал не дождался ASR
    /// (переполнена очередь или остановка прервана по дедлайну). Ноль
    /// показывать нельзя — в норме этой строки не должно быть вовсе.
    static func droppedIntervalsLine(_ dropped: UInt32) -> String? {
        guard dropped > 0 else { return nil }
        return L("metric.droppedIntervals", Int(dropped))
    }

    /// Сводка по хранилищу для Настроек: «Данные: 42 МБ · 137 записей».
    ///
    /// Размер — база плюс WAL рядом с ней: пользователь видит место на диске,
    /// а не внутреннее устройство SQLite. `intervals` отрицательным не бывает,
    /// но защищаемся: отрицательное число записей — это 0. Форма слова
    /// «запись/записи/записей» приходит из plural-варианта каталога.
    static func storeLine(sizeBytes: UInt64, walBytes: UInt64, intervals: Int64) -> String {
        let count = max(0, intervals)
        return L("metric.storeLine",
                 memBytes(sizeBytes + walBytes),
                 L("metric.records", Int(count)))
    }
}

// MARK: - 24h-аналитика для popover (#6) — чистые функции

/// Один часовой бакет за 24-часовое окно.
struct HourBucket: Equatable, Identifiable {
    /// Начало часа (локальная зона).
    let start: Date
    /// Суммарно слов по всем дорожкам, попавшим в этот час.
    let words: Int
    /// Был ли хотя бы один интервал в этом часе (покрытие).
    let active: Bool
    var id: TimeInterval { start.timeIntervalSinceReferenceDate }
}

/// Сводка за 24 часа: бакеты по часам + агрегаты для подписи.
struct Window24h: Equatable {
    /// 24 бакета, СТАРЫЙ→НОВЫЙ (последний — текущий час).
    let buckets: [HourBucket]
    /// Суммарно слов за 24ч.
    let totalWords: Int
    /// Суммарно интервалов за 24ч.
    let totalIntervals: Int
}

/// Чистые функции расчёта 24-часовых бакетов и покрытия (#6).
///
/// Источник — массив интервалов (`IntervalRecord`): надёжнее, чем агрегаты
/// активности, т.к. интервалы и их слова приходят в живую ленту и однозначно
/// маппятся в час по `startAt`. Маппинг в часы — через переданный `Calendar`
/// (детерминизм в тестах: можно зафиксировать зону).
enum Activity24h {
    /// Слова интервала = сумма по всем дорожкам.
    static func words(_ iv: IntervalRecord) -> Int {
        iv.channels.reduce(0) { $0 + Int($1.words) }
    }

    /// Строит окно из 24 часовых бакетов, заканчивающихся часом `now`.
    /// Бакет k покрывает [hourStart-(23-k)ч … +1ч). Интервал попадает в бакет
    /// по началу своего часа (floor `startAt` до часа). Возвращает бакеты
    /// СТАРЫЙ→НОВЫЙ и агрегаты ровно по тем интервалам, что попали в окно.
    ///
    /// - parameter parse: парсер ISO-строки в Date (по умолчанию `Fmt.date`).
    static func window(intervals: [IntervalRecord],
                       now: Date,
                       calendar: Calendar = Calendar.current,
                       parse: (String) -> Date? = { Fmt.date($0) }) -> Window24h {
        // Час текущего момента (floor до начала часа).
        let currentHour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        // 24 начала часов: [currentHour-23ч … currentHour].
        let starts: [Date] = (0..<24).compactMap { i in
            calendar.date(byAdding: .hour, value: -(23 - i), to: currentHour)
        }
        guard starts.count == 24, let windowStart = starts.first else {
            return Window24h(buckets: [], totalWords: 0, totalIntervals: 0)
        }
        let windowEnd = calendar.date(byAdding: .hour, value: 1, to: currentHour) ?? now

        // Индекс часа → накопленные слова и флаг активности.
        var wordsByIndex = [Int](repeating: 0, count: 24)
        var activeByIndex = [Bool](repeating: false, count: 24)
        var totalWords = 0
        var totalIntervals = 0

        for iv in intervals {
            guard let d = parse(iv.startAt), d >= windowStart, d < windowEnd else { continue }
            guard let hourStart = calendar.dateInterval(of: .hour, for: d)?.start else { continue }
            // Индекс = число часов от windowStart.
            let idx = calendar.dateComponents([.hour], from: windowStart, to: hourStart).hour ?? -1
            guard idx >= 0, idx < 24 else { continue }
            let w = words(iv)
            wordsByIndex[idx] += w
            activeByIndex[idx] = true
            totalWords += w
            totalIntervals += 1
        }

        let buckets = (0..<24).map { i in
            HourBucket(start: starts[i], words: wordsByIndex[i], active: activeByIndex[i])
        }
        return Window24h(buckets: buckets, totalWords: totalWords, totalIntervals: totalIntervals)
    }
}

// MARK: - Сведения о сборке

/// Имя и версия приложения из Info.plist.
///
/// В `swift run`/тестах bundle-ключей нет — тогда отдаём «—», а не падаем и не
/// печатаем пустые скобки.
enum AppInfo {
    static let name = "Chronica"

    /// Публичный репозиторий проекта (окно «О Chronica», ссылки в UI).
    static let repositoryURL = URL(string: "https://github.com/Vadim170/chronica")!
    /// Короткая подпись той же ссылки — без схемы, чтобы не растягивать окно.
    static let repositoryLabel = "github.com/Vadim170/chronica"
    /// Имя файла уведомлений о сторонних компонентах в `Contents/Resources`.
    static let noticesFileName = "THIRD_PARTY_NOTICES.md"

    static var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    /// «Версия 0.1.0 (сборка 1)» — одна строка для Настроек и окна «О Chronica».
    static var versionLine: String { versionLine(shortVersion: shortVersion, build: build) }

    /// Чистое формирование строки версии.
    ///
    /// Вынесено из `versionLine`, потому что в `swift run`/тестах ключей
    /// Info.plist нет: подстановка «—» вместо пустых скобок — это поведение,
    /// которое проверяется тестом, а не деталь чтения бандла.
    static func versionLine(shortVersion: String, build: String) -> String {
        L("about.versionLine", shortVersion, build)
    }

    /// Строка авторства окна «О Chronica».
    static var author: String {
        L("about.author", comment: "Authorship line in the About window")
    }

    /// Куда открывать «Сторонние компоненты».
    ///
    /// В собранном .app файл лежит в `Contents/Resources` (его кладёт
    /// `package-app.sh` — требование лицензий поставлять текст вместе с
    /// бинарной дистрибуцией). В dev-сборке через `swift run` бандла нет,
    /// поэтому честно уходим на GitHub, а не открываем пустоту.
    static func noticesTarget(bundledPath: String?) -> URL {
        if let bundledPath { return URL(fileURLWithPath: bundledPath) }
        return repositoryURL.appendingPathComponent("blob/main/\(noticesFileName)")
    }

    /// Боевой вариант: путь ищется в ресурсах бандла.
    static var noticesTarget: URL {
        noticesTarget(bundledPath: Bundle.main.path(forResource: "THIRD_PARTY_NOTICES",
                                                    ofType: "md"))
    }
}

// MARK: - Период журнала → границы запроса

/// Чистое преобразование «выбранный период (от/по) → границы запроса ядра».
///
/// Пикеры дают ДНИ, а хранилище сравнивает строки времени лексикографически,
/// поэтому границы обязаны быть локальным ISO со смещением зоны
/// (`Fmt.queryBound`): начало дня `from` и начало СЛЕДУЮЩЕГО за `to` дня
/// (полуинтервал `[start, end)` — день `to` попадает целиком).
enum JournalPeriod {
    /// Границы как `Date` в локальной зоне.
    static func bounds(from: Date, to: Date,
                       calendar: Calendar = Calendar.current) -> (start: Date, end: Date) {
        // Перевёрнутый выбор («по» раньше «от») не должен давать пустой период.
        let lo = min(from, to), hi = max(from, to)
        let start = calendar.startOfDay(for: lo)
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: hi))
            ?? hi
        return (start, end)
    }

    /// Границы как строки для `engine.intervals*/voiceActivity*`.
    static func isoBounds(from: Date, to: Date,
                          calendar: Calendar = Calendar.current) -> (start: String, end: String) {
        let b = bounds(from: from, to: to, calendar: calendar)
        return (Fmt.queryBound(b.start), Fmt.queryBound(b.end))
    }

    /// Гранулярность графика активности: до 2 суток включительно — по часам,
    /// дальше — по дням (иначе 300+ столбцов превращаются в кашу).
    static func isHourly(from: Date, to: Date,
                         calendar: Calendar = Calendar.current) -> Bool {
        let b = bounds(from: from, to: to, calendar: calendar)
        return b.end.timeIntervalSince(b.start) <= 2 * 86_400
    }
}

// MARK: - Channel meta

enum Channels {
    static let mic = "mic"
    static let remote = "remote"
    static func label(_ id: String) -> String {
        id == remote ? L("channel.system") : L("channel.mic")
    }
}
