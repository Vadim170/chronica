import XCTest
@testable import Chronica

/// Тесты сетевого seam Ollama: bounded timeout и отмена не требуют сервера.
final class VisionDescriberTests: XCTestCase {
    func testGenerateTimeoutIsBoundedAndSurfaced() async {
        let seen = LockedTimeInterval()
        let describer = OllamaDescriber(
            baseURL: URL(string: "http://127.0.0.1:11434")!,
            model: "test",
            timeout: 1,
            transport: { request in
                seen.set(request.timeoutInterval)
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return (Data(), HTTPURLResponse(
                    url: request.url!, statusCode: 200,
                    httpVersion: nil, headerFields: nil
                )!)
            }
        )

        let started = Date()
        do {
            _ = try await describer.describe(jpegBase64: "x", app: "A", windowTitle: "W")
            XCTFail("expected timeout")
        } catch let error as VisionError {
            guard case .timeout = error else { return XCTFail("unexpected error: \(error)") }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(seen.value, 1, accuracy: 0.1)
        // Do not assert wall time tightly: CI scheduling can be noisy. The
        // cancellation-aware transport must finish before its 2s sleep.
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.5)
    }

    func testConfiguredTimeoutIsCappedAtTwoMinutes() async throws {
        let seen = LockedTimeInterval()
        let describer = OllamaDescriber(
            baseURL: URL(string: "http://127.0.0.1:11434")!,
            model: "test",
            timeout: 999,
            transport: { request in
                seen.set(request.timeoutInterval)
                let body = Data("{\"response\":\"ok\"}".utf8)
                return (body, HTTPURLResponse(
                    url: request.url!, statusCode: 200,
                    httpVersion: nil, headerFields: nil
                )!)
            }
        )
        let text = try await describer.describe(jpegBase64: "x", app: "A", windowTitle: "W")
        XCTAssertEqual(text, "ok")
        XCTAssertEqual(seen.value, 120, accuracy: 0.1)
    }

    func testGenerateCancellationStopsTransport() async throws {
        let transport = CancellationProbe()
        let describer = OllamaDescriber(
            baseURL: URL(string: "http://127.0.0.1:11434")!,
            model: "test",
            timeout: 30,
            transport: { request in
                await transport.started()
                try await Task.sleep(nanoseconds: 30_000_000_000)
                return (Data(), HTTPURLResponse(
                    url: request.url!, statusCode: 200,
                    httpVersion: nil, headerFields: nil
                )!)
            }
        )

        let task = Task {
            try await describer.describe(jpegBase64: "x", app: "A", windowTitle: "W")
        }
        await transport.waitUntilStarted()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        }
    }
}

private final class LockedTimeInterval: @unchecked Sendable {
    private let lock = NSLock()
    private var raw: TimeInterval = 0
    var value: TimeInterval { lock.withLock { raw } }
    func set(_ value: TimeInterval) { lock.withLock { raw = value } }
}

private actor CancellationProbe {
    private var didStart = false
    private var waiter: CheckedContinuation<Void, Never>?

    func started() {
        didStart = true
        waiter?.resume()
        waiter = nil
    }

    func waitUntilStarted() async {
        if didStart { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiter = continuation
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
