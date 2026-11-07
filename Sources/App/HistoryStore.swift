import Foundation
import SQLite3

/// Grandeurs enregistrées chaque minute.
enum Metric: String, CaseIterable {
    case cpu, gpu, mem
    case cpuTemp = "cpu_temp", cpuTempMax = "cpu_temp_max", gpuTemp = "gpu_temp"
    case fan0, fan1, power
    case battPct = "batt_pct", battTemp = "batt_temp", battPower = "batt_power"
}

/// Agrégat (moyenne / min / max) d'une grandeur sur une période.
struct Agg {
    var sum = 0.0, n = 0, min = Double.infinity, max = -Double.infinity
    var avg: Double? { n > 0 ? sum / Double(n) : nil }
    mutating func add(_ v: Double) { sum += v; n += 1; min = Swift.min(min, v); max = Swift.max(max, v) }
    mutating func merge(_ o: Agg) {
        guard o.n > 0 else { return }
        sum += o.sum; n += o.n; min = Swift.min(min, o.min); max = Swift.max(max, o.max)
    }
}

/// Une ligne agrégée (minute ou heure) lue dans la base.
struct HistoryRow {
    let date: Date
    var minutes: Int
    var batteryMinutes: Int
    var hotApp: String?
    var values: [Metric: Agg]
}

struct AppHourRow {
    let date: Date
    let app: String
    let cpuSeconds: Double
    let energyJ: Double
    let batteryEnergyJ: Double
    let tempWeighted: Double     // Σ (secondes CPU × température CPU)
    let hotCpuSeconds: Double    // secondes CPU passées pendant que le Mac chauffait
}

struct MinuteRecord {
    let ts: Int
    let values: [Metric: Double]
    let onBattery: Bool
    let topApp: String?
    let apps: [String: AppDelta]
    let bundlePaths: [String: String]
    let batteryHealth: Double?
    let batteryCycles: Int?
}

/// Base SQLite : ~/Library/Application Support/FanPilot/history.sqlite
///   samples      – une ligne par minute (conservée 35 jours, pour la vue Jour)
///   hourly       – agrégats par heure (conservés indéfiniment : mois, années)
///   app_hourly   – consommation par application et par heure
///   battery_daily – santé / cycles de la batterie, une ligne par jour
final class HistoryStore: @unchecked Sendable {     // accès SQLite sérialisés sur `queue`
    static let shared = HistoryStore()
    static let hotThreshold = 80.0   // °C : au-delà, on considère que le Mac « chauffe »

    let queue = DispatchQueue(label: "fanpilot.history")
    private var db: OpaquePointer?
    let url: URL

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FanPilot", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Debug : FANPILOT_DB=/chemin.sqlite pour travailler sur une base de test.
        url = ProcessInfo.processInfo.environment["FANPILOT_DB"].map { URL(fileURLWithPath: $0) }
            ?? dir.appendingPathComponent("history.sqlite")
        queue.sync {
            guard sqlite3_open(url.path, &db) == SQLITE_OK else { db = nil; return }
            exec("PRAGMA journal_mode=WAL")
            exec("PRAGMA synchronous=NORMAL")
            createSchema()
        }
    }

    // MARK: Schéma

    private func createSchema() {
        let m = Metric.allCases
        exec("CREATE TABLE IF NOT EXISTS samples(ts INTEGER PRIMARY KEY, "
             + m.map { "\($0.rawValue) REAL" }.joined(separator: ", ")
             + ", on_battery INTEGER, top_app TEXT)")
        exec("CREATE TABLE IF NOT EXISTS hourly(hour INTEGER PRIMARY KEY, minutes INTEGER NOT NULL DEFAULT 0, "
             + "batt_minutes INTEGER NOT NULL DEFAULT 0, hot_app TEXT, "
             + m.map { "\($0.rawValue)_sum REAL NOT NULL DEFAULT 0, \($0.rawValue)_n INTEGER NOT NULL DEFAULT 0, "
                     + "\($0.rawValue)_min REAL, \($0.rawValue)_max REAL" }.joined(separator: ", ") + ")")
        exec("""
            CREATE TABLE IF NOT EXISTS app_hourly(hour INTEGER NOT NULL, app TEXT NOT NULL,
              cpu_sec REAL NOT NULL DEFAULT 0, energy_j REAL NOT NULL DEFAULT 0, batt_energy_j REAL NOT NULL DEFAULT 0,
              temp_w REAL NOT NULL DEFAULT 0, hot_cpu_sec REAL NOT NULL DEFAULT 0, PRIMARY KEY(hour, app))
            """)
        exec("CREATE INDEX IF NOT EXISTS app_hourly_app ON app_hourly(app, hour)")
        exec("CREATE TABLE IF NOT EXISTS apps(app TEXT PRIMARY KEY, path TEXT)")
        exec("CREATE TABLE IF NOT EXISTS battery_daily(day INTEGER PRIMARY KEY, health REAL, cycles INTEGER)")
    }

    // MARK: Écriture (appelée une fois par minute)

    func record(_ r: MinuteRecord) {
        queue.async { [self] in
            guard db != nil else { return }
            exec("BEGIN")
            let m = Metric.allCases
            let ts = r.ts
            let hour = ts - ts % 3600

            // 1. Minute brute
            run("INSERT OR REPLACE INTO samples(ts, " + m.map(\.rawValue).joined(separator: ", ")
                + ", on_battery, top_app) VALUES(?" + String(repeating: ", ?", count: m.count + 2) + ")") { st in
                var i: Int32 = 1
                bind(st, &i, ts)
                for k in m { bind(st, &i, r.values[k]) }
                bind(st, &i, r.onBattery ? 1 : 0)
                bind(st, &i, r.topApp)
            }

            // 2. Agrégat horaire (UPSERT : sommes, compteurs, min, max, app de la minute la plus chaude)
            var cols = ["hour", "minutes", "batt_minutes", "hot_app"]
            var sets = ["minutes = minutes + 1", "batt_minutes = batt_minutes + excluded.batt_minutes",
                        "hot_app = CASE WHEN excluded.cpu_temp_max_max > coalesce(cpu_temp_max_max, -1000) THEN excluded.hot_app ELSE hot_app END"]
            for k in m {
                let c = k.rawValue
                cols += ["\(c)_sum", "\(c)_n", "\(c)_min", "\(c)_max"]
                sets += ["\(c)_sum = \(c)_sum + excluded.\(c)_sum",
                         "\(c)_n = \(c)_n + excluded.\(c)_n",
                         "\(c)_min = CASE WHEN excluded.\(c)_min IS NULL THEN \(c)_min WHEN \(c)_min IS NULL OR excluded.\(c)_min < \(c)_min THEN excluded.\(c)_min ELSE \(c)_min END",
                         "\(c)_max = CASE WHEN excluded.\(c)_max IS NULL THEN \(c)_max WHEN \(c)_max IS NULL OR excluded.\(c)_max > \(c)_max THEN excluded.\(c)_max ELSE \(c)_max END"]
            }
            run("INSERT INTO hourly(" + cols.joined(separator: ", ") + ") VALUES(?"
                + String(repeating: ", ?", count: cols.count - 1) + ") ON CONFLICT(hour) DO UPDATE SET "
                + sets.joined(separator: ", ")) { st in
                var i: Int32 = 1
                bind(st, &i, hour); bind(st, &i, 1); bind(st, &i, r.onBattery ? 1 : 0); bind(st, &i, r.topApp)
                for k in m {
                    let v = r.values[k]
                    bind(st, &i, v ?? 0); bind(st, &i, v == nil ? 0 : 1); bind(st, &i, v); bind(st, &i, v)
                }
            }

            // 3. Applications
            let temp = r.values[.cpuTemp] ?? 0
            let hot = (r.values[.cpuTempMax] ?? 0) >= Self.hotThreshold
            for (app, d) in r.apps where d.cpuSeconds >= 0.01 || d.energyJoules >= 0.01 {
                run("""
                    INSERT INTO app_hourly(hour, app, cpu_sec, energy_j, batt_energy_j, temp_w, hot_cpu_sec)
                    VALUES(?, ?, ?, ?, ?, ?, ?) ON CONFLICT(hour, app) DO UPDATE SET
                    cpu_sec = cpu_sec + excluded.cpu_sec, energy_j = energy_j + excluded.energy_j,
                    batt_energy_j = batt_energy_j + excluded.batt_energy_j, temp_w = temp_w + excluded.temp_w,
                    hot_cpu_sec = hot_cpu_sec + excluded.hot_cpu_sec
                    """) { st in
                    var i: Int32 = 1
                    bind(st, &i, hour); bind(st, &i, app); bind(st, &i, d.cpuSeconds); bind(st, &i, d.energyJoules)
                    bind(st, &i, r.onBattery ? d.energyJoules : 0); bind(st, &i, d.cpuSeconds * temp)
                    bind(st, &i, hot ? d.cpuSeconds : 0)
                }
            }
            for (app, path) in r.bundlePaths {
                run("INSERT OR REPLACE INTO apps(app, path) VALUES(?, ?)") { st in
                    var i: Int32 = 1; bind(st, &i, app); bind(st, &i, path)
                }
            }

            // 4. Santé batterie (une ligne par jour local)
            if let h = r.batteryHealth {
                let day = Int(Calendar.current.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(ts))).timeIntervalSince1970)
                run("INSERT OR REPLACE INTO battery_daily(day, health, cycles) VALUES(?, ?, ?)") { st in
                    var i: Int32 = 1; bind(st, &i, day); bind(st, &i, h); bind(st, &i, r.batteryCycles)
                }
            }

            // 5. Ménage : les minutes brutes ne sont gardées que 35 jours
            if ts % 86400 < 60 || Int.random(in: 0..<1440) == 0 {
                run("DELETE FROM samples WHERE ts < ?") { st in var i: Int32 = 1; bind(st, &i, ts - 35 * 86400) }
            }
            exec("COMMIT")
        }
    }

    // MARK: Lecture

    func minutes(from: Date, to: Date) -> [HistoryRow] {
        queue.sync {
            var rows: [HistoryRow] = []
            let m = Metric.allCases
            query("SELECT ts, on_battery, top_app, " + m.map(\.rawValue).joined(separator: ", ")
                  + " FROM samples WHERE ts >= ? AND ts < ? ORDER BY ts",
                  [Int(from.timeIntervalSince1970), Int(to.timeIntervalSince1970)]) { st in
                var values: [Metric: Agg] = [:]
                for (j, k) in m.enumerated() where sqlite3_column_type(st, Int32(3 + j)) != SQLITE_NULL {
                    var a = Agg(); a.add(sqlite3_column_double(st, Int32(3 + j))); values[k] = a
                }
                rows.append(HistoryRow(date: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(st, 0))),
                                       minutes: 1, batteryMinutes: Int(sqlite3_column_int(st, 1)),
                                       hotApp: text(st, 2), values: values))
            }
            return rows
        }
    }

    func hours(from: Date, to: Date) -> [HistoryRow] {
        queue.sync {
            var rows: [HistoryRow] = []
            let m = Metric.allCases
            let cols = m.map { "\($0.rawValue)_sum, \($0.rawValue)_n, \($0.rawValue)_min, \($0.rawValue)_max" }
            query("SELECT hour, minutes, batt_minutes, hot_app, " + cols.joined(separator: ", ")
                  + " FROM hourly WHERE hour >= ? AND hour < ? ORDER BY hour",
                  [Int(from.timeIntervalSince1970), Int(to.timeIntervalSince1970)]) { st in
                var values: [Metric: Agg] = [:]
                for (j, k) in m.enumerated() {
                    let b = Int32(4 + j * 4)
                    let n = Int(sqlite3_column_int(st, b + 1))
                    guard n > 0 else { continue }
                    values[k] = Agg(sum: sqlite3_column_double(st, b), n: n,
                                    min: sqlite3_column_double(st, b + 2), max: sqlite3_column_double(st, b + 3))
                }
                rows.append(HistoryRow(date: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(st, 0))),
                                       minutes: Int(sqlite3_column_int(st, 1)),
                                       batteryMinutes: Int(sqlite3_column_int(st, 2)),
                                       hotApp: text(st, 3), values: values))
            }
            return rows
        }
    }

    func appHours(from: Date, to: Date, app: String? = nil) -> [AppHourRow] {
        queue.sync {
            var rows: [AppHourRow] = []
            var sql = "SELECT hour, app, cpu_sec, energy_j, batt_energy_j, temp_w, hot_cpu_sec FROM app_hourly WHERE hour >= ? AND hour < ?"
            var args: [Any] = [Int(from.timeIntervalSince1970), Int(to.timeIntervalSince1970)]
            if let app { sql += " AND app = ?"; args.append(app) }
            query(sql, args) { st in
                rows.append(AppHourRow(date: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(st, 0))),
                                       app: text(st, 1) ?? "?", cpuSeconds: sqlite3_column_double(st, 2),
                                       energyJ: sqlite3_column_double(st, 3), batteryEnergyJ: sqlite3_column_double(st, 4),
                                       tempWeighted: sqlite3_column_double(st, 5), hotCpuSeconds: sqlite3_column_double(st, 6)))
            }
            return rows
        }
    }

    func appPaths() -> [String: String] {
        queue.sync {
            var out: [String: String] = [:]
            query("SELECT app, path FROM apps", []) { st in
                if let a = text(st, 0), let p = text(st, 1) { out[a] = p }
            }
            return out
        }
    }

    func batteryHealthHistory() -> [(Date, Double, Int)] {
        queue.sync {
            var out: [(Date, Double, Int)] = []
            query("SELECT day, health, cycles FROM battery_daily ORDER BY day", []) { st in
                out.append((Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(st, 0))),
                            sqlite3_column_double(st, 1), Int(sqlite3_column_int(st, 2))))
            }
            return out
        }
    }

    /// Date du tout premier enregistrement.
    func firstDate() -> Date? {
        queue.sync {
            var d: Date?
            query("SELECT min(hour) FROM hourly", []) { st in
                if sqlite3_column_type(st, 0) != SQLITE_NULL {
                    d = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(st, 0)))
                }
            }
            return d
        }
    }

    var fileSize: Int64 {
        ["", "-wal"].reduce(0) { acc, suffix in
            acc + ((try? FileManager.default.attributesOfItem(atPath: url.path + suffix)[.size] as? Int64) ?? 0)
        }
    }

    // MARK: SQLite bas niveau (toujours appelé sur `queue`)

    private func exec(_ sql: String) {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            NSLog("FanPilot SQLite: %@ — %@", String(cString: sqlite3_errmsg(db)), sql)
        }
    }

    private func run(_ sql: String, bindings: (OpaquePointer) -> Void) {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else {
            NSLog("FanPilot SQLite prepare: %@", String(cString: sqlite3_errmsg(db))); return
        }
        defer { sqlite3_finalize(st) }
        bindings(st)
        if sqlite3_step(st) != SQLITE_DONE { NSLog("FanPilot SQLite step: %@", String(cString: sqlite3_errmsg(db))) }
    }

    private func query(_ sql: String, _ args: [Any], row: (OpaquePointer) -> Void) {
        guard db != nil else { return }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else { return }
        defer { sqlite3_finalize(st) }
        var i: Int32 = 1
        for a in args {
            if let v = a as? Int { bind(st, &i, v) } else if let s = a as? String { bind(st, &i, s) }
        }
        while sqlite3_step(st) == SQLITE_ROW { row(st) }
    }

    private func text(_ st: OpaquePointer, _ col: Int32) -> String? {
        guard let c = sqlite3_column_text(st, col) else { return nil }
        return String(cString: c)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func bind(_ st: OpaquePointer, _ i: inout Int32, _ v: Int?) {
    if let v { sqlite3_bind_int64(st, i, Int64(v)) } else { sqlite3_bind_null(st, i) }
    i += 1
}
private func bind(_ st: OpaquePointer, _ i: inout Int32, _ v: Double?) {
    if let v, v.isFinite { sqlite3_bind_double(st, i, v) } else { sqlite3_bind_null(st, i) }
    i += 1
}
private func bind(_ st: OpaquePointer, _ i: inout Int32, _ v: String?) {
    if let v { sqlite3_bind_text(st, i, v, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(st, i) }
    i += 1
}
