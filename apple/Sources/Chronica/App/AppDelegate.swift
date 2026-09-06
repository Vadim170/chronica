import AppKit
import SwiftUI
import Combine
import ObjectiveC
import TranscriberCore

/// Состояние стеклянной панели в меню-баре.
///
/// Это намеренно чистая модель: AppKit-анимации и мониторы лишь исполняют
/// переходы, но не определяют их. `generation` меняется на каждом новом
/// запросе показа/скрытия и отбрасывает устаревшие completion-callbacks.
enum PanelPhase: Equatable {
    case closed
    case opening
    case open
    case closing

    /// Панель — одна из причин подсветки кнопки меню-бара: пока она
    /// открывается или открыта, иконка активна; при начале закрытия эта
    /// причина исчезает. Остальные причины — в `StatusHighlightState`.
    var isStatusButtonActive: Bool {
        self == .opening || self == .open
    }
}

/// Снимок состояния панели с поколением перехода.
struct PanelState: Equatable {
    let phase: PanelPhase
    let generation: UInt64

    init(phase: PanelPhase = .closed, generation: UInt64 = 0) {
        self.phase = phase
        self.generation = generation
    }
}

/// События, которые приходят от кнопки, панели и системных уведомлений.
enum PanelEvent: Equatable {
    case toggle
    case requestOpen
    case requestClose
    case openingFinished(UInt64)
    case closingFinished(UInt64)
}

/// Чистый reducer жизненного цикла панели. UI-тесты проверяют этот контракт
/// без создания NSPanel, NSEvent или SwiftUI-хостинга.
enum PanelStateReducer {
    static func reduce(_ state: PanelState, _ event: PanelEvent) -> PanelState {
        switch event {
        case .toggle:
            switch state.phase {
            case .closed, .closing:
                return PanelState(phase: .opening, generation: next(state.generation))
            case .opening, .open:
                return PanelState(phase: .closing, generation: next(state.generation))
            }

        case .requestOpen:
            switch state.phase {
            case .closed, .closing:
                return PanelState(phase: .opening, generation: next(state.generation))
            case .opening, .open:
                return state
            }

        case .requestClose:
            switch state.phase {
            case .closed, .closing:
                return state
            case .opening, .open:
                return PanelState(phase: .closing, generation: next(state.generation))
            }

        case let .openingFinished(token):
            guard state.phase == .opening, state.generation == token else { return state }
            return PanelState(phase: .open, generation: state.generation)

        case let .closingFinished(token):
            guard state.phase == .closing, state.generation == token else { return state }
            return PanelState(phase: .closed, generation: state.generation)
        }
    }

    private static func next(_ generation: UInt64) -> UInt64 {
        generation == .max ? 0 : generation + 1
    }
}

/// Причины, по которым иконка меню-бара подсвечена.
///
/// Подсветка — производная состояния, но причин у неё ТРИ, и это
/// принципиально. `NSStatusBarButton` подсвечивается сам на mouseDown и сам
/// гасит `isHighlighted` СРАЗУ ПОСЛЕ возврата из action (проверено на живой
/// кнопке: в action `isHighlighted == true`, после возврата — `false`).
/// Поэтому одного «панель открыта» мало: между отпусканием кнопки и первым
/// принятым переходом панели подсветка обязана держаться на факте нажатия, а
/// при правом клике — на факте открытого меню. Пока хотя бы одна причина в
/// силе, иконка активна — как у нативных меню-бар приложений, где подсветка
/// не проваливается между нажатием и появлением меню.
struct StatusHighlightState: Equatable {
    /// Кнопку нажали, но клик ещё не разрешён: решение toggle принимается на
    /// mouseUp, в `AppDelegate.statusItemClicked`.
    var isPressed: Bool = false
    /// Фаза панели — та же, что в `PanelState`.
    var panelPhase: PanelPhase = .closed
    /// Открыто контекстное меню (правый / ctrl-клик).
    var isMenuOpen: Bool = false

    /// Итоговое значение для `NSStatusBarButton.highlight(_:)`.
    var isActive: Bool {
        isPressed || panelPhase.isStatusButtonActive || isMenuOpen
    }
}

/// События, меняющие причины подсветки.
enum StatusHighlightEvent: Equatable {
    /// mouseDown по иконке меню-бара.
    case buttonPressed
    /// Клик разрешён: панель переключена или меню показано и закрыто.
    case clickResolved
    /// Панель приняла переход (устаревшие поколения `PanelStateReducer`
    /// отбрасывает, поэтому сюда они не доходят).
    case panelPhaseChanged(PanelPhase)
    case menuOpened
    case menuClosed
}

/// Чистый reducer подсветки статусной иконки. Тесты проверяют именно
/// ПОСЛЕДОВАТЕЛЬНОСТЬ значений `isActive` — пользователь видит её как
/// «загорелась → погасла» и любой лишний `false` внутри клика есть баг.
///
/// ВАЖЕН ПОРЯДОК событий: `clickResolved` отправляется ПОСЛЕ маршрутизации
/// клика. Если снять нажатие раньше, между mouseUp и началом открытия панели
/// появится провал — ровно то мигание, из-за которого иконка «активируется,
/// деактивируется и активируется снова».
enum StatusHighlightReducer {
    static func reduce(_ state: StatusHighlightState,
                       _ event: StatusHighlightEvent) -> StatusHighlightState {
        var next = state
        switch event {
        case .buttonPressed:
            next.isPressed = true
        case .clickResolved:
            next.isPressed = false
        case let .panelPhaseChanged(phase):
            next.panelPhase = phase
        case .menuOpened:
            next.isMenuOpen = true
        case .menuClosed:
            next.isMenuOpen = false
        }
        return next
    }
}

/// Удержание подсветки статусной кнопки: AppKit не должен иметь возможности
/// её погасить.
///
/// `NSStatusBarButton` гасит `isHighlighted` сам — СРАЗУ ПОСЛЕ возврата из
/// action, то есть уже после того, как мы выставили нужное значение. Схема
/// «поставили → AppKit погасил → мы вернули следующим шагом» ноля не даёт:
/// шаг main-очереди выполняется ПОСЛЕ монтажа тяжёлой SwiftUI-ветки панели,
/// который встаёт в ту же очередь раньше. Замер зондом на живом статус-айтеме:
/// иконка оставалась погашенной ~100 мс на клик, и за это время CoreAnimation
/// коммитил ~1000 кадров с тёмной иконкой — это и есть видимое мигание.
///
/// Поэтому подсветку здесь не «возвращают», а НЕ ДАЮТ снять: класс ОДНОГО
/// объекта — ячейки статусной кнопки — подменяется на созданный в рантайме
/// подкласс, который игнорирует `highlight(false)`, пока подсветка нужна
/// модели. Это тот же приём, которым пользуется KVO (`NSKVONotifying_*`):
/// глобальные методы AppKit не патчатся, другие ячейки процесса не
/// затрагиваются, а переопределяется ПУБЛИЧНЫЙ метод
/// `NSCell.highlight(_:withFrame:in:)` — приватных имён в коде нет, класс
/// ячейки берётся у объекта в рантайме.
///
/// Если подменить класс не удалось (метод исчез на будущей macOS, класс не
/// даёт наследоваться), `install` вернёт `false` и поведение деградирует до
/// прежнего: подсветку восстановит блок run loop в `statusItemClicked`.
///
/// Всё — только главный поток (AppKit).
enum StatusHighlightPin {
    /// Суффикс имени подкласса; по нему же узнаём уже подменённую ячейку.
    private static let suffix = "_ChronicaHighlightPinned"
    /// Пока `true`, ячейка не даёт себя погасить.
    private static var isPinned = false

    /// Применить состояние подсветки к кнопке.
    ///
    /// Порядок обязателен: пин снимается ДО `highlight(false)`, иначе подкласс
    /// проглотил бы наш собственный сброс и иконка залипла бы включённой.
    static func apply(_ active: Bool, to button: NSButton) {
        isPinned = active
        install(on: button)
        button.highlight(active)
    }

    /// Подменить класс ячейки кнопки. Идемпотентно.
    @discardableResult
    static func install(on button: NSButton) -> Bool {
        guard let cell = button.cell, let current: AnyClass = object_getClass(cell) else {
            return false
        }
        let currentName = NSStringFromClass(current)
        if currentName.hasSuffix(suffix) { return true }
        let name = currentName + suffix
        if let ready = NSClassFromString(name) {
            object_setClass(cell, ready)
            return true
        }
        let selector = #selector(NSCell.highlight(_:withFrame:in:))
        guard let method = class_getInstanceMethod(current, selector),
              let encoding = method_getTypeEncoding(method),
              let subclass: AnyClass = objc_allocateClassPair(current, name, 0) else {
            return false
        }
        typealias Original = @convention(c) (AnyObject, Selector, Bool, NSRect, AnyObject) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let replacement: @convention(block) (AnyObject, Bool, NSRect, AnyObject) -> Void = {
            cell, flag, frame, view in
            // Сброс, пока подсветка нужна модели, до AppKit просто не доходит.
            guard flag || !isPinned else { return }
            original(cell, selector, flag, frame, view)
        }
        guard class_addMethod(subclass, selector,
                              imp_implementationWithBlock(replacement), encoding) else {
            objc_disposeClassPair(subclass)
            return false
        }
        objc_registerClassPair(subclass)
        object_setClass(cell, subclass)
        return true
    }
}

/// Общая SwiftUI-модель видимости панели меню-бара.
///
/// `PopoverView` держит лёгкую оболочку при `isPresented == false` и монтирует
/// live/data-heavy ветку только после того, как AppKit вывел окно вперёд.
/// Модель отделена от `PanelState`, чтобы SwiftUI не наблюдала токены
/// переходов и детали AppKit.
@MainActor
final class PanelVisibilityModel: ObservableObject {
    @Published private(set) var isPresented = false

    func setPresented(_ presented: Bool) {
        guard isPresented != presented else { return }
        isPresented = presented
    }
}

/// Геометрия входных событий панели, вынесенная в чистую функцию для тестов.
enum PanelInputRouting {
    static func isInsideStatusItemFrame(_ point: NSPoint, frame: NSRect) -> Bool {
        frame.contains(point)
    }

    /// Экранная точка события мыши. У событий без окна (`event.window == nil`,
    /// глобальные мониторы) экранные координаты берём из `NSEvent`.
    static func screenPoint(of event: NSEvent) -> NSPoint {
        guard let window = event.window else { return NSEvent.mouseLocation }
        return window.convertPoint(toScreen: event.locationInWindow)
    }
}

/// Что делать по запросу выхода из приложения.
enum QuitDecision: Equatable {
    /// Ждать нечего — завершаемся немедленно.
    case terminateNow
    /// Идёт запись/остановка ядра: просим AppKit подождать, иначе теряется
    /// незакоммиченный хвост (до 5 минут аудио).
    case waitForCoreStop
}

/// Шаг ожидания остановки ядра перед выходом.
enum QuitWaitStep: Equatable {
    case keepWaiting
    case finished
    case timedOut
}

/// Чистая логика graceful quit. Проверяется тестами без AppKit и без ядра.
enum QuitPolicy {
    /// Максимум ожидания остановки ядра, после которого выходим принудительно.
    static let stopTimeoutS: TimeInterval = 5

    static func decide(hasPendingCoreWork: Bool) -> QuitDecision {
        hasPendingCoreWork ? .waitForCoreStop : .terminateNow
    }

    static func step(hasPendingCoreWork: Bool, elapsedS: TimeInterval,
                     timeoutS: TimeInterval = stopTimeoutS) -> QuitWaitStep {
        if !hasPendingCoreWork { return .finished }
        if elapsedS >= timeoutS { return .timedOut }
        return .keepWaiting
    }
}

/// Проверка того, что перезапуск поднял ИМЕННО новый процесс.
///
/// `NSWorkspace.openApplication` без `createsNewApplicationInstance` возвращает
/// текущий инстанс; следом `NSApp.terminate` просто закрывал приложение.
enum RelaunchOutcome {
    static func succeeded(newPid: pid_t?, error: Error?, currentPid: pid_t) -> Bool {
        guard error == nil, let newPid else { return false }
        return newPid != currentPid
    }
}

/// Menu-bar controller. Owns the status item, the shared Engine, the single
/// main window и стеклянный popover.
///
/// ЛЕВЫЙ клик по иконке → стеклянная панель (`NSPanel`, borderless,
/// non-activating), позиционируемая ТОЧНО под иконкой меню-бара. ПРАВЫЙ /
/// ctrl-клик → короткое нативное `NSMenu`. Глиф иконки отражает состояние
/// сессии.
///
/// #1 — НАДЁЖНОЕ ПОЗИЦИОНИРОВАНИЕ. Стандартный `NSPopover.show(...preferredEdge:
/// .minY)` в accessory-приложении периодически вставал не туда (особенно когда
/// контент оказывался выше экрана под меню-баром — AppKit двигал popover ВВЕРХ,
/// и стрелка/тело перекрывали строку меню-бара). Чтобы исключить это поведение,
/// мы вообще не полагаемся на авто-расстановку NSPopover: рисуем СОБСТВЕННОЕ
/// borderless-окно (`PanelController`) и сами считаем его кадр от
/// `statusItem.button.window.frame` в экранных координатах — центрируем по
/// кнопке, верх окна ставим строго ПОД строкой меню-бара. Высота окна
/// фиксированная (`PopoverView.popoverHeight`), поэтому окно гарантированно
/// помещается ниже меню-бара и не залезает на него.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let engine = Engine()
    /// Наблюдатель экрана (Chronica): скриншот → vision-LLM → журнал дел.
    /// Создаётся лениво в didFinishLaunching (нужен storagePath движка).
    private(set) var screenObserver: ScreenObserver!
    private let nav = Navigation()
    private var window: NSWindow?
    /// Отдельное окно технических показателей (Настройки → Дополнительно).
    private var diagnosticsWindow: NSWindow?
    /// Окно «О Chronica» (контекстное меню статус-айтема).
    private var aboutWindow: NSWindow?
    private var statusItem: NSStatusItem!
    private var cancellable: AnyCancellable?
    private var panel: PanelController?
    private let panelVisibility = PanelVisibilityModel()
    private var panelState = PanelState()
    /// Причины подсветки статусной иконки (нажатие · панель · меню).
    private var highlightState = StatusHighlightState()
    /// Монитор mouseDown по статусной кнопке — только для подсветки.
    private var statusPressMonitor: Any?
    private var appNotificationTokens: [NSObjectProtocol] = []
    private var workspaceNotificationTokens: [NSObjectProtocol] = []
    private var relaunchInFlight = false
    /// Ожидание остановки ядра перед завершением (`.terminateLater`).
    private var terminationWaitTask: Task<Void, Never>?
    private var isTerminating = false
    private var quitKeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine.boot()
        engine.setRelaunchApplicationHandler { [weak self] completion in
            self?.relaunchApplication(completion: completion)
        }
        screenObserver = ScreenObserver(storagePath: engine.storagePath)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(statusItemClicked)
            button.target = self
            // Ловим оба типа клика, чтобы развести popover (левый) и меню (правый).
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            // Подсветку держит подмена класса ячейки (`StatusHighlightPin`):
            // AppKit не должен уметь погасить её после возврата из action.
            StatusHighlightPin.apply(false, to: button)
        }

        // Создаём стекло и SwiftUI-host заранее, пока приложение спокойно
        // входит в run loop. При первом клике остаются только позиционирование
        // и orderFront; тяжёлая ветка PopoverView включится следующим тиком.
        panel = makePanel()
        installPanelNotifications()
        installStatusButtonPressMonitor()
        installPowerNotifications()
        installQuitShortcut()
        reregisterLoginItemAfterRename()
        updateStatusIcon(engine.state)

        // Reflect Engine state in the menu-bar glyph.
        cancellable = engine.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateStatusIcon($0) }
    }

    /// Однократная перерегистрация автозапуска после смены bundle id.
    ///
    /// `SMAppService` привязан к bundle id, поэтому прежняя регистрация
    /// осталась у системы под именем «Transcriber», а новая не создалась.
    /// Если пользователь держал автозапуск включённым — включаем заново под
    /// новым id. Ошибку только логируем: в неподписанной dev-сборке
    /// `register()` штатно падает, а флаг не даст дёргать её каждый запуск.
    private func reregisterLoginItemAfterRename() {
        let defaults = UserDefaults.standard
        guard LoginItemMigration.shouldReregister(
            prefEnabled: Prefs.shared.launchAtLogin,
            systemRegistered: LoginItem.shared.isEnabled,
            alreadyDone: defaults.bool(forKey: LoginItemMigration.flagKey)) else { return }
        defaults.set(true, forKey: LoginItemMigration.flagKey)
        do {
            try LoginItem.shared.setEnabled(true)
        } catch {
            NSLog("Chronica: login item re-registration failed: %@", "\(error)")
        }
    }

    // MARK: статус-айтем → popover (левый) / меню (правый)

    @objc private func statusItemClicked() {
        // Окно статус-бара может лишить non-activating панель key до mouseUp.
        // Снимаем локальную защиту перед маршрутизацией, чтобы именно mouseUp
        // оставался единственным решением toggle.
        panel?.statusButtonMouseUp()
        let isRight = NSApp.currentEvent.map { ev in
            ev.type == .rightMouseUp || ev.modifierFlags.contains(.control)
        } ?? false
        if isRight {
            // Меню объявляем открытым ДО закрытия панели: иначе подсветка
            // провалится в промежутке «панель закрылась, меню ещё не
            // показано».
            applyHighlightEvent(.menuOpened)
            closePanel()
            showContextMenu()
        } else {
            togglePanel()
        }
        // Нажатие снимаем ТОЛЬКО после маршрутизации: к этому моменту
        // причиной подсветки уже стала панель (или меню), и провала нет.
        applyHighlightEvent(.clickResolved)
        // Страховка на случай, если подмена класса ячейки не встала
        // (`StatusHighlightPin.install` вернул false): переспрашиваем модель
        // БЛОКОМ RUN LOOP. Он выполняется в том же проходе — сразу после
        // обработки события и ДО слива main-очереди, поэтому монтаж тяжёлой
        // SwiftUI-ветки панели уже не может его задержать. Прежний шаг
        // main-очереди вставал в очередь ПОСЛЕ этого монтажа и отставал на
        // ~100 мс — всё это время иконка была тёмной.
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { [weak self] in
            MainActor.assumeIsolated { self?.refreshStatusHighlight() }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    /// Стеклянная панель строго под иконкой (#1).
    private func togglePanel() {
        applyPanelEvent(.toggle)
    }

    private func makePanel() -> PanelController {
        // Панель показывает ту же ЕДИНУЮ ленту, что и окно (реплики + дела с
        // экрана), поэтому наблюдателю экрана место и здесь. Он создаётся в
        // `didFinishLaunching` ДО панели; страховка на случай иного порядка —
        // панель не имеет права падать из-за отсутствующего журнала.
        let observer = screenObserver ?? ScreenObserver(storagePath: engine.storagePath)
        screenObserver = observer

        let root = PopoverView { [weak self] section in
            self?.closePanel()
            self?.showWindow(section: section)
        }
        .environmentObject(engine)
        .environmentObject(panelVisibility)
        .environmentObject(observer)

        let controller = PanelController(
            content: root,
            width: PopoverView.popoverWidth,
            height: PopoverView.popoverHeight,
            statusButton: statusItem?.button
        )
        controller.onRequestClose = { [weak self] in
            self?.closePanel()
        }
        return controller
    }

    // MARK: panel lifecycle

    /// Единая точка закрытия панели. Сюда приходят второй клик, внешний клик,
    /// Escape, потеря key-фокуса, смена экрана/Space, навигация и выход.
    private func closePanel(immediately: Bool = false) {
        applyPanelEvent(.requestClose, immediately: immediately)
    }

    private func applyPanelEvent(_ event: PanelEvent, immediately: Bool = false) {
        let previous = panelState
        let next = PanelStateReducer.reduce(previous, event)
        guard next != previous else { return }
        panelState = next
        applyHighlightEvent(.panelPhaseChanged(next.phase))

        switch next.phase {
        case .opening:
            guard let button = statusItem?.button else {
                // Статусный item может исчезнуть только при завершении
                // приложения; не оставляем reducer в вечном `.opening`.
                applyPanelEvent(.requestClose, immediately: true)
                return
            }
            let controller = panel ?? makePanel()
            panel = controller
            panelVisibility.setPresented(false)
            controller.showShell(below: button, token: next.generation)

            // Сначала показываем shell/orderFront, затем в следующем тике
            // включаем дорогую SwiftUI-ветку и fade-in. Если за это время
            // пришёл close/reopen, поколение делает callback безопасным.
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.panelState.phase == .opening,
                      self.panelState.generation == next.generation else { return }
                self.panelVisibility.setPresented(true)
                self.panel?.animateOpen(token: next.generation) { [weak self] in
                    self?.applyPanelEvent(.openingFinished(next.generation))
                }
            }

        case .closing:
            panelVisibility.setPresented(false)
            guard let controller = panel else {
                applyPanelEvent(.closingFinished(next.generation))
                return
            }
            if immediately {
                controller.closeImmediately(token: next.generation)
                applyPanelEvent(.closingFinished(next.generation))
            } else {
                controller.animateClose(token: next.generation) { [weak self] in
                    self?.applyPanelEvent(.closingFinished(next.generation))
                }
            }

        case .open, .closed:
            // Completion-callback переводит фазу; дополнительная работа
            // AppKit здесь не нужна.
            break
        }
    }

    /// Событие подсветки: решает чистый reducer, AppKit только исполняет.
    private func applyHighlightEvent(_ event: StatusHighlightEvent) {
        // Само нажатие — единственное событие, которое приходит с зажатой
        // кнопкой мыши; перед остальными снимаем «залипшее» нажатие.
        let base = event == .buttonPressed ? highlightState : stateWithoutStalePress()
        let next = StatusHighlightReducer.reduce(base, event)
        guard next != highlightState else { return }
        highlightState = next
        applyStatusHighlight()
    }

    /// Состояние подсветки без «залипшего» нажатия.
    ///
    /// Если физической кнопки мыши уже нет, а `clickResolved` не пришёл
    /// (палец увели с иконки и отпустили мимо — action не вызывается), то
    /// нажатие больше не может быть причиной подсветки.
    private func stateWithoutStalePress() -> StatusHighlightState {
        guard highlightState.isPressed, NSEvent.pressedMouseButtons == 0 else {
            return highlightState
        }
        return StatusHighlightReducer.reduce(highlightState, .clickResolved)
    }

    /// Выставить подсветку по текущей модели.
    ///
    /// Значение выставляется ВСЕГДА, а не только на изменение: `highlight(_:)`
    /// идемпотентен, а лишний вызов дешевле рассинхрона.
    ///
    /// `highlight` даёт статусному item ту же визуальную активацию, что и
    /// нативный control меню-бара, не смешивая её с glyph/state иконки.
    /// `state`/`.pushOnPushOff` для этого не годятся: `NSStatusBarButtonCell`
    /// переключает `state` сам на каждом клике (`setNextState`), то есть спорил
    /// бы с моделью, да и фон подсветки в меню-баре от `state` не рисуется —
    /// меняется только яркость глифа (проверено зондом).
    ///
    /// Собственно удержание — в `StatusHighlightPin`: пока модель требует
    /// активности, сброс от AppKit до ячейки не доходит, поэтому тёмного кадра
    /// между нажатием и открытием панели не существует по построению.
    private func applyStatusHighlight() {
        guard let button = statusItem?.button else { return }
        StatusHighlightPin.apply(highlightState.isActive, to: button)
    }

    /// Переспросить модель и выставить подсветку заново — вне обработки
    /// события подсветки (после смены глифа и после возврата из action).
    private func refreshStatusHighlight() {
        highlightState = stateWithoutStalePress()
        applyStatusHighlight()
    }

    /// Подсветка обязана включаться В МОМЕНТ нажатия, поэтому о mouseDown
    /// модель узнаёт из локального монитора событий.
    ///
    /// Решение toggle при этом остаётся на mouseUp (`statusItemClicked`):
    /// перенести его на mouseDown нельзя — окно статус-бара лишает
    /// non-activating панель key до mouseUp, а `sendAction(on: .leftMouseDown)`
    /// у `NSStatusBarButton` не добавляет вызов на нажатии, а ЗАМЕНЯЕТ им
    /// вызов на отпускании (проверено на живой кнопке). Монитор ничего не
    /// решает и не съедает событие — только сообщает о нажатии.
    private func installStatusButtonPressMonitor() {
        statusPressMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, self.isStatusButtonEvent(event) else { return event }
            self.applyHighlightEvent(.buttonPressed)
            return event
        }
    }

    private func isStatusButtonEvent(_ event: NSEvent) -> Bool {
        guard let frame = statusItem?.button?.window?.frame else { return false }
        return PanelInputRouting.isInsideStatusItemFrame(
            PanelInputRouting.screenPoint(of: event), frame: frame)
    }

    private func installPanelNotifications() {
        let center = NotificationCenter.default
        appNotificationTokens.append(
            center.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.closePanel(immediately: true)
                }
            }
        )
        appNotificationTokens.append(
            center.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.closePanel(immediately: true)
                }
            }
        )

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceNotificationTokens.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.closePanel(immediately: true)
                }
            }
        )
    }

    /// Сон/пробуждение ноутбука. Стратегия описана в `Engine.suspendForSleep`:
    /// перед сном снимаем только захват, после пробуждения — ре-арм в той же
    /// сессии. Без этого обычное закрытие крышки оставляло «залипшее»
    /// состояние «перезапустите приложение».
    private func installPowerNotifications() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceNotificationTokens.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.engine.suspendForSleep()
                }
            }
        )
        workspaceNotificationTokens.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.engine.resumeAfterWake()
                }
            }
        )
    }

    /// Приложение — accessory без главного меню, поэтому Cmd+Q из окна или
    /// панели ловим локальным монитором и отправляем в ТОТ ЖЕ путь выхода,
    /// что и пункт «Выйти».
    private func installQuitShortcut() {
        quitKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers?.lowercased() == "q" else { return event }
            NSApp.terminate(nil)
            return nil
        }
    }

    private func removePanelNotifications() {
        for token in appNotificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        for token in workspaceNotificationTokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        appNotificationTokens.removeAll()
        workspaceNotificationTokens.removeAll()
        if let quitKeyMonitor {
            NSEvent.removeMonitor(quitKeyMonitor)
            self.quitKeyMonitor = nil
        }
        if let statusPressMonitor {
            NSEvent.removeMonitor(statusPressMonitor)
            self.statusPressMonitor = nil
        }
    }

    /// Короткое контекстное меню: только ДЕЙСТВИЯ.
    ///
    /// Строки статуса/таймера/ошибки убраны: они были неактивными пунктами,
    /// которые нельзя нажать, дублировали панель и растягивали меню. Всё
    /// состояние показывает сама панель по левому клику.
    private func showContextMenu() {
        let menu = NSMenu()

        let recording = engine.state == .recording
        menu.addItem(item(recording ? L("menu.stopRecording") : L("popover.start"),
                          #selector(toggleRecord), key: recording ? "" : "r"))
        menu.addItem(.separator())
        menu.addItem(item(L("menu.openWindow"), #selector(openWindow), key: "o"))
        menu.addItem(item(L("menu.settings"), #selector(openSettings), key: ","))
        menu.addItem(item(L("menu.about"), #selector(showAbout), key: ""))
        menu.addItem(.separator())
        // Выход через собственный метод: `item` подставляет target=self, когда
        // передан nil, а AppDelegate не отвечает на `terminate:` — поэтому
        // раньше пункт «Выйти» молча ничего не делал.
        menu.addItem(item(L("menu.quit"), #selector(quit), key: "q"))

        // Пока меню открыто, иконка обязана оставаться активной, а погаснуть —
        // один раз, когда меню закрылось. `popUp` блокирует поток, поэтому о
        // закрытии узнаём из `menuDidClose`.
        menu.delegate = self

        // Поскольку статус-айтем ловит клики через sendAction (а не через
        // привязанное меню), показываем меню вручную под кнопкой.
        if let button = statusItem.button {
            menu.popUp(positioning: nil,
                       at: NSPoint(x: 0, y: button.bounds.height + 4),
                       in: button)
        }
        // Страховка на случай, если делегат не сработал (меню не показалось):
        // событие идемпотентно.
        applyHighlightEvent(.menuClosed)
    }

    private func item(_ title: String, _ action: Selector, key: String, target: AnyObject? = nil) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = target ?? self
        return it
    }

    // MARK: actions

    @objc private func toggleRecord() {
        if engine.pipelineStalled { engine.restartApplication() }
        else if engine.state == .recording { engine.stop() } else { engine.loadModelAndStart() }
    }

    /// Launch a clean process before terminating this one. The stalled core's
    /// Rust stop may be blocked in a worker, so waiting for it here would keep
    /// the UI frozen; process relaunch is the explicit recovery action.
    private func relaunchApplication(completion: @escaping (Bool) -> Void) {
        guard !relaunchInFlight else {
            completion(false)
            return
        }
        relaunchInFlight = true
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // Без этого флага LaunchServices просто активирует ТЕКУЩИЙ процесс и
        // возвращает его же: следом `terminate` закрывал приложение совсем.
        configuration.createsNewApplicationInstance = true
        let currentPid = ProcessInfo.processInfo.processIdentifier
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL,
                                           configuration: configuration) { application, error in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.relaunchInFlight = false
                // Успех — только если поднялся ДРУГОЙ процесс. Иначе остаёмся
                // на экране с честной ошибкой вместо тихого выхода.
                let succeeded = RelaunchOutcome.succeeded(
                    newPid: application?.processIdentifier,
                    error: error,
                    currentPid: currentPid)
                completion(succeeded)
                if succeeded { NSApp.terminate(nil) }
            }
        }
    }
    @objc private func openWindow() { showWindow(section: .journal) }
    @objc private func openSettings() { showWindow(section: .settings) }

    /// «О Chronica»: отдельное небольшое окно — иконка, имя, версия,
    /// авторство, ссылка на репозиторий, честное «работает локально»,
    /// лицензия и обязательная атрибуция модели (CC-BY-4.0).
    ///
    /// Окно создаётся один раз и переиспользуется, как главное окно и
    /// «Диагностика»: повторный вызов пункта меню поднимает уже готовое.
    @objc private func showAbout() {
        closePanel()
        if aboutWindow == nil {
            let hosting = NSHostingController(rootView: AboutView(onOpenNotices: {
                NSWorkspace.shared.open(AppInfo.noticesTarget)
            }))
            let w = EscapeClosableWindow(contentViewController: hosting)
            w.title = L("window.about")
            w.styleMask = [.titled, .closable]
            w.appearance = NSAppearance(named: .darkAqua)
            w.isReleasedWhenClosed = false
            w.center()
            aboutWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        aboutWindow?.makeKeyAndOrderFront(nil)
    }

    /// Отдельное небольшое окно диагностики (Настройки → Дополнительно).
    /// Создаётся один раз и переиспользуется, как и главное окно.
    func showDiagnostics() {
        if diagnosticsWindow == nil {
            let hosting = NSHostingController(rootView: DiagnosticsView(engine: engine))
            let w = NSWindow(contentViewController: hosting)
            w.title = L("window.diagnostics")
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 460, height: 560))
            w.contentMinSize = NSSize(width: 380, height: 420)
            w.appearance = NSAppearance(named: .darkAqua)
            w.isReleasedWhenClosed = false
            w.center()
            diagnosticsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        diagnosticsWindow?.makeKeyAndOrderFront(nil)
    }
    /// Единая точка выхода: и пункт «Выйти», и Cmd+Q, и системный запрос идут
    /// через `NSApp.terminate` → `applicationShouldTerminate`.
    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// Graceful quit: пока идёт запись, нельзя завершаться синхронно — ядро
    /// дописывает незакоммиченный хвост (до 5 минут аудио). Просим AppKit
    /// подождать и отвечаем, когда ядро остановилось или истёк таймаут.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        beginShutdown()
        switch QuitPolicy.decide(hasPendingCoreWork: engine.hasPendingCoreWork) {
        case .terminateNow:
            return .terminateNow
        case .waitForCoreStop:
            waitForCoreStopBeforeTermination()
            return .terminateLater
        }
    }

    /// Гасим панель, наблюдение экрана и запись. Идемпотентно: повторный
    /// запрос выхода не перезапускает остановку.
    private func beginShutdown() {
        guard !isTerminating else { return }
        isTerminating = true
        closePanel(immediately: true)
        screenObserver?.stop()
        engine.stop()
    }

    private func waitForCoreStopBeforeTermination() {
        guard terminationWaitTask == nil else { return }
        let started = Date()
        terminationWaitTask = Task { [weak self] in
            while true {
                guard let self else { return }
                let step = QuitPolicy.step(
                    hasPendingCoreWork: self.engine.hasPendingCoreWork,
                    elapsedS: Date().timeIntervalSince(started))
                guard step == .keepWaiting else {
                    self.terminationWaitTask = nil
                    NSApp.reply(toApplicationShouldTerminate: true)
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminationWaitTask?.cancel()
        terminationWaitTask = nil
        closePanel(immediately: true)
        removePanelNotifications()
        panel?.closeImmediately()
    }

    /// Show (creating once) the single main window and select a section.
    private func showWindow(section: AppSection) {
        nav.section = section
        if window == nil {
            let root = RootView(engine: engine, observer: screenObserver, nav: nav,
                                openDiagnostics: { [weak self] in self?.showDiagnostics() })
            let hosting = NSHostingController(rootView: root)
            let w = NSWindow(contentViewController: hosting)
            w.title = AppInfo.name
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            // #7: прозрачный фон окна → сквозь контент читается оконное стекло
            // (VisualEffectView в RootView), системные углы окна остаются
            // скруглёнными, титлбар сливается с контентом (liquid glass).
            w.isOpaque = false
            w.backgroundColor = .clear
            w.setContentSize(NSSize(width: 980, height: 640))
            // #3: минимальный размер окна, чтобы боковая панель и контент не
            // схлопывались (согласован с `contentMinSize` в RootView).
            w.contentMinSize = NSSize(width: 860, height: 560)
            w.appearance = NSAppearance(named: .darkAqua)
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: status icon

    private func updateStatusIcon(_ state: SessionState) {
        guard let button = statusItem.button else { return }
        let name: String
        switch state {
        case .recording: name = "record.circle.fill"
        case .error: name = "exclamationmark.triangle"
        case .loading, .stopping: name = "waveform.circle"
        case .idle: name = "waveform"
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Chronica")
        if state == .recording {
            image?.isTemplate = false
            button.image = image?.withSymbolConfiguration(
                .init(paletteColors: [NSColor(Theme.Color.semRec)]))
        } else {
            image?.isTemplate = true
            button.image = image
        }
        // Смена глифа не должна ронять подсветку — переспрашиваем модель.
        refreshStatusHighlight()
    }
}

// MARK: - Контекстное меню статус-айтема

extension AppDelegate: NSMenuDelegate {
    /// Меню закрылось (выбором пункта, Escape или кликом мимо) — исчезла
    /// последняя причина держать иконку активной.
    func menuDidClose(_ menu: NSMenu) {
        applyHighlightEvent(.menuClosed)
    }
}

// MARK: - Стеклянная панель меню-бара (#1)

/// Borderless non-activating панель, позиционируемая ВРУЧНУЮ строго под иконкой
/// статус-айтема. Заменяет капризный `NSPopover` в accessory-приложении.
///
/// Координаты: AppKit использует систему с началом в НИЖНЕМ-ЛЕВОМ углу экрана.
/// Кадр кнопки статус-айтема берём из `button.window.frame` (окно статус-айтема
/// шириной с кнопку и расположено в строке меню-бара сверху). Низ этого окна
/// (`buttonFrame.minY`) — это нижняя кромка строки меню-бара. Значит верх нашей
/// панели = `buttonFrame.minY - gap`, и панель целиком оказывается НИЖЕ
/// меню-бара (никогда не залезает на него). По горизонтали центрируем под
/// кнопкой и зажимаем в видимую область экрана с полями.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let width: CGFloat
    private let height: CGFloat
    private weak var statusButton: NSStatusBarButton?
    /// Локальный/глобальный монитор кликов вне панели — для авто-закрытия.
    private var clickMonitor: Any?
    private var globalMonitor: Any?
    private var keyMonitor: Any?
    private var monitorsInstalled = false
    private var transitionToken: UInt64 = 0
    private var suppressNextResign = false

    /// Reducer принадлежит AppDelegate; любое закрытие извне панели вызывает
    /// этот callback, а не меняет видимость AppKit напрямую.
    var onRequestClose: (() -> Void)?

    var isVisible: Bool { panel.isVisible }

    init<Content: View>(
        content: Content,
        width: CGFloat,
        height: CGFloat,
        statusButton: NSStatusBarButton?
    ) {
        self.width = width
        self.height = height
        self.statusButton = statusButton
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            // Backing store создаётся во время prewarm при запуске, а не на
            // первом клике. Дорогая ветка SwiftUI ограждена общей
            // PanelVisibilityModel из AppDelegate.
            defer: false
        )
        super.init()

        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self

        // Стекло с гарантированным контрастом: размытие `.hudWindow` (темнее
        // `.popover`) + СВЕРХУ тёмный скрим, который «сажает» фон в тёмный
        // диапазон на любых обоях → светлый текст всегда читается.
        //
        // Доступность: при системном «Уменьшить прозрачность» стекло и скрим
        // заменяются СПЛОШНОЙ заливкой — именно тем, чего ждёт пользователь,
        // включивший этот режим.
        let radius: CGFloat = 14
        let dimming: CGFloat = 0.42
        let opaque = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = opaque ? .inactive : .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = radius
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]
        effect.frame = NSRect(x: 0, y: 0, width: width, height: height)

        let backdrop = NSView(frame: effect.bounds)
        backdrop.wantsLayer = true
        backdrop.autoresizingMask = [.width, .height]
        backdrop.layer?.backgroundColor = opaque
            ? NSColor(Theme.Color.bgBase).cgColor
            : NSColor.black.withAlphaComponent(dimming).cgColor
        effect.addSubview(backdrop)

        let hosting = NSHostingView(rootView: content)
        hosting.frame = effect.bounds
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        effect.addSubview(hosting)

        // Тонкая светлая hairline-рамка по контуру (ощущение края стекла).
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor

        panel.contentView = effect
    }

    /// Показать shell панели строго под кнопкой статус-айтема. Дорогой
    /// SwiftUI-контент AppDelegate включает следующим тиком main loop.
    func showShell(below button: NSStatusBarButton, token: UInt64) {
        transitionToken = token
        positionPanel(below: button)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        installClickMonitors()
    }

    func animateOpen(token: UInt64, completion: @escaping () -> Void) {
        guard transitionToken == token, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.completionHandler = { [weak self] in
                guard let self, self.transitionToken == token else { return }
                completion()
            }
            panel.animator().alphaValue = 1
        }
    }

    func animateClose(token: UInt64, completion: @escaping () -> Void) {
        // Запрос закрытия всегда продвигает поколение AppDelegate. Принимаем
        // новый token здесь, чтобы animation открытия сразу стала устаревшей.
        transitionToken = token
        removeClickMonitors()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.completionHandler = { [weak self] in
                guard let self, self.transitionToken == token else { return }
                self.panel.orderOut(nil)
                completion()
            }
            panel.animator().alphaValue = 0
        }
    }

    /// Немедленное скрытие используется при смене экрана/Space и завершении
    /// приложения. Инвалидирует старые animation-callbacks.
    func closeImmediately(token: UInt64? = nil) {
        transitionToken = token ?? nextToken(transitionToken)
        removeClickMonitors()
        panel.alphaValue = 0
        panel.orderOut(nil)
    }

    /// Расчёт кадра: центр по кнопке, верх — строго под строкой меню-бара,
    /// зажат в видимую область экрана.
    private func positionPanel(below button: NSStatusBarButton) {
        guard let buttonWindow = button.window else {
            panel.center(); return
        }
        // Кадр кнопки в экранных координатах (окно статус-айтема = размер кнопки).
        let buttonFrame = buttonWindow.frame
        let screen = buttonWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? buttonFrame

        let gap: CGFloat = 6
        // Центр по X под серединой кнопки.
        var originX = buttonFrame.midX - width / 2
        // Верх панели — на gap ниже нижней кромки окна кнопки (= низ меню-бара).
        let topY = buttonFrame.minY - gap
        var originY = topY - height

        // Горизонтальный зажим в видимую область с полями 8pt.
        let margin: CGFloat = 8
        originX = max(visible.minX + margin, min(originX, visible.maxX - width - margin))
        // Вертикальный зажим снизу (на случай очень низкого экрана) — но верх
        // никогда не поднимаем выше topY, чтобы не залезть на меню-бар.
        if originY < visible.minY + margin {
            originY = visible.minY + margin
        }

        panel.setFrame(NSRect(x: originX, y: originY, width: width, height: height), display: false)
    }

    // MARK: авто-закрытие по клику вне / потере фокуса

    private func installClickMonitors() {
        guard !monitorsInstalled else { return }
        monitorsInstalled = true
        // Клик внутри приложения, но вне панели.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.window !== self.panel {
                if self.isStatusItemEvent(event) {
                    // AppKit may emit windowDidResignKey for this mouseDown;
                    // statusItemClicked(mouseUp) must still perform the toggle.
                    self.suppressNextResign = true
                } else {
                    self.onRequestClose?()
                }
            }
            return event
        }
        // Клик в другом приложении / по рабочему столу.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, !self.isStatusItemEvent(event) else { return }
            self.onRequestClose?()
        }
        // Borderless non-activating панели ненадёжно получают Escape через
        // cancelOperation, поэтому поглощаем клавишу локальным monitor-ом.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53 else { return event }
            self.onRequestClose?()
            return nil
        }
    }

    private func removeClickMonitors() {
        guard monitorsInstalled else { return }
        monitorsInstalled = false
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    private func isStatusItemEvent(_ event: NSEvent) -> Bool {
        guard let buttonWindow = statusButton?.window else { return false }
        // Окно status-item обычно совпадает с frame кнопки. Экранный frame
        // также закрывает различия event.window между Space и не позволяет
        // спрятать панель до statusItemClicked(mouseUp).
        return PanelInputRouting.isInsideStatusItemFrame(
            PanelInputRouting.screenPoint(of: event), frame: buttonWindow.frame)
    }

    /// Сбросить защиту от resign, установленную на mouseDown статусной кнопки.
    func statusButtonMouseUp() {
        suppressNextResign = false
    }

    // Закрываемся, если панель теряет ключевой статус (например, открыли меню).
    func windowDidResignKey(_ notification: Notification) {
        guard !suppressNextResign else { return }
        onRequestClose?()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        onRequestClose?()
    }

    private func nextToken(_ token: UInt64) -> UInt64 {
        token == .max ? 0 : token + 1
    }
}
