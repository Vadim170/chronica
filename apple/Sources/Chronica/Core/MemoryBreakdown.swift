import Foundation
import Darwin

/// Разбор расхода памяти процесса по понятным КАТЕГОРИЯМ для подсказки на
/// показателе RAM. Цель — объяснить обычными словами, на что уходит текущий
/// RSS: на саму модель распознавания, на рабочую память во время обработки
/// звука, на поиск по смыслу и на само приложение.
///
/// Категории строятся из РЕАЛЬНЫХ якорей: базовый RSS (замер на старте, до
/// загрузки модели), размер весов модели на диске и текущий RSS. Остаток
/// относится к рабочей памяти распознавания. Цифры приблизительные (помечены
/// «≈»), но дают честную картину распределения. Названия категорий намеренно
/// без внутренних терминов (ORT, «арена активаций», NLEmbedding) — подсказку
/// читает пользователь, а не разработчик.

// MARK: - Чтение RSS процесса (mach)

enum ProcessMemory {
    /// Текущий резидентный набор (RSS) процесса в байтах. `nil` при ошибке.
    static func currentRSSBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.resident_size : nil
    }
}

// MARK: - Флаг загрузки модели семантического поиска

/// Лёгкий потокобезопасный «маяк»: загружена ли сейчас модель семантического
/// поиска (`NLEmbedding`). `SemanticSearchEngine` обновляет его при загрузке/
/// выгрузке, а разбор памяти читает — чтобы корректно отнести её расход в
/// отдельную категорию (поиск живёт в другом контексте — в Журнале).
final class SearchMemoryProbe: @unchecked Sendable {
    static let shared = SearchMemoryProbe()
    private let lock = NSLock()
    private var _loaded = false
    var loaded: Bool { lock.lock(); defer { lock.unlock() }; return _loaded }
    func setLoaded(_ value: Bool) { lock.lock(); _loaded = value; lock.unlock() }
}

// MARK: - Чистая логика разбора (тестируемо)

/// Одна категория расхода памяти.
struct MemoryCategory: Equatable {
    let title: String
    let bytes: UInt64
    let detail: String
    /// Значение приблизительное (показывать «≈»).
    let estimated: Bool
    /// Категория сейчас активна (для модели поиска: загружена ли). При `false`
    /// показываем «не загружена» вместо числа.
    let present: Bool
}

enum MemoryBreakdownLogic {
    /// Оценка резидентного расхода моделей `NLEmbedding` (ru+en) когда загружены.
    static let searchModelEstimateBytes: UInt64 = 300 * 1_048_576

    /// Человекочитаемый размер: «652 МБ» / «1.6 ГБ». Единица локализована.
    static func fmtBytes(_ b: UInt64) -> String {
        let mb = Double(b) / 1_048_576
        if mb >= 1024 { return String(format: "%.1f ", mb / 1024) + L("unit.gigabytes") }
        return String(format: "%.0f ", mb) + L("unit.megabytes")
    }

    /// Категории, в сумме приблизительно равные `totalBytes`.
    /// - app: базовый расход (замер на старте, до модели).
    /// - search: оценка памяти поиска по смыслу, если он загружен (иначе 0).
    /// - weights: веса модели распознавания на диске (зажаты остатком).
    /// - runtime: всё остальное — рабочая память распознавания.
    static func categories(totalBytes: UInt64,
                           baselineBytes: UInt64,
                           modelWeightsBytes: UInt64,
                           modelTitle: String,
                           searchLoaded: Bool) -> [MemoryCategory] {
        let total = totalBytes
        let app = min(baselineBytes, total)
        let search = searchLoaded ? min(searchModelEstimateBytes, total) : 0
        let weightsRoom = total > app + search ? total - app - search : 0
        let weights = min(modelWeightsBytes, weightsRoom)
        let used = app + search + weights
        let runtime = total > used ? total - used : 0

        return [
            MemoryCategory(
                title: L("memory.cat.model", modelTitle),
                bytes: weights,
                detail: L("memory.cat.model.detail"),
                estimated: false, present: true),
            MemoryCategory(
                title: L("memory.cat.runtime"),
                bytes: runtime,
                detail: L("memory.cat.runtime.detail"),
                estimated: true, present: true),
            MemoryCategory(
                title: L("memory.cat.search"),
                bytes: search,
                detail: L("memory.cat.search.detail"),
                estimated: true, present: searchLoaded),
            MemoryCategory(
                title: L("memory.cat.app"),
                bytes: app,
                detail: L("memory.cat.app.detail"),
                estimated: true, present: true),
        ]
    }

    /// Готовый многострочный текст для всплывающей подсказки (`.help`).
    static func summaryText(totalBytes: UInt64,
                            baselineBytes: UInt64,
                            modelWeightsBytes: UInt64,
                            modelTitle: String,
                            searchLoaded: Bool) -> String {
        let total = totalBytes
        let cats = categories(totalBytes: total, baselineBytes: baselineBytes,
                              modelWeightsBytes: modelWeightsBytes, modelTitle: modelTitle,
                              searchLoaded: searchLoaded)
        var lines: [String] = [L("memory.total", fmtBytes(total)), ""]
        for c in cats {
            lines.append("• \(c.title)")
            if !c.present {
                lines.append("   " + L("memory.notLoaded", c.detail,
                                       fmtBytes(searchModelEstimateBytes)))
            } else {
                let pct = total > 0 ? Int((Double(c.bytes) / Double(total) * 100).rounded()) : 0
                let prefix = c.estimated ? "≈" : ""
                lines.append("   " + L("memory.category.line", prefix,
                                       fmtBytes(c.bytes), pct, c.detail))
            }
        }
        return lines.joined(separator: "\n")
    }
}
