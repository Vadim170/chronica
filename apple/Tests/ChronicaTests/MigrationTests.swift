import XCTest
@testable import Chronica

/// Перенос каталога данных со старого имени продукта на новое.
///
/// Проверяется ПОВЕДЕНИЕ: когда переносим, когда нет, и что сорванный перенос
/// не теряет данные (продолжаем работать со старой папкой и честно сообщаем
/// об ошибке). Файловая система инжектируется — тест не трогает диск.
final class SupportFolderMigrationTests: XCTestCase {

    private let legacy = URL(fileURLWithPath: "/Support/Transcriber", isDirectory: true)
    private let new = URL(fileURLWithPath: "/Support/Chronica", isDirectory: true)

    func testMovesOnlyWhenLegacyExistsAndNewDoesNot() {
        XCTAssertEqual(SupportFolderMigration.decide(legacyExists: true, newExists: false), .move)
        // Новая папка уже есть — она главная: сливать две истории нечем.
        XCTAssertEqual(SupportFolderMigration.decide(legacyExists: true, newExists: true), .useNew)
        XCTAssertEqual(SupportFolderMigration.decide(legacyExists: false, newExists: false), .useNew)
        XCTAssertEqual(SupportFolderMigration.decide(legacyExists: false, newExists: true), .useNew)
    }

    func testFirstLaunchAfterRenameMovesLegacyFolderWhole() {
        var moves: [(URL, URL)] = []
        let outcome = SupportFolderMigration.prepare(
            legacy: legacy, new: new,
            exists: { $0 == self.legacy },
            move: { from, to in moves.append((from, to)) })

        XCTAssertEqual(moves.count, 1, "переносим одним moveItem, а не покопийно")
        XCTAssertEqual(moves.first?.0, legacy)
        XCTAssertEqual(moves.first?.1, new)
        XCTAssertTrue(outcome.moved)
        XCTAssertEqual(outcome.url, new)
        XCTAssertNil(outcome.error)
    }

    func testFreshInstallDoesNotTouchTheFileSystem() {
        var moveCalls = 0
        let outcome = SupportFolderMigration.prepare(
            legacy: legacy, new: new,
            exists: { _ in false },
            move: { _, _ in moveCalls += 1 })

        XCTAssertEqual(moveCalls, 0)
        XCTAssertFalse(outcome.moved)
        XCTAssertEqual(outcome.url, new)
        XCTAssertNil(outcome.error)
    }

    func testSecondLaunchKeepsNewFolderAndSkipsTheMove() {
        var moveCalls = 0
        let outcome = SupportFolderMigration.prepare(
            legacy: legacy, new: new,
            exists: { _ in true },
            move: { _, _ in moveCalls += 1 })

        XCTAssertEqual(moveCalls, 0)
        XCTAssertEqual(outcome.url, new)
        XCTAssertNil(outcome.error)
    }

    func testFailedMoveFallsBackToTheLegacyFolderWithAMessage() {
        struct Denied: Error {}
        let outcome = SupportFolderMigration.prepare(
            legacy: legacy, new: new,
            exists: { $0 == self.legacy },
            move: { _, _ in throw Denied() })

        // Данные пользователя остались на старом пути — работаем с ними.
        XCTAssertEqual(outcome.url, legacy)
        XCTAssertFalse(outcome.moved)
        let message = outcome.error ?? ""
        XCTAssertFalse(message.isEmpty, "сорванный перенос обязан быть видимым")
        XCTAssertTrue(message.contains("Transcriber"))
        XCTAssertTrue(message.contains("Chronica"))
    }

    func testFailureMessageDropsMultilineOrOverlongDetail() {
        let long = NSError(domain: "test", code: 1, userInfo: [
            NSLocalizedDescriptionKey: String(repeating: "щ", count: 400),
        ])
        let multiline = NSError(domain: "test", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "первая строка\nвторая строка",
        ])
        XCTAssertFalse(SupportFolderMigration.failureMessage(long).contains("щщщ"))
        XCTAssertFalse(SupportFolderMigration.failureMessage(multiline).contains("\n"))
    }
}

/// Перенос настроек `pref.*` из домена старого bundle id.
final class PrefsMigrationTests: XCTestCase {

    func testCopiesLegacyValuesOnFirstRun() {
        let legacy: [String: Any] = [
            "pref.launchAtLogin": true,
            "pref.visionModel": "qwen2.5vl:3b",
            "pref.screenPeriodS": 300.0,
        ]
        let plan = PrefsMigration.plan(legacy: legacy, existingKeys: [], alreadyMigrated: false)

        XCTAssertEqual(Set(plan.keys), Set(["pref.launchAtLogin", "pref.visionModel",
                                            "pref.screenPeriodS"]))
        XCTAssertEqual(plan["pref.visionModel"] as? String, "qwen2.5vl:3b")
        XCTAssertEqual(plan["pref.launchAtLogin"] as? Bool, true)
        XCTAssertEqual(plan["pref.screenPeriodS"] as? Double, 300)
    }

    func testValueAlreadySetInTheNewDomainWins() {
        let legacy: [String: Any] = [
            "pref.visionModel": "qwen2.5vl:3b",
            "pref.ollamaURL": "http://127.0.0.1:11434",
        ]
        let plan = PrefsMigration.plan(legacy: legacy,
                                       existingKeys: ["pref.visionModel"],
                                       alreadyMigrated: false)

        XCTAssertNil(plan["pref.visionModel"], "выбор пользователя в новой версии важнее")
        XCTAssertEqual(plan["pref.ollamaURL"] as? String, "http://127.0.0.1:11434")
    }

    func testMigrationRunsOnlyOnce() {
        let legacy: [String: Any] = ["pref.launchAtLogin": true]
        XCTAssertTrue(PrefsMigration.plan(legacy: legacy, existingKeys: [],
                                          alreadyMigrated: true).isEmpty,
                      "повторный перенос оживил бы настройку, сброшенную вручную")
    }

    func testForeignKeysFromTheOldDomainAreNotCopied() {
        let legacy: [String: Any] = [
            "NSWindow Frame main": "0 0 100 100",
            "pref.launchAtLogin": true,
            "somebody.elses.key": 42,
        ]
        let plan = PrefsMigration.plan(legacy: legacy, existingKeys: [], alreadyMigrated: false)
        XCTAssertEqual(Set(plan.keys), Set(["pref.launchAtLogin"]))
    }

    func testEveryPrefsKeyIsCoveredByTheMigration() {
        // Ключи `Prefs` и список переноса обязаны совпадать: забытый ключ
        // молча потерял бы настройку пользователя при обновлении.
        XCTAssertEqual(Set(PrefsMigration.keys), Set([
            "pref.launchAtLogin",
            "pref.screenEnabled",
            "pref.screenPeriodS",
            "pref.screenRetentionDays",
            "pref.ollamaURL",
            "pref.visionModel",
            "pref.transcriptRetentionDays",
        ]))
    }
}

/// Перерегистрация автозапуска после смены bundle id.
final class LoginItemMigrationTests: XCTestCase {

    func testReregistersOnlyWhenTheUserWantedAutostartAndSystemLostIt() {
        XCTAssertTrue(LoginItemMigration.shouldReregister(
            prefEnabled: true, systemRegistered: false, alreadyDone: false))
        // Автозапуск не был включён — ничего не навязываем.
        XCTAssertFalse(LoginItemMigration.shouldReregister(
            prefEnabled: false, systemRegistered: false, alreadyDone: false))
        // Система уже знает о новом id.
        XCTAssertFalse(LoginItemMigration.shouldReregister(
            prefEnabled: true, systemRegistered: true, alreadyDone: false))
        // Попытка уже была (в dev-сборке register() штатно падает).
        XCTAssertFalse(LoginItemMigration.shouldReregister(
            prefEnabled: true, systemRegistered: false, alreadyDone: true))
    }
}

/// Сведения о сборке для окна «О Chronica».
final class AppInfoTests: XCTestCase {

    func testVersionLineShowsVersionAndBuildNumber() {
        let line = AppInfo.versionLine(shortVersion: "0.1.0", build: "1")
        XCTAssertEqual(line, L("about.versionLine", "0.1.0", "1"))
        XCTAssertTrue(line.contains("0.1.0"))
        XCTAssertTrue(line.contains("1"))
    }

    func testVersionLineWithoutBundleKeysStaysReadable() {
        // В `swift run`/тестах ключей Info.plist нет: пустых скобок быть не должно.
        XCTAssertEqual(AppInfo.versionLine(shortVersion: "—", build: "—"),
                       L("about.versionLine", "—", "—"))
        XCTAssertFalse(AppInfo.versionLine.contains("()"))
    }

    func testNoticesOpenTheBundledFileWhenItIsShipped() {
        let url = AppInfo.noticesTarget(bundledPath: "/Apps/Chronica.app/Contents/Resources/THIRD_PARTY_NOTICES.md")
        XCTAssertTrue(url.isFileURL)
        XCTAssertEqual(url.lastPathComponent, "THIRD_PARTY_NOTICES.md")
    }

    func testNoticesFallBackToGitHubWithoutABundle() {
        let url = AppInfo.noticesTarget(bundledPath: nil)
        XCTAssertFalse(url.isFileURL)
        XCTAssertTrue(url.absoluteString.hasPrefix("https://github.com/Vadim170/chronica"))
        XCTAssertTrue(url.absoluteString.hasSuffix("THIRD_PARTY_NOTICES.md"))
    }

    func testAuthorLineIsPresentForTheAboutWindow() throws {
        // Ключ обязан разрешаться в текст, а не показываться как «about.author».
        XCTAssertNotEqual(AppInfo.author, "about.author")
        XCTAssertFalse(AppInfo.author.isEmpty)
        XCTAssertEqual(try L10nTestSupport.string("about.author", language: "en"),
                       "Developed by Vadim Makarov")
        XCTAssertEqual(try L10nTestSupport.string("about.author", language: "ru"),
                       "Разработал Вадим Макаров")
    }
}
