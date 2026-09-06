import XCTest
import TranscriberCore
@testable import Chronica

// =============================================================================
// Изоляция прогона от пользовательских данных
// =============================================================================
//
// `Engine()` без аргументов берёт РЕАЛЬНЫЙ `~/Library/Application Support` и
// выполняет там миграцию каталога (`Transcriber` → `Chronica`), а `Prefs.shared`
// пишет в домен приложения. Обычный `swift test` на машине разработчика из-за
// этого один раз уже переименовал живую папку данных под работающим
// приложением.
//
// Поэтому тесты НИКОГДА не создают `Engine()`/`Prefs.shared` напрямую: они
// берут `makeIsolatedEngine(...)` / `makeIsolatedPrefs()` — временный каталог и
// отдельный suite `UserDefaults`, оба удаляются в teardown.

extension XCTestCase {

    /// Временный каталог, удаляемый после теста.
    func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chronica-tests-\(UUID().uuidString)", isDirectory: true)
        // В замыкание уходит только путь (`String`): держать `URL`/`FileManager`
        // в `@Sendable`-блоке teardown не нужно.
        let path = url.path
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: path)
        }
        return url
    }

    /// Настройки на отдельном домене `UserDefaults`, удаляемом после теста.
    ///
    /// `migrate: false` — перенос из домена старого bundle id читает и пишет
    /// настоящие пользовательские домены, в прогоне ему делать нечего.
    @MainActor
    func makeIsolatedPrefs() -> Prefs {
        let suite = XCTestCase.defaultsSuiteName(forTest: name)
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("не удалось открыть тестовый suite UserDefaults")
        }
        // Чистим и на входе, и в teardown: домен переиспользуется между
        // прогонами, а тест обязан начинать с пустых настроек.
        XCTestCase.discardDefaultsSuite(suite)
        addTeardownBlock { XCTestCase.discardDefaultsSuite(suite) }
        return Prefs(defaults: defaults, migrate: false)
    }

    /// Имя тестового домена настроек — ДЕТЕРМИНИРОВАННОЕ, от имени теста.
    ///
    /// Случайные имена накапливали бы по одному пустому plist'у за прогон в
    /// `~/Library/Preferences`: `cfprefsd` дописывает файл домена асинхронно,
    /// иногда уже после выхода процесса, поэтому удалить его из teardown
    /// гарантированно нельзя. Стабильное имя означает переиспользование одного
    /// и того же (пустого) файла вместо роста мусора.
    static func defaultsSuiteName(forTest testName: String) -> String {
        let safe = testName.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return "test.chronica." + String(safe)
    }

    /// Очищает тестовый домен настроек и удаляет его файл, если он уже создан.
    static func discardDefaultsSuite(_ suite: String) {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        CFPreferencesAppSynchronize(suite as CFString)
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(suite).plist")
        try? FileManager.default.removeItem(at: plist)
    }

    /// `Engine` в полной изоляции: данные — во временном каталоге, настройки —
    /// в отдельном домене. Реальный `Application Support` и
    /// `UserDefaults.standard` не участвуют.
    ///
    /// Сигнатура повторяет `Engine.init`, чтобы тест мог подставить любой seam.
    @MainActor
    func makeIsolatedEngine(
        core: TranscriberCore? = nil,
        captureFactory: (() -> CaptureControlling)? = nil,
        watchdogTimeoutS: TimeInterval = 12,
        watchdogPollS: TimeInterval = 1,
        clock: @escaping () -> Date = Date.init,
        monotonicClock: @escaping () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        watchdogSleep: @escaping @Sendable (UInt64) async -> Void = { ns in
            try? await Task.sleep(nanoseconds: ns)
        },
        restartHandler: (() -> Void)? = nil,
        relaunchHandler: ((@escaping (Bool) -> Void) -> Void)? = nil,
        micPermission: MicPermissionProviding? = nil,
        wakeRetryDelayS: TimeInterval = 1.5
    ) -> Engine {
        Engine(dataRoot: makeTemporaryDirectory(),
               prefs: makeIsolatedPrefs(),
               core: core,
               captureFactory: captureFactory,
               watchdogTimeoutS: watchdogTimeoutS,
               watchdogPollS: watchdogPollS,
               clock: clock,
               monotonicClock: monotonicClock,
               watchdogSleep: watchdogSleep,
               restartHandler: restartHandler,
               relaunchHandler: relaunchHandler,
               micPermission: micPermission,
               wakeRetryDelayS: wakeRetryDelayS)
    }
}

/// Защитные тесты гигиены прогона: `Engine` с явным каталогом данных не
/// прикасается к пользовательским каталогам и настройкам.
@MainActor
final class EngineDataIsolationTests: XCTestCase {

    /// Реальный `Application Support` (только для чтения снимков).
    private var applicationSupport: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
    }

    /// Есть ли каталог. Намеренно НЕ смотрим `modificationDate`: приложение
    /// владельца может быть запущено и писать в свою папку прямо во время
    /// прогона — тогда сравнение времён краснело бы без всякой вины теста.
    /// Проверяемый сценарий (переименование живой папки) меняет именно
    /// СУЩЕСТВОВАНИЕ обоих каталогов, а его этот снимок ловит полностью.
    private func snapshot(_ url: URL) -> String {
        FileManager.default.fileExists(atPath: url.path) ? "present" : "absent"
    }

    func testIsolatedEngineLeavesTheRealApplicationSupportUntouched() {
        // Именно этот сценарий однажды сломал прод-данные: `Engine()` в тесте
        // переименовал живую папку. Снимок «до/после» вокруг конструктора —
        // самая прямая проверка того, что этого больше не происходит.
        let current = applicationSupport.appendingPathComponent(
            SupportFolderMigration.folderName, isDirectory: true)
        let legacy = applicationSupport.appendingPathComponent(
            SupportFolderMigration.legacyFolderName, isDirectory: true)
        let currentBefore = snapshot(current)
        let legacyBefore = snapshot(legacy)

        let engine = makeIsolatedEngine()

        XCTAssertEqual(snapshot(current), currentBefore,
                       "каталог данных пользователя не должен меняться в прогоне")
        XCTAssertEqual(snapshot(legacy), legacyBefore,
                       "каталог прежнего имени продукта не должен появляться или исчезать")
        XCTAssertFalse(engine.storagePath.hasPrefix(applicationSupport.path),
                       "хранилище теста обязано лежать вне Application Support")
        XCTAssertFalse(engine.modelsPath.hasPrefix(applicationSupport.path))
    }

    func testExplicitDataRootIsUsedAsIsWithoutMigration() {
        // Ловушка: рядом с заданным каталогом лежит папка со СТАРЫМ именем
        // продукта. Явный `dataRoot` означает «каталог уже выбран», поэтому
        // миграция не запускается и ловушку никто не трогает.
        let parent = makeTemporaryDirectory()
        let legacy = parent.appendingPathComponent(SupportFolderMigration.legacyFolderName,
                                                   isDirectory: true)
        let root = parent.appendingPathComponent(SupportFolderMigration.folderName,
                                                 isDirectory: true)
        XCTAssertNoThrow(try FileManager.default.createDirectory(
            at: legacy.appendingPathComponent("store", isDirectory: true),
            withIntermediateDirectories: true))

        let engine = Engine(dataRoot: root, prefs: makeIsolatedPrefs())

        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path),
                      "каталог старого имени не переносится, когда dataRoot задан явно")
        XCTAssertEqual(engine.storagePath,
                       root.appendingPathComponent("store", isDirectory: true).path)
        XCTAssertEqual(engine.modelsPath,
                       root.appendingPathComponent("Models", isDirectory: true).path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: engine.storagePath),
                      "рабочие подкаталоги создаются внутри заданного корня")
        XCTAssertTrue(FileManager.default.fileExists(atPath: engine.modelsPath))
        XCTAssertEqual(engine.lastError, "", "своего каталога миграция не касается")
    }

    func testIsolatedPrefsWritesOnlyIntoItsOwnDomain() {
        let key = "pref.screenPeriodS"
        let standardBefore = UserDefaults.standard.object(forKey: key) as? Double
        let prefs = makeIsolatedPrefs()

        prefs.screenPeriodS = 300

        XCTAssertEqual(prefs.screenPeriodS, 300)
        XCTAssertEqual(UserDefaults.standard.object(forKey: key) as? Double, standardBefore,
                       "изолированные настройки не пишут в домен приложения")
    }

    func testIsolatedPrefsSkipsTheLegacyDomainMigration() {
        // Флаг переноса живёт в домене настроек. Изолированный экземпляр не
        // должен его ставить: иначе прогон «съел» бы одноразовую миграцию.
        let suite = XCTestCase.defaultsSuiteName(forTest: name)
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("не удалось открыть тестовый suite UserDefaults")
        }
        XCTestCase.discardDefaultsSuite(suite)
        addTeardownBlock { XCTestCase.discardDefaultsSuite(suite) }

        _ = Prefs(defaults: defaults, migrate: false)

        XCTAssertNil(defaults.object(forKey: PrefsMigration.flagKey))
    }
}
