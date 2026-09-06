import Foundation
import SQLite3

/// SQLite-хранилище дел и наблюдений экрана (`screen.sqlite` рядом с БД ядра).
///
/// Отдельная БД, не ядро: фича пока только для macOS, и контракт ядра не
/// трогаем. Время хранится как epoch-секунды (INTEGER) — сортировка и
/// диапазоны не зависят от зоны (в БД ядра лексикографика RFC3339 уже
/// приводила к багу «нет активности», см. STATUS раунд UI №1 #6).
///
/// Потокобезопасность: все вызовы этого класса — с главного актора
/// (ScreenObserver). Фоновые чтения идут не сюда, а в `ActivityReader` — по
/// отдельному соединению (см. конец файла).
final class ActivityStore {
    private var db: OpaquePointer?

    /// Открывает (создавая при необходимости) БД по пути. Бросает при сбое.
    init(path: String) throws {
        if let dir = URL(fileURLWithPath: path).deletingLastPathComponent().path as String?, !dir.isEmpty {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw StoreError.open(msg)
        }
        try exec("PRAGMA journal_mode=WAL")
        try exec("""
            CREATE TABLE IF NOT EXISTS activities(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              start_ts INTEGER NOT NULL,
              end_ts INTEGER NOT NULL,
              app TEXT NOT NULL,
              title TEXT NOT NULL,
              summary TEXT NOT NULL,
              observations INTEGER NOT NULL DEFAULT 1)
            """)
        try exec("CREATE INDEX IF NOT EXISTS idx_activities_start ON activities(start_ts)")
        try exec("""
            CREATE TABLE IF NOT EXISTS observations(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              activity_id INTEGER NOT NULL,
              ts INTEGER NOT NULL,
              app TEXT NOT NULL,
              title TEXT NOT NULL,
              summary TEXT NOT NULL)
            """)
        try exec("CREATE INDEX IF NOT EXISTS idx_observations_act ON observations(activity_id)")
    }

    deinit { sqlite3_close(db) }

    enum StoreError: Error, CustomStringConvertible {
        case open(String)
        case exec(String)
        var description: String {
            switch self {
            case .open(let m): return "screen store open: \(m)"
            case .exec(let m): return "screen store: \(m)"
            }
        }
    }

    // MARK: activities

    /// Вставляет новое дело, возвращает копию с проставленным id.
    func insert(_ activity: Activity) throws -> Activity {
        let sql = "INSERT INTO activities(start_ts,end_ts,app,title,summary,observations) VALUES(?,?,?,?,?,?)"
        try withStatement(sql) { st in
            sqlite3_bind_int64(st, 1, Int64(activity.startAt.timeIntervalSince1970))
            sqlite3_bind_int64(st, 2, Int64(activity.endAt.timeIntervalSince1970))
            bindText(st, 3, activity.app)
            bindText(st, 4, activity.title)
            bindText(st, 5, activity.summary)
            sqlite3_bind_int64(st, 6, Int64(activity.observations))
            try stepDone(st)
        }
        var saved = activity
        saved.id = sqlite3_last_insert_rowid(db)
        return saved
    }

    /// Обновляет продолжающееся дело (end/summary/title/observations).
    func update(_ activity: Activity) throws {
        let sql = "UPDATE activities SET end_ts=?, title=?, summary=?, observations=? WHERE id=?"
        try withStatement(sql) { st in
            sqlite3_bind_int64(st, 1, Int64(activity.endAt.timeIntervalSince1970))
            bindText(st, 2, activity.title)
            bindText(st, 3, activity.summary)
            sqlite3_bind_int64(st, 4, Int64(activity.observations))
            sqlite3_bind_int64(st, 5, activity.id)
            try stepDone(st)
        }
    }

    /// Последнее по времени конца дело (для продолжения блока после рестарта).
    func lastActivity() throws -> Activity? {
        let sql = "SELECT id,start_ts,end_ts,app,title,summary,observations FROM activities ORDER BY end_ts DESC LIMIT 1"
        var result: Activity?
        try withStatement(sql) { st in
            if sqlite3_step(st) == SQLITE_ROW { result = readActivityRow(st) }
        }
        return result
    }

    /// Запрос дел за период. Один и тот же текст для главного соединения и для
    /// фонового `ActivityReader`: панель и окно обязаны видеть одно и то же.
    static let activitiesInRangeSQL = """
        SELECT id,start_ts,end_ts,app,title,summary,observations FROM activities
        WHERE end_ts >= ? AND start_ts <= ? ORDER BY start_ts DESC
        """

    /// Дела, пересекающиеся с [from, to], новые сверху.
    func activities(from: Date, to: Date) throws -> [Activity] {
        var out: [Activity] = []
        try withStatement(Self.activitiesInRangeSQL) { st in
            sqlite3_bind_int64(st, 1, Int64(from.timeIntervalSince1970))
            sqlite3_bind_int64(st, 2, Int64(to.timeIntervalSince1970))
            while sqlite3_step(st) == SQLITE_ROW { out.append(readActivityRow(st)) }
        }
        return out
    }

    // MARK: observations

    /// Пишет сырое наблюдение, привязанное к делу (журнал для отладки/аудита).
    func appendObservation(_ obs: ScreenObservation, activityId: Int64) throws {
        let sql = "INSERT INTO observations(activity_id,ts,app,title,summary) VALUES(?,?,?,?,?)"
        try withStatement(sql) { st in
            sqlite3_bind_int64(st, 1, activityId)
            sqlite3_bind_int64(st, 2, Int64(obs.ts.timeIntervalSince1970))
            bindText(st, 3, obs.app)
            bindText(st, 4, obs.windowTitle)
            bindText(st, 5, obs.summary)
            try stepDone(st)
        }
    }

    /// Наблюдения одного дела (по возрастанию времени).
    func observations(activityId: Int64) throws -> [ScreenObservation] {
        let sql = "SELECT ts,app,title,summary FROM observations WHERE activity_id=? ORDER BY ts ASC"
        var out: [ScreenObservation] = []
        try withStatement(sql) { st in
            sqlite3_bind_int64(st, 1, activityId)
            while sqlite3_step(st) == SQLITE_ROW {
                out.append(ScreenObservation(
                    ts: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(st, 0))),
                    app: readTextColumn(st, 1),
                    windowTitle: readTextColumn(st, 2),
                    summary: readTextColumn(st, 3)
                ))
            }
        }
        return out
    }

    /// Ретеншн: удаляет дела и наблюдения старше `days` дней.
    func deleteOlderThan(days: Int, now: Date = Date()) throws {
        let cutoff = Int64(now.timeIntervalSince1970) - Int64(days) * 86_400
        try withStatement("DELETE FROM observations WHERE activity_id IN (SELECT id FROM activities WHERE end_ts < ?)") { st in
            sqlite3_bind_int64(st, 1, cutoff)
            try stepDone(st)
        }
        try withStatement("DELETE FROM activities WHERE end_ts < ?") { st in
            sqlite3_bind_int64(st, 1, cutoff)
            try stepDone(st)
        }
    }

    // MARK: - helpers

    // SQLITE_TRANSIENT: SQLite копирует строку сразу (Swift-строка временная).
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bindText(_ st: OpaquePointer?, _ idx: Int32, _ value: String) {
        sqlite3_bind_text(st, idx, value, -1, transient)
    }

    private func withStatement(_ sql: String, _ body: (OpaquePointer?) throws -> Void) throws {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
            throw StoreError.exec(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(st) }
        try body(st)
    }

    private func stepDone(_ st: OpaquePointer?) throws {
        guard sqlite3_step(st) == SQLITE_DONE else {
            throw StoreError.exec(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw StoreError.exec(String(cString: sqlite3_errmsg(db)))
        }
    }
}

// MARK: - Фоновое чтение

/// ОТДЕЛЬНОЕ соединение с журналом дел для ФОНОВЫХ (не главный актор) чтений.
///
/// `ActivityStore` принадлежит главному актору: в него пишет тик наблюдателя.
/// Панель меню-бара обязана открываться мгновенно, поэтому читает дела вне
/// главного актора — и делает это по СВОЕМУ соединению, а не по чужому: в
/// режиме WAL читатель не мешает писателю, а sqlite-хендл писателя не уезжает
/// между потоками. Собственный мьютекс сериализует фоновые чтения между собой.
final class ActivityReader: @unchecked Sendable {
    private let lock = NSLock()
    private var db: OpaquePointer?

    /// Открывает СУЩЕСТВУЮЩИЙ файл журнала только на чтение. `nil` — файла
    /// ещё нет (журнал экрана ничего не записал): читать нечего, а создавать
    /// базу здесь незачем — это делает `ActivityStore`.
    init?(path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        db = handle
    }

    deinit { sqlite3_close(db) }

    /// Дела, пересекающиеся с [from, to], новые сверху.
    ///
    /// Ошибку не бросает: единственный вызывающий — панель, а панель без дел
    /// лучше панели со сбоем.
    func activities(from: Date, to: Date) -> [Activity] {
        lock.lock()
        defer { lock.unlock() }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, ActivityStore.activitiesInRangeSQL, -1, &st, nil) == SQLITE_OK
        else { return [] }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_int64(st, 1, Int64(from.timeIntervalSince1970))
        sqlite3_bind_int64(st, 2, Int64(to.timeIntervalSince1970))
        var out: [Activity] = []
        while sqlite3_step(st) == SQLITE_ROW { out.append(readActivityRow(st)) }
        return out
    }
}

// MARK: - Чтение строк (общее для обоих соединений)

/// Строка таблицы `activities` → `Activity`. Свободная функция, потому что
/// читают её оба соединения: рабочее (`ActivityStore`) и фоновое
/// (`ActivityReader`), и расходиться они не имеют права.
private func readActivityRow(_ st: OpaquePointer?) -> Activity {
    Activity(
        id: sqlite3_column_int64(st, 0),
        startAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(st, 1))),
        endAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(st, 2))),
        app: readTextColumn(st, 3),
        title: readTextColumn(st, 4),
        summary: readTextColumn(st, 5),
        observations: Int(sqlite3_column_int64(st, 6))
    )
}

private func readTextColumn(_ st: OpaquePointer?, _ col: Int32) -> String {
    sqlite3_column_text(st, col).map { String(cString: $0) } ?? ""
}
