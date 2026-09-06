import XCTest
import AppKit
@testable import Chronica

/// Поведенческие контракты lifecycle панели без создания реального NSPanel.
/// AppKit-интеграция остаётся тонким исполнителем чистого reducer-а.
final class PanelStateTests: XCTestCase {
    func testToggleOpensThenSecondToggleClosesWithNewGeneration() {
        let opening = PanelStateReducer.reduce(PanelState(), .toggle)
        XCTAssertEqual(opening.phase, .opening)
        XCTAssertEqual(opening.generation, 1)

        let closing = PanelStateReducer.reduce(opening, .toggle)
        XCTAssertEqual(closing.phase, .closing)
        XCTAssertEqual(closing.generation, 2)
    }

    func testStaleAnimationCompletionsCannotChangeCurrentPhase() {
        let opening = PanelStateReducer.reduce(PanelState(), .toggle)
        let closing = PanelStateReducer.reduce(opening, .toggle)

        XCTAssertEqual(
            PanelStateReducer.reduce(closing, .openingFinished(opening.generation)),
            closing
        )
        XCTAssertEqual(
            PanelStateReducer.reduce(closing, .closingFinished(opening.generation)),
            closing
        )

        let closed = PanelStateReducer.reduce(closing, .closingFinished(closing.generation))
        XCTAssertEqual(closed.phase, .closed)
    }

    func testRapidCloseThenReopenInvalidatesOldCloseToken() {
        let opening = PanelStateReducer.reduce(PanelState(), .requestOpen)
        let closing = PanelStateReducer.reduce(opening, .requestClose)
        let reopened = PanelStateReducer.reduce(closing, .toggle)

        XCTAssertEqual(reopened.phase, .opening)
        XCTAssertGreaterThan(reopened.generation, closing.generation)
        XCTAssertEqual(
            PanelStateReducer.reduce(reopened, .closingFinished(closing.generation)),
            reopened
        )

        let open = PanelStateReducer.reduce(reopened, .openingFinished(reopened.generation))
        XCTAssertEqual(open.phase, .open)
    }

    func testCloseIsIdempotentAndClosedIgnoresCloseRequests() {
        let closed = PanelState()
        XCTAssertEqual(PanelStateReducer.reduce(closed, .requestClose), closed)

        let opening = PanelStateReducer.reduce(closed, .requestOpen)
        let closing = PanelStateReducer.reduce(opening, .requestClose)
        XCTAssertEqual(PanelStateReducer.reduce(closing, .requestClose), closing)

        let finished = PanelStateReducer.reduce(closing, .closingFinished(closing.generation))
        XCTAssertEqual(PanelStateReducer.reduce(finished, .requestClose), finished)
    }

    func testStatusButtonDeactivatesAsSoonAsClosingBegins() {
        XCTAssertFalse(PanelPhase.closed.isStatusButtonActive)
        XCTAssertTrue(PanelPhase.opening.isStatusButtonActive)
        XCTAssertTrue(PanelPhase.open.isStatusButtonActive)
        XCTAssertFalse(PanelPhase.closing.isStatusButtonActive)
    }

    // MARK: подсветка иконки меню-бара

    /// Тот самый баг: иконка «активируется, деактивируется и активируется
    /// снова». Между нажатием и появлением панели подсветка обязана
    /// держаться непрерывно.
    func testHighlightDoesNotDropBetweenPressAndPanelOpening() {
        var driver = StatusHighlightDriver()
        driver.press()
        XCTAssertEqual(driver.transitions, [true], "подсветка включается в момент нажатия")

        driver.panelEvent(.toggle)
        driver.resolveClick()
        driver.panelEvent(.openingFinished(driver.generation))

        XCTAssertEqual(driver.transitions, [true],
                       "между mouseUp и открытием панели не должно быть промежуточного off")
        XCTAssertTrue(driver.isActive)
    }

    /// Клик открыл панель, второй клик закрыл: ровно одно включение и ровно
    /// одно выключение, без вспышки-провала-вспышки на втором клике.
    func testClickOpenThenClickCloseGivesExactlyOneOnAndOneOff() {
        var driver = StatusHighlightDriver()
        driver.leftClick()
        driver.panelEvent(.openingFinished(driver.generation))
        XCTAssertEqual(driver.transitions, [true])

        driver.leftClick()
        XCTAssertEqual(driver.transitions, [true, false],
                       "закрывающий клик гасит иконку один раз, в конце клика")

        driver.panelEvent(.closingFinished(driver.generation))
        XCTAssertEqual(driver.transitions, [true, false])
        XCTAssertFalse(driver.isActive)
    }

    /// Закрытие снаружи, Escape и потеря key приходят одним путём
    /// (`requestClose`) и гасят иконку ровно один раз, сколько бы раз запрос
    /// ни повторился.
    func testOutsideCloseAndEscapeDeactivateExactlyOnce() {
        var driver = StatusHighlightDriver()
        driver.leftClick()
        driver.panelEvent(.openingFinished(driver.generation))

        driver.panelEvent(.requestClose)
        driver.panelEvent(.requestClose)
        driver.panelEvent(.closingFinished(driver.generation))
        driver.panelEvent(.requestClose)

        XCTAssertEqual(driver.transitions, [true, false])
        XCTAssertFalse(driver.isActive)
    }

    /// Правый / ctrl-клик: иконка активна на нажатии и гаснет один раз —
    /// после закрытия контекстного меню.
    func testRightClickStaysActiveUntilMenuCloses() {
        var driver = StatusHighlightDriver()
        driver.press()
        driver.openMenu()
        // Закрытие панели в этом пути ничего не меняет: панель уже закрыта.
        driver.panelEvent(.requestClose)
        XCTAssertEqual(driver.transitions, [true], "пока меню открыто, иконка активна")

        driver.closeMenu()
        driver.resolveClick()
        XCTAssertEqual(driver.transitions, [true, false])
        XCTAssertFalse(driver.isActive)
    }

    /// Правый клик поверх открытой панели: панель закрывается, меню
    /// открывается, иконка не гаснет в промежутке.
    func testRightClickOverOpenPanelKeepsHighlightThroughMenu() {
        var driver = StatusHighlightDriver()
        driver.leftClick()
        driver.panelEvent(.openingFinished(driver.generation))

        driver.press()
        driver.openMenu()
        driver.panelEvent(.requestClose)
        driver.panelEvent(.closingFinished(driver.generation))
        XCTAssertEqual(driver.transitions, [true],
                       "закрытие панели под открытым меню не гасит иконку")

        driver.closeMenu()
        driver.resolveClick()
        XCTAssertEqual(driver.transitions, [true, false])
    }

    /// Устаревшие и повторные завершения анимаций подсветку не переключают.
    func testStaleGenerationEventsDoNotToggleHighlight() {
        var driver = StatusHighlightDriver()
        driver.leftClick()
        let staleGeneration = driver.generation
        driver.panelEvent(.openingFinished(staleGeneration))
        driver.leftClick()
        XCTAssertEqual(driver.transitions, [true, false])

        driver.panelEvent(.openingFinished(staleGeneration))
        driver.panelEvent(.closingFinished(staleGeneration))
        driver.panelEvent(.closingFinished(driver.generation))
        driver.panelEvent(.closingFinished(driver.generation))

        XCTAssertEqual(driver.transitions, [true, false])
        XCTAssertFalse(driver.isActive)
    }

    /// Контракт порядка: нажатие снимается ПОСЛЕ маршрутизации клика. Если
    /// снять раньше, появляется лишний `off` между mouseUp и открытием
    /// панели — ровно то мигание, которое лечил этот раунд.
    func testClickResolvedBeforeRoutingWouldDropHighlight() {
        var wrongOrder = StatusHighlightDriver()
        wrongOrder.press()
        wrongOrder.resolveClick()
        wrongOrder.panelEvent(.toggle)
        XCTAssertEqual(wrongOrder.transitions, [true, false, true])

        var correctOrder = StatusHighlightDriver()
        correctOrder.press()
        correctOrder.panelEvent(.toggle)
        correctOrder.resolveClick()
        XCTAssertEqual(correctOrder.transitions, [true])
    }

    /// Повторные события идемпотентны, а иконка гаснет только когда исчезла
    /// ПОСЛЕДНЯЯ причина подсветки.
    func testHighlightNeedsAllReasonsGoneToDeactivate() {
        var state = StatusHighlightState()
        XCTAssertFalse(state.isActive)

        state = StatusHighlightReducer.reduce(state, .buttonPressed)
        XCTAssertTrue(state.isActive)
        XCTAssertEqual(StatusHighlightReducer.reduce(state, .buttonPressed), state)

        state = StatusHighlightReducer.reduce(state, .menuOpened)
        XCTAssertEqual(StatusHighlightReducer.reduce(state, .menuOpened), state)
        state = StatusHighlightReducer.reduce(state, .panelPhaseChanged(.open))
        XCTAssertEqual(StatusHighlightReducer.reduce(state, .panelPhaseChanged(.open)), state)

        state = StatusHighlightReducer.reduce(state, .clickResolved)
        XCTAssertTrue(state.isActive, "меню и панель ещё держат подсветку")
        state = StatusHighlightReducer.reduce(state, .menuClosed)
        XCTAssertTrue(state.isActive, "панель ещё открыта")
        state = StatusHighlightReducer.reduce(state, .panelPhaseChanged(.closing))
        XCTAssertFalse(state.isActive)
    }

    // MARK: подсветка на ЖИВОЙ кнопке AppKit

    /// Главный контракт раунда. Чистые редьюсеры сами по себе мигание не
    /// лечили: AppKit гасит подсветку статусной кнопки СВОИМ вызовом сразу
    /// после возврата из action, и восстановление «следующим шагом» опаздывало
    /// на монтаж SwiftUI-ветки панели (~100 мс тёмной иконки). Здесь тот же
    /// сброс от AppKit подаётся на настоящую ячейку — и он не должен
    /// отражаться на кнопке, пока подсветка нужна модели.
    @MainActor
    func testLiveButtonDoesNotBlinkWhenAppKitClearsHighlightAfterAction() {
        let driver = LiveHighlightDriver()
        defer { driver.release() }

        driver.leftClick()
        driver.panelEvent(.openingFinished(driver.generation))

        XCTAssertEqual(driver.transitions, [true],
                       "сброс подсветки от AppKit не должен доходить до иконки")
        XCTAssertTrue(driver.isVisiblyActive)
    }

    /// Полный цикл «клик открыл — клик закрыл» на живой кнопке: ровно одно
    /// включение и ровно одно выключение, включая сбросы от AppKit.
    @MainActor
    func testLiveButtonGivesExactlyOneOnAndOneOffPerOpenCloseCycle() {
        let driver = LiveHighlightDriver()
        defer { driver.release() }

        driver.leftClick()
        driver.panelEvent(.openingFinished(driver.generation))
        XCTAssertEqual(driver.transitions, [true])

        driver.leftClick()
        XCTAssertEqual(driver.transitions, [true, false])

        driver.panelEvent(.closingFinished(driver.generation))
        XCTAssertEqual(driver.transitions, [true, false])
        XCTAssertFalse(driver.isVisiblyActive)
    }

    /// Правый клик: пока висит контекстное меню, иконка активна, а сброс от
    /// AppKit её не гасит.
    @MainActor
    func testLiveButtonStaysActiveWhileContextMenuIsOpen() {
        let driver = LiveHighlightDriver()
        defer { driver.release() }

        driver.press()
        driver.openMenu()
        driver.panelEvent(.requestClose)
        driver.appKitClearsHighlight()
        XCTAssertEqual(driver.transitions, [true], "меню держит иконку активной")

        driver.closeMenu()
        driver.resolveClick()
        XCTAssertEqual(driver.transitions, [true, false])
        XCTAssertFalse(driver.isVisiblyActive)
    }

    /// Удержание — свойство ОДНОГО объекта: подмена класса ячейки не влияет ни
    /// на какие другие кнопки процесса.
    @MainActor
    func testPinAffectsOnlyItsOwnButtonCell() {
        let pinned = NSButton(title: "", target: nil, action: nil)
        let other = NSButton(title: "", target: nil, action: nil)
        XCTAssertTrue(StatusHighlightPin.install(on: pinned),
                      "без подмены класса подсветку удержать нечем")
        StatusHighlightPin.apply(true, to: pinned)
        defer { StatusHighlightPin.apply(false, to: pinned) }

        other.highlight(true)
        other.cell?.highlight(false, withFrame: other.bounds, in: other)
        XCTAssertFalse(other.cell?.isHighlighted ?? true,
                       "обычная кнопка гасится как обычно")

        pinned.cell?.highlight(false, withFrame: pinned.bounds, in: pinned)
        XCTAssertTrue(pinned.cell?.isHighlighted ?? false,
                      "у своей кнопки сброс не проходит, пока подсветка нужна")
    }

    /// Снятие удержания обязано пропускать НАШ собственный сброс — иначе
    /// иконка залипла бы включённой навсегда.
    @MainActor
    func testReleasingThePinLetsTheHighlightGoOff() {
        let button = NSButton(title: "", target: nil, action: nil)
        StatusHighlightPin.apply(true, to: button)
        XCTAssertTrue(button.cell?.isHighlighted ?? false)

        StatusHighlightPin.apply(false, to: button)
        XCTAssertFalse(button.cell?.isHighlighted ?? true)

        // И повторное включение после снятия работает.
        StatusHighlightPin.apply(true, to: button)
        XCTAssertTrue(button.cell?.isHighlighted ?? false)
        StatusHighlightPin.apply(false, to: button)
        XCTAssertFalse(button.cell?.isHighlighted ?? true)
    }

    func testStatusItemFrameIsIgnoredByOutsideClickRouting() {
        let frame = NSRect(x: 100, y: 900, width: 32, height: 24)
        XCTAssertTrue(PanelInputRouting.isInsideStatusItemFrame(
            NSPoint(x: 116, y: 912),
            frame: frame
        ))
        XCTAssertFalse(PanelInputRouting.isInsideStatusItemFrame(
            NSPoint(x: 116, y: 870),
            frame: frame
        ))
    }

    @MainActor
    func testVisibilityModelPublishesOnlyRealChanges() {
        let model = PanelVisibilityModel()
        XCTAssertFalse(model.isPresented)
        model.setPresented(true)
        XCTAssertTrue(model.isPresented)
        model.setPresented(true)
        XCTAssertTrue(model.isPresented)
        model.setPresented(false)
        XCTAssertFalse(model.isPresented)
    }
}

/// Тест-драйвер подсветки статусной иконки.
///
/// Повторяет связку двух чистых редьюсеров из `AppDelegate`: событие панели
/// проходит через `PanelStateReducer`, и подсветка узнаёт только о ПРИНЯТЫХ
/// переходах (устаревшие поколения до неё не доходят). Пишет ИЗМЕНЕНИЯ
/// `isActive` — то, что пользователь видит как «загорелась / погасла», а не
/// число вызовов AppKit.
private struct StatusHighlightDriver {
    private(set) var panel = PanelState()
    private(set) var highlight = StatusHighlightState()
    /// Последовательность изменений подсветки; начальное состояние — погашено.
    private(set) var transitions: [Bool] = []

    var isActive: Bool { highlight.isActive }
    var generation: UInt64 { panel.generation }

    /// mouseDown по иконке.
    mutating func press() { send(.buttonPressed) }
    /// Конец обработки клика (после маршрутизации, как в `statusItemClicked`).
    mutating func resolveClick() { send(.clickResolved) }
    mutating func openMenu() { send(.menuOpened) }
    mutating func closeMenu() { send(.menuClosed) }

    mutating func panelEvent(_ event: PanelEvent) {
        let next = PanelStateReducer.reduce(panel, event)
        guard next != panel else { return }
        panel = next
        send(.panelPhaseChanged(next.phase))
    }

    /// Полный левый клик: нажатие → toggle на mouseUp → снятие нажатия.
    mutating func leftClick() {
        press()
        panelEvent(.toggle)
        resolveClick()
    }

    private mutating func send(_ event: StatusHighlightEvent) {
        let before = highlight.isActive
        highlight = StatusHighlightReducer.reduce(highlight, event)
        if highlight.isActive != before { transitions.append(highlight.isActive) }
    }
}

/// Тот же драйвер, но подсветка применяется к НАСТОЯЩЕЙ кнопке AppKit через
/// `StatusHighlightPin`, а `transitions` пишутся по фактическому состоянию
/// ячейки. Дополнительно воспроизводится сброс, который AppKit делает сам
/// сразу после возврата из action статусной кнопки, — именно он и давал
/// мигание.
@MainActor
private final class LiveHighlightDriver {
    let button = NSButton(title: "", target: nil, action: nil)
    private(set) var transitions: [Bool] = []
    private var panel = PanelState()
    private var highlight = StatusHighlightState()

    var generation: UInt64 { panel.generation }
    var isVisiblyActive: Bool { button.cell?.isHighlighted ?? false }

    func press() { send(.buttonPressed) }
    func resolveClick() { send(.clickResolved) }
    func openMenu() { send(.menuOpened) }
    func closeMenu() { send(.menuClosed) }

    func panelEvent(_ event: PanelEvent) {
        let next = PanelStateReducer.reduce(panel, event)
        guard next != panel else { return }
        panel = next
        send(.panelPhaseChanged(next.phase))
    }

    /// AppKit гасит подсветку статусной кнопки сам — этим самым вызовом.
    func appKitClearsHighlight() {
        button.cell?.highlight(false, withFrame: button.bounds, in: button)
        record()
    }

    /// Левый клик целиком: нажатие → toggle на mouseUp → снятие нажатия →
    /// сброс от AppKit после возврата из action.
    func leftClick() {
        press()
        panelEvent(.toggle)
        resolveClick()
        appKitClearsHighlight()
    }

    /// Снять удержание, чтобы глобальное состояние не утекало в другие тесты.
    func release() { StatusHighlightPin.apply(false, to: button) }

    private func send(_ event: StatusHighlightEvent) {
        highlight = StatusHighlightReducer.reduce(highlight, event)
        StatusHighlightPin.apply(highlight.isActive, to: button)
        record()
    }

    private func record() {
        if transitions.last != isVisiblyActive { transitions.append(isVisiblyActive) }
    }
}
