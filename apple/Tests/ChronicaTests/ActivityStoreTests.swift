import XCTest
@testable import Chronica

/// Поведение SQLite-хранилища дел: CRUD, диапазоны (epoch, без ловушки
/// лексикографики зон), наблюдения, ретеншн. Реальная БД во временном файле.
final class ActivityStoreTests: XCTestCase {
    private var dir: URL!
    private var store: ActivityStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chronica-tests-\(UUID().uuidString)")
        store = try ActivityStore(path: dir.appendingPathComponent("screen.sqlite").path)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func activity(_ start: TimeInterval, _ end: TimeInterval,
                          app: String = "Xcode", summary: String = "s") -> Activity {
        Activity(startAt: Date(timeIntervalSince1970: start),
                 endAt: Date(timeIntervalSince1970: end),
                 app: app, title: "t", summary: summary)
    }

    func testInsertAssignsIdAndRoundTrips() throws {
        let saved = try store.insert(activity(1000, 1060))
        XCTAssertGreaterThan(saved.id, 0)
        let last = try store.lastActivity()
        XCTAssertEqual(last, saved)
    }

    func testUpdateExtendsBlock() throws {
        var a = try store.insert(activity(1000, 1000))
        a.endAt = Date(timeIntervalSince1970: 1120)
        a.summary = "обновлено"
        a.observations = 3
        try store.update(a)
        XCTAssertEqual(try store.lastActivity(), a)
    }

    func testRangeQueryUsesOverlapNewestFirst() throws {
        let a1 = try store.insert(activity(1000, 1100))
        let a2 = try store.insert(activity(2000, 2100))
        _ = try store.insert(activity(9000, 9100)) // вне диапазона

        let got = try store.activities(from: Date(timeIntervalSince1970: 1050),
                                       to: Date(timeIntervalSince1970: 2050))
        XCTAssertEqual(got.map(\.id), [a2.id, a1.id], "перекрытие диапазона, новые сверху")
    }

    func testObservationsAttachToActivity() throws {
        let a = try store.insert(activity(1000, 1000))
        let o1 = ScreenObservation(ts: Date(timeIntervalSince1970: 1000),
                                   app: "Xcode", windowTitle: "t", summary: "раз")
        let o2 = ScreenObservation(ts: Date(timeIntervalSince1970: 1060),
                                   app: "Xcode", windowTitle: "t", summary: "два")
        try store.appendObservation(o1, activityId: a.id)
        try store.appendObservation(o2, activityId: a.id)
        XCTAssertEqual(try store.observations(activityId: a.id), [o1, o2])
    }

    func testRetentionDeletesOldActivitiesWithObservations() throws {
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        let old = try store.insert(activity(10 * 86_400, 10 * 86_400 + 60))
        try store.appendObservation(
            ScreenObservation(ts: old.startAt, app: "X", windowTitle: "", summary: ""),
            activityId: old.id
        )
        let fresh = try store.insert(activity(99 * 86_400, 99 * 86_400 + 60))

        try store.deleteOlderThan(days: 30, now: now)

        let all = try store.activities(from: Date(timeIntervalSince1970: 0), to: now)
        XCTAssertEqual(all.map(\.id), [fresh.id])
        XCTAssertTrue(try store.observations(activityId: old.id).isEmpty)
    }

    func testLastActivityIsLatestByEnd() throws {
        _ = try store.insert(activity(1000, 5000))
        let later = try store.insert(activity(2000, 6000))
        XCTAssertEqual(try store.lastActivity()?.id, later.id)
    }
}
