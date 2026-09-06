import XCTest
@testable import Chronica

/// Чистая логика выхода и перезапуска. AppKit здесь не нужен: проверяем
/// решение «ждать / не ждать / хватит ждать» и признание перезапуска удачным.
final class AppQuitPolicyTests: XCTestCase {

    func testIdleAppQuitsImmediatelyAndBusyAppWaits() {
        XCTAssertEqual(QuitPolicy.decide(hasPendingCoreWork: false), .terminateNow)
        XCTAssertEqual(QuitPolicy.decide(hasPendingCoreWork: true), .waitForCoreStop)
    }

    func testWaitFinishesWhenCoreStopsAndTimesOutOtherwise() {
        XCTAssertEqual(QuitPolicy.step(hasPendingCoreWork: true, elapsedS: 0), .keepWaiting)
        XCTAssertEqual(QuitPolicy.step(hasPendingCoreWork: true, elapsedS: 4.9), .keepWaiting)
        // Хвост записи дописан — выходим, не досиживая таймаут.
        XCTAssertEqual(QuitPolicy.step(hasPendingCoreWork: false, elapsedS: 0.1), .finished)
        // Ядро зависло — всё равно выходим, но по таймауту.
        XCTAssertEqual(QuitPolicy.step(hasPendingCoreWork: true, elapsedS: 5), .timedOut)
        XCTAssertEqual(QuitPolicy.step(hasPendingCoreWork: true, elapsedS: 60), .timedOut)
    }

    func testQuitTimeoutIsFiveSeconds() {
        XCTAssertEqual(QuitPolicy.stopTimeoutS, 5)
    }

    func testRelaunchCountsOnlyADifferentProcessAsSuccess() {
        struct Failed: Error {}
        XCTAssertTrue(RelaunchOutcome.succeeded(newPid: 4242, error: nil, currentPid: 100))
        // LaunchServices вернул ТЕКУЩИЙ инстанс — перезапуска не было.
        XCTAssertFalse(RelaunchOutcome.succeeded(newPid: 100, error: nil, currentPid: 100))
        XCTAssertFalse(RelaunchOutcome.succeeded(newPid: nil, error: nil, currentPid: 100))
        XCTAssertFalse(RelaunchOutcome.succeeded(newPid: 4242, error: Failed(), currentPid: 100))
    }
}

/// Ожидание выхода должно опираться на честный признак «ядру ещё есть что
/// доделать», иначе хвост записи теряется.
@MainActor
final class EnginePendingWorkTests: XCTestCase {

    func testIdleEngineHasNoPendingCoreWork() {
        let engine = makeIsolatedEngine()
        XCTAssertFalse(engine.hasPendingCoreWork)
        XCTAssertEqual(QuitPolicy.decide(hasPendingCoreWork: engine.hasPendingCoreWork),
                       .terminateNow)
    }
}
