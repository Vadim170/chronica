import XCTest
@testable import Chronica

/// Поведенческие тесты lifecycle экрана. SCK, TCC и Ollama не используются:
/// внешние операции подменены cancellation-aware и cancellation-ignoring doubles.
@MainActor
final class ScreenObserverLifecycleTests: XCTestCase {
    func testStopCancelsDescribeAndDoesNotPersistObservation() async throws {
        let describer = TestDescriber(results: ["stale"], cancellationAware: true)
        let observer = makeObserver(describer: describer)

        observer.start()
        await describer.waitUntilStarted()
        observer.stop()
        await describer.release()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(observer.status, .off)
        XCTAssertNil(observer.lastObservation)
        XCTAssertTrue(observer.activities(from: .distantPast, to: .distantFuture).isEmpty)
    }

    func testStopRestartRunsFreshTickWhileStaleDescribeIgnoresCancellation() async throws {
        let describer = TestDescriber(results: ["stale", "fresh"], cancellationAware: false)
        let observer = makeObserver(describer: describer, period: 0.05)

        observer.start()
        await describer.waitUntilStarted()
        observer.stop()
        observer.start()

        // Старый describe игнорирует cancellation и всё ещё ждёт. Новое
        // поколение всё равно должно войти в свой тик и сохранить fresh.
        try await waitUntil(timeout: 3) { describer.snapshot().calls >= 2 }
        XCTAssertEqual(describer.snapshot().maxActive, 2)
        try await waitUntil(timeout: 3) {
            observer.activities(from: .distantPast, to: .distantFuture).count == 1
        }
        var saved = observer.activities(from: .distantPast, to: .distantFuture)
        XCTAssertEqual(saved.first?.summary, "fresh")

        // Разрешаем старый await: его result остаётся stale и не может
        // перезаписать observation нового поколения.
        await describer.release()
        try await waitUntil(timeout: 3) { describer.snapshot().calls >= 2 }
        saved = observer.activities(from: .distantPast, to: .distantFuture)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.summary, "fresh")
        observer.stop()
    }

    func testBackendErrorStillPersistsObservationAndDegradesStatus() async throws {
        let describer = TestDescriber(error: VisionError.backend("offline"))
        let observer = makeObserver(describer: describer)

        observer.start()
        await describer.release()
        try await waitUntil(timeout: 3) {
            if case .backendUnavailable = observer.status { return true }
            return false
        }
        let saved = observer.activities(from: .distantPast, to: .distantFuture)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.app, "TestApp")
        XCTAssertEqual(saved.first?.summary, "")
        observer.stop()
    }

    func testStopIsIdempotentAndRestartUsesFreshGeneration() async throws {
        let describer = TestDescriber(results: ["ok", "ok2"])
        let observer = makeObserver(describer: describer)
        observer.stop()
        observer.stop()
        XCTAssertEqual(observer.status, .off)

        observer.start()
        observer.stop()
        observer.stop()
        await describer.release()
        XCTAssertEqual(observer.status, .off)
    }

    func testInvalidPeriodDoesNotTrapScheduler() async throws {
        let describer = TestDescriber(results: ["ok"])
        let observer = makeObserver(describer: describer, period: -.infinity)
        observer.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        observer.stop()
        await describer.release()
        XCTAssertEqual(observer.status, .off)
    }

    // MARK: helpers

    private func makeObserver(
        describer: VisionDescriber,
        period: Double = 0.05,
        frameProvider: ScreenObserver.FrameProvider? = nil
    ) -> ScreenObserver {
        let dir = makeTemporaryDirectory()
        let frame = ScreenObserver.CapturedFrame(
            jpegBase64: "dGVzdA==",
            luma64: (0..<64).map(UInt8.init)
        )
        return ScreenObserver(
            storagePath: dir.path,
            // Без явных настроек ScreenObserver берёт `Prefs.shared`, то есть
            // домен приложения и одноразовый перенос из старого bundle id.
            prefs: makeIsolatedPrefs(),
            describer: describer,
            frameProvider: frameProvider ?? { frame },
            contextProvider: { (app: "TestApp", title: "TestWindow") },
            nowProvider: { Date(timeIntervalSince1970: 1_000) },
            enabledProvider: { true },
            periodProvider: { period },
            autoStart: false
        )
    }

    /// Ожидание УСЛОВИЯ с дедлайном. Дедлайн — верхняя граница терпения, а не
    /// ожидаемое время: на медленном раннере CI тик наблюдателя приходит позже,
    /// и запас по дедлайну не ослабляет проверку.
    private func waitUntil(
        timeout: TimeInterval = 3,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("condition timed out")
    }
}

private actor TestGate {
    private var isOpen = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiter = continuation
        }
    }

    func open() {
        isOpen = true
        waiter?.resume()
        waiter = nil
    }

    func reset() {
        isOpen = false
    }
}

private final class TestDescriber: VisionDescriber, @unchecked Sendable {
    private let gate = TestGate()
    private let results: [String]
    private let error: Error?
    private let cancellationAware: Bool
    private let lock = NSLock()
    private var callCount = 0
    private var active = 0
    private var maxActive = 0

    init(results: [String] = [],
         error: Error? = nil,
         cancellationAware: Bool = true) {
        self.results = results
        self.error = error
        self.cancellationAware = cancellationAware
    }

    func describe(jpegBase64: String, app: String, windowTitle: String) async throws -> String {
        let index = lock.withLock {
            callCount += 1
            active += 1
            maxActive = max(maxActive, active)
            return callCount - 1
        }
        defer { lock.withLock { active -= 1 } }
        // Hold only the first call. A restarted generation gets an independent
        // call while the stale first call ignores cancellation.
        if index == 0 { await gate.wait() }
        if cancellationAware { try Task.checkCancellation() }
        if let error { throw error }
        return results[min(index, max(0, results.count - 1))]
    }

    func probe() async -> VisionProbe { .ready }

    func waitUntilStarted() async {
        while snapshot().calls == 0 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func release() async { await gate.open() }

    func snapshot() -> (calls: Int, maxActive: Int) {
        lock.withLock { (callCount, maxActive) }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
