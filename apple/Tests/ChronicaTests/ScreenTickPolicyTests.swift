import XCTest
@testable import Chronica

/// Наблюдение экрана не должно тратить скриншот + vision-LLM, когда смотреть
/// нечего. Правило чистое, поэтому проверяется без SCK, Ollama и реального
/// простоя системы.
final class ScreenTickPolicyTests: XCTestCase {

    func testActiveUserIsObserved() {
        XCTAssertEqual(
            ScreenTickPolicy.decide(locked: false, idleSeconds: 3, periodS: 60),
            .observe)
        // Ровно на границе периода ещё наблюдаем.
        XCTAssertEqual(
            ScreenTickPolicy.decide(locked: false, idleSeconds: 60, periodS: 60),
            .observe)
    }

    func testIdleLongerThanPeriodSkipsTick() {
        XCTAssertEqual(
            ScreenTickPolicy.decide(locked: false, idleSeconds: 61, periodS: 60),
            .skipIdle)
        XCTAssertEqual(
            ScreenTickPolicy.decide(locked: false, idleSeconds: 7200, periodS: 30),
            .skipIdle)
    }

    func testLockedSessionSkipsTickEvenWhenInputIsFresh() {
        XCTAssertEqual(
            ScreenTickPolicy.decide(locked: true, idleSeconds: 0, periodS: 60),
            .skipLocked)
    }

    func testBrokenIdleOrPeriodValuesDoNotBlockObservation() {
        XCTAssertEqual(
            ScreenTickPolicy.decide(locked: false, idleSeconds: .nan, periodS: 60),
            .observe)
        XCTAssertEqual(
            ScreenTickPolicy.decide(locked: false, idleSeconds: 5, periodS: .nan),
            .observe)
        // Слишком мелкий период не должен превращать любой простой в скип
        // (нижняя граница порога — 1 с).
        XCTAssertEqual(
            ScreenTickPolicy.decide(locked: false, idleSeconds: 0.5, periodS: 0),
            .observe)
    }

    func testRetentionRunsOncePerDay() {
        let now = Date()
        XCTAssertTrue(ScreenTickPolicy.shouldRunRetention(lastRunAt: nil, now: now))
        XCTAssertFalse(ScreenTickPolicy.shouldRunRetention(
            lastRunAt: now.addingTimeInterval(-3600), now: now))
        XCTAssertTrue(ScreenTickPolicy.shouldRunRetention(
            lastRunAt: now.addingTimeInterval(-86_400), now: now))
        XCTAssertTrue(ScreenTickPolicy.shouldRunRetention(
            lastRunAt: now.addingTimeInterval(-10 * 86_400), now: now))
    }
}

/// Наблюдатель обязан применять правило на деле: при простое/блокировке кадр
/// вообще не снимается (нет ни скриншота, ни вызова vision-LLM).
@MainActor
final class ScreenObserverSkipTests: XCTestCase {

    func testIdleUserSkipsCaptureEntirely() async throws {
        let counter = CallCounter()
        let observer = makeObserver(counter: counter, idleSeconds: 3600, locked: false)
        observer.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        observer.stop()
        XCTAssertEqual(counter.value, 0)
    }

    func testLockedScreenSkipsCaptureEntirely() async throws {
        let counter = CallCounter()
        let observer = makeObserver(counter: counter, idleSeconds: 0, locked: true)
        observer.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        observer.stop()
        XCTAssertEqual(counter.value, 0)
    }

    func testActiveUserStillCaptures() async throws {
        let counter = CallCounter()
        let observer = makeObserver(counter: counter, idleSeconds: 1, locked: false)
        observer.start()
        // Ждём УСЛОВИЯ (кадр снят) с дедлайном, а не фиксированную паузу:
        // дедлайн взят с запасом под медленный раннер CI.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, counter.value == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        observer.stop()
        XCTAssertGreaterThan(counter.value, 0)
    }

    private func makeObserver(counter: CallCounter,
                              idleSeconds: TimeInterval,
                              locked: Bool) -> ScreenObserver {
        let dir = makeTemporaryDirectory()
        let frame = ScreenObserver.CapturedFrame(jpegBase64: "dGVzdA==",
                                                 luma64: (0..<64).map(UInt8.init))
        return ScreenObserver(
            storagePath: dir.path,
            prefs: makeIsolatedPrefs(),
            describer: SilentDescriber(),
            frameProvider: { counter.bump(); return frame },
            contextProvider: { (app: "TestApp", title: "TestWindow") },
            nowProvider: { Date(timeIntervalSince1970: 1_000) },
            enabledProvider: { true },
            periodProvider: { 0.05 },
            idleSecondsProvider: { idleSeconds },
            screenLockedProvider: { locked },
            autoStart: false
        )
    }
}

/// Потокобезопасный счётчик вызовов кадра (frameProvider — `@Sendable`).
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    func bump() {
        lock.lock(); count += 1; lock.unlock()
    }
}

/// Vision-бэкенд без сети: тесты проверяют только факт снятия кадра.
private struct SilentDescriber: VisionDescriber {
    func describe(jpegBase64: String, app: String, windowTitle: String) async throws -> String {
        ""
    }
    func probe() async -> VisionProbe { .ready }
}
