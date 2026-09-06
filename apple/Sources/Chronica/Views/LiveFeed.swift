import SwiftUI
import TranscriberCore

/// Статус живой ленты реплик.
///
/// Отдельного раздела «Live» в окне больше нет, а сама лента панели меню-бара
/// собирается общей логикой `JournalFeed` (хвост истории из хранилища + живые
/// события текущей сессии), поэтому здесь остался только «хвост» статуса.

/// Чистое форматирование строки-«хвоста» статуса ленты во время записи.
///
/// Счётчик очереди берётся ТОЛЬКО из `MetricsSnapshot.bgQueueDepth` — числа
/// интервалов, ожидающих транскрибации. `SourceMetrics.queueSize` (сырые
/// сэмплы аудиобуфера) сюда попадать не должен: он давал абсурдные «1640658».
enum LiveTail {
    /// - Parameters:
    ///   - bgQueueDepth: интервалы в очереди на транскрибацию (`metrics.bgQueueDepth`).
    ///   - channelsSilent: все ли дорожки сейчас молчат.
    /// - Returns: «обрабатываю…» при непустой очереди, иначе «тишина…» при
    ///   молчании и «слушаю…» в остальных случаях.
    static func text(bgQueueDepth: UInt32, channelsSilent: Bool) -> String {
        if bgQueueDepth > 0 { return L("live.processing") }
        if channelsSilent { return L("live.silence") }
        return L("live.listening")
    }
}
