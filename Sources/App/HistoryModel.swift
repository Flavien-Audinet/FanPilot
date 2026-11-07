import Foundation
import SwiftUI

// MARK: - Couleurs des séries (palette catégorielle validée, clair / sombre)

enum Palette {
    private static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            let hex = ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                           blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        })
    }
    static let s1 = dyn(0x2a78d6, 0x3987e5)   // bleu
    static let s2 = dyn(0xeb6834, 0xd95926)   // orange
    static let s3 = dyn(0x1baf7a, 0x199e70)   // aqua
}

// MARK: - Période affichée

enum PeriodKind: String, CaseIterable, Identifiable {
    case day = "Jour", week = "Semaine", month = "Mois", year = "Année"
    var id: String { rawValue }
    var component: Calendar.Component {
        switch self { case .day: return .day; case .week: return .weekOfYear; case .month: return .month; case .year: return .year }
    }
    /// Taille d'un point du graphique.
    var bucket: Bucket {
        switch self { case .day: return .minutes(5); case .week: return .hours(1); case .month: return .hours(4); case .year: return .day }
    }
}

enum Bucket {
    case minutes(Int), hours(Int), day

    var seconds: TimeInterval {
        switch self { case .minutes(let m): return TimeInterval(m * 60); case .hours(let h): return TimeInterval(h * 3600); case .day: return 86400 }
    }

    /// Début du point (en heure locale) contenant `d`.
    func start(of d: Date, _ cal: Calendar) -> Date {
        switch self {
        case .minutes(let m):
            let t = d.timeIntervalSince1970
            return Date(timeIntervalSince1970: t - t.truncatingRemainder(dividingBy: TimeInterval(m * 60)))
        case .hours(let h):
            var c = cal.dateComponents([.year, .month, .day, .hour], from: d)
            c.hour = (c.hour ?? 0) / h * h
            return cal.date(from: c) ?? d
        case .day:
            return cal.startOfDay(for: d)
        }
    }
}

@MainActor
final class PeriodState: ObservableObject {
    @Published var kind: PeriodKind = ProcessInfo.processInfo.environment["FANPILOT_PERIOD"]
        .flatMap(PeriodKind.init(rawValue:)) ?? .day   // debug : Jour|Semaine|Mois|Année
    @Published var anchor = Date()

    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: "fr_FR")
        c.firstWeekday = 2   // semaine du lundi au dimanche
        return c
    }

    var interval: DateInterval {
        calendar.dateInterval(of: kind.component, for: anchor) ?? DateInterval(start: anchor, duration: 86400)
    }

    var isCurrent: Bool { interval.contains(Date()) }

    func shift(_ n: Int) {
        if let d = calendar.date(byAdding: kind.component, value: n, to: anchor) { anchor = d }
    }

    var label: String {
        let i = interval
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        switch kind {
        case .day:
            f.dateFormat = "EEEE d MMMM yyyy"
            return f.string(from: i.start).capitalizedFirst
        case .week:
            let end = i.end.addingTimeInterval(-1)
            f.dateFormat = "d MMMM yyyy"
            let endStr = f.string(from: end)
            f.dateFormat = calendar.isDate(i.start, equalTo: end, toGranularity: .month) ? "d" : "d MMMM"
            return "Semaine du \(f.string(from: i.start)) au \(endStr)"
        case .month:
            f.dateFormat = "MMMM yyyy"
            return f.string(from: i.start).capitalizedFirst
        case .year:
            f.dateFormat = "yyyy"
            return f.string(from: i.start)
        }
    }

    /// Format de la date dans l'infobulle d'un point.
    func pointLabel(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        switch kind {
        case .day: f.dateFormat = "HH:mm"
        case .week: f.dateFormat = "EEE d MMM, HH'h'"
        case .month: f.dateFormat = "EEE d MMM, HH'h'"
        case .year: f.dateFormat = "EEEE d MMMM yyyy"
        }
        return f.string(from: d)
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: - Données agrégées d'une période

struct Point: Identifiable {
    let date: Date
    let value: Double
    let segment: Int          // les trous (app fermée, Mac en veille) coupent la courbe
    var id: Date { date }
}

struct MonthSummary: Identifiable {
    let month: Date
    let minutes: Int
    let batteryMinutes: Int
    let values: [Metric: Agg]
    var id: Date { month }
}

struct Peak: Identifiable {
    let date: Date
    let temp: Double
    let app: String?
    var id: Date { date }
}

struct PeriodData {
    var buckets: [(Date, [Metric: Agg], Int)] = []    // (début, agrégats, minutes enregistrées)
    var totals: [Metric: Agg] = [:]
    var minutes = 0
    var batteryMinutes = 0
    var peaks: [Peak] = []
    var months: [MonthSummary] = []
    var bucketSeconds: TimeInterval = 300

    var isEmpty: Bool { minutes == 0 }

    /// Série moyenne (ou max) d'une grandeur, coupée aux trous.
    func points(_ m: Metric, useMax: Bool = false, scale: Double = 1) -> [Point] {
        var out: [Point] = []
        var seg = 0
        var last: Date?
        for (d, vals, _) in buckets {
            guard let a = vals[m], let avg = a.avg else { continue }
            if let l = last, d.timeIntervalSince(l) > bucketSeconds * 1.5 { seg += 1 }
            out.append(Point(date: d, value: (useMax ? a.max : avg) * scale, segment: seg))
            last = d
        }
        return out
    }

    static func load(_ kind: PeriodKind, _ interval: DateInterval, calendar cal: Calendar) -> PeriodData {
        let store = HistoryStore.shared
        var rows = kind == .day ? store.minutes(from: interval.start, to: interval.end) : []
        if rows.isEmpty { rows = store.hours(from: interval.start, to: interval.end) }   // > 35 jours : données horaires
        let bucket: Bucket = kind == .day && rows.first?.minutes ?? 1 > 1 ? .hours(1) : kind.bucket

        var data = PeriodData()
        data.bucketSeconds = bucket.seconds
        var map: [Date: ([Metric: Agg], Int)] = [:]
        var monthMap: [Date: ([Metric: Agg], Int, Int)] = [:]
        var peakRows: [Peak] = []

        for r in rows {
            let b = bucket.start(of: r.date, cal)
            var entry = map[b] ?? ([:], 0)
            for (k, a) in r.values {
                entry.0[k, default: Agg()].merge(a)
                data.totals[k, default: Agg()].merge(a)
            }
            entry.1 += r.minutes
            map[b] = entry
            data.minutes += r.minutes
            data.batteryMinutes += r.batteryMinutes
            if let t = r.values[.cpuTempMax]?.max, t.isFinite { peakRows.append(Peak(date: r.date, temp: t, app: r.hotApp)) }

            if kind == .year, let m = cal.dateInterval(of: .month, for: r.date)?.start {
                var e = monthMap[m] ?? ([:], 0, 0)
                for (k, a) in r.values { e.0[k, default: Agg()].merge(a) }
                e.1 += r.minutes; e.2 += r.batteryMinutes
                monthMap[m] = e
            }
        }
        data.buckets = map.keys.sorted().map { ($0, map[$0]!.0, map[$0]!.1) }

        // Pics : les moments les plus chauds, en évitant d'en lister plusieurs dans la même heure.
        var seen = Set<Date>()
        data.peaks = peakRows.sorted { $0.temp > $1.temp }.filter { p in
            let h = Bucket.hours(1).start(of: p.date, cal)
            return seen.insert(h).inserted
        }.prefix(5).map { $0 }

        if kind == .year {
            data.months = (0..<12).compactMap { i in
                guard let m = cal.date(byAdding: .month, value: i, to: interval.start) else { return nil }
                let e = monthMap[m]
                return MonthSummary(month: m, minutes: e?.1 ?? 0, batteryMinutes: e?.2 ?? 0, values: e?.0 ?? [:])
            }
        }
        return data
    }
}

// MARK: - Applications sur une période

struct AppUsage: Identifiable {
    let name: String
    var cpuSeconds = 0.0
    var energyJ = 0.0
    var batteryEnergyJ = 0.0
    var tempWeighted = 0.0
    var hotCpuSeconds = 0.0
    var path: String?
    var id: String { name }

    var avgTemp: Double? { cpuSeconds > 1 ? tempWeighted / cpuSeconds : nil }
}

struct AppsData {
    var apps: [AppUsage] = []
    var recordedSeconds = 0.0
    var totalCPU = 0.0, totalEnergy = 0.0, totalBattery = 0.0, totalHot = 0.0

    static func load(_ interval: DateInterval) -> AppsData {
        let store = HistoryStore.shared
        let paths = store.appPaths()
        var map: [String: AppUsage] = [:]
        for r in store.appHours(from: interval.start, to: interval.end) {
            var a = map[r.app] ?? AppUsage(name: r.app, path: paths[r.app])
            a.cpuSeconds += r.cpuSeconds; a.energyJ += r.energyJ; a.batteryEnergyJ += r.batteryEnergyJ
            a.tempWeighted += r.tempWeighted; a.hotCpuSeconds += r.hotCpuSeconds
            map[r.app] = a
        }
        var d = AppsData()
        d.apps = Array(map.values)
        d.totalCPU = d.apps.reduce(0) { $0 + $1.cpuSeconds }
        d.totalEnergy = d.apps.reduce(0) { $0 + $1.energyJ }
        d.totalBattery = d.apps.reduce(0) { $0 + $1.batteryEnergyJ }
        d.totalHot = d.apps.reduce(0) { $0 + $1.hotCpuSeconds }
        d.recordedSeconds = Double(store.hours(from: interval.start, to: interval.end).reduce(0) { $0 + $1.minutes } * 60)
        return d
    }

    /// Utilisation CPU d'une app dans le temps (en % d'un cœur).
    static func series(app: String, kind: PeriodKind, interval: DateInterval, calendar cal: Calendar) -> [Point] {
        let store = HistoryStore.shared
        let bucket: Bucket = kind == .day ? .hours(1) : kind.bucket
        var cpu: [Date: Double] = [:], rec: [Date: Double] = [:]
        for r in store.appHours(from: interval.start, to: interval.end, app: app) {
            cpu[bucket.start(of: r.date, cal), default: 0] += r.cpuSeconds
        }
        for h in store.hours(from: interval.start, to: interval.end) {
            rec[bucket.start(of: h.date, cal), default: 0] += Double(h.minutes * 60)
        }
        var seg = 0
        var last: Date?
        return rec.keys.sorted().compactMap { d in
            guard let s = rec[d], s > 0 else { return nil }
            if let l = last, d.timeIntervalSince(l) > bucket.seconds * 1.5 { seg += 1 }
            last = d
            return Point(date: d, value: (cpu[d] ?? 0) / s * 100, segment: seg)
        }
    }
}

// MARK: - Formats

func duration(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    if s < 60 { return "\(s) s" }
    if s < 3600 { return "\(s / 60) min \(String(format: "%02d", s % 60)) s" }
    let h = s / 3600, m = (s % 3600) / 60
    if h < 48 { return "\(h) h \(String(format: "%02d", m))" }
    return "\(h / 24) j \(h % 24) h"
}

func energy(_ joules: Double) -> String {
    let wh = joules / 3600
    return wh >= 1 ? String(format: "%.1f Wh", wh) : String(format: "%.0f mWh", wh * 1000)
}
