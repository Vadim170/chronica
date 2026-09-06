import XCTest
@testable import Chronica

/// Поведенческие тесты строки-«хвоста» живой ленты.
///
/// Контракт после упрощения интерфейса: строка говорит, ЧТО СЕЙЧАС происходит
/// (обрабатываю / тишина / слушаю), и НЕ показывает никаких чисел. Раньше сюда
/// подмешивалась глубина очереди — техническая деталь, которая пользователю
/// ничего не объясняла, а в старом баге ещё и печатала счётчик сэмплов
/// («обрабатываю… (1640658 в очереди)»). Текст сверяем с ключами каталога —
/// интерфейс локализован, литералы одного языка тест бы сломали.
final class LiveTailTests: XCTestCase {

    func testQueuedWorkReportsProcessing() {
        XCTAssertEqual(LiveTail.text(bgQueueDepth: 3, channelsSilent: false),
                       L("live.processing"))
        // Непустая очередь важнее тишины на дорожках.
        XCTAssertEqual(LiveTail.text(bgQueueDepth: 1, channelsSilent: true),
                       L("live.processing"))
    }

    func testSilentWhenNothingQueuedAndChannelsSilent() {
        XCTAssertEqual(LiveTail.text(bgQueueDepth: 0, channelsSilent: true), L("live.silence"))
    }

    func testListeningWhenIdleQueueAndNotSilent() {
        XCTAssertEqual(LiveTail.text(bgQueueDepth: 0, channelsSilent: false), L("live.listening"))
    }

    func testNoNumbersLeakIntoTheStatusLine() {
        // Любая глубина очереди даёт один и тот же текст без цифр.
        for depth: UInt32 in [1, 4, 64, 1_640_658] {
            let text = LiveTail.text(bgQueueDepth: depth, channelsSilent: false)
            XCTAssertEqual(text, L("live.processing"))
            XCTAssertFalse(text.contains(where: \.isNumber),
                           "в строке состояния не должно быть чисел")
        }
    }
}
