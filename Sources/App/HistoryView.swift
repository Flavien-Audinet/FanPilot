import SwiftUI
import Charts

/// Recharge les données quand la période change, et chaque minute pour la période en cours.
@MainActor
final class HistoryLoader: ObservableObject {
    @Published var data = PeriodData()
    @Published var apps = AppsData()
    @Published var health: [(Date, Double, Int)] = []
    private var key = ""
    private var lastLoad = Date.distantPast

    func reload(_ p: PeriodState, force: Bool = false) {
        let k = "\(p.kind.rawValue)|\(p.interval.start.timeIntervalSince1970)"
        guard force || k != key || (p.isCurrent && Date().timeIntervalSince(lastLoad) > 55) else { return }
        key = k
        lastLoad = Date()
        let kind = p.kind, interval = p.interval, cal = p.calendar
        Task.detached(priority: .userInitiated) {
            let d = PeriodData.load(kind, interval, calendar: cal)
            let a = AppsData.load(interval)
            let h = HistoryStore.shared.batteryHealthHistory()
            await MainActor.run {
                guard k == self.key else { return }
                self.data = d; self.apps = a; self.health = h
            }
        }
    }
}

/// Modificateur commun : charge au changement de période et toutes les minutes.
struct ReloadOnPeriod: ViewModifier {
    @EnvironmentObject var period: PeriodState
    @EnvironmentObject var loader: HistoryLoader
    let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    func body(content: Content) -> some View {
        content
            .onAppear { loader.reload(period) }
            .onChange(of: period.kind) { loader.reload(period) }
            .onChange(of: period.anchor) { loader.reload(period) }
            .onReceive(timer) { _ in loader.reload(period) }
    }
}

// MARK: - Historique

struct HistoryView: View {
    @EnvironmentObject var period: PeriodState
    @EnvironmentObject var loader: HistoryLoader

    var body: some View {
        let d = loader.data
        let i = period.interval
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PeriodBar()
                summary(d)

                TimeChart(title: "Températures",
                          series: [ChartSeries(name: "CPU (moyenne)", color: Palette.s1, points: d.points(.cpuTemp)),
                                   ChartSeries(name: "CPU (pic)", color: Palette.s2, points: d.points(.cpuTempMax, useMax: true)),
                                   ChartSeries(name: "GPU", color: Palette.s3, points: d.points(.gpuTemp))],
                          interval: i, format: { String(format: "%.0f °C", $0) },
                          pointLabel: period.pointLabel)

                TimeChart(title: "Utilisation",
                          series: [ChartSeries(name: "CPU", color: Palette.s1, points: d.points(.cpu, scale: 100)),
                                   ChartSeries(name: "GPU", color: Palette.s2, points: d.points(.gpu, scale: 100)),
                                   ChartSeries(name: "Mémoire", color: Palette.s3, points: d.points(.mem, scale: 100))],
                          interval: i, format: { String(format: "%.0f %%", $0) }, domain: 0...100,
                          pointLabel: period.pointLabel)

                HStack(alignment: .top, spacing: 14) {
                    TimeChart(title: "Ventilateurs",
                              series: [ChartSeries(name: "Gauche", color: Palette.s1, points: d.points(.fan0)),
                                       ChartSeries(name: "Droit", color: Palette.s2, points: d.points(.fan1))],
                              interval: i, format: { String(format: "%.0f tr/min", $0) },
                              pointLabel: period.pointLabel, height: 150)
                    TimeChart(title: "Consommation du Mac",
                              series: [ChartSeries(name: "Puissance", color: Palette.s1, points: d.points(.power))],
                              interval: i, format: { String(format: "%.0f W", $0) },
                              pointLabel: period.pointLabel, height: 150)
                }

                if period.kind == .year { MonthTable(months: d.months) }
                PeaksCard(peaks: d.peaks, kind: period.kind)
            }
            .padding(20)
        }
        .modifier(ReloadOnPeriod())
    }

    @ViewBuilder
    private func summary(_ d: PeriodData) -> some View {
        let temp = d.totals[.cpuTemp]?.avg
        let peak = d.peaks.first
        HStack(spacing: 12) {
            StatTile(title: "Temp. CPU moyenne", value: celsius(temp), symbol: "thermometer.medium")
            StatTile(title: "Pic CPU", value: celsius(peak?.temp),
                     detail: peak.map { period.pointLabel($0.date) + ($0.app.map { " · \($0)" } ?? "") },
                     symbol: peak.map { Heat($0.temp).symbol } ?? "flame",
                     tint: peak.map { Heat($0.temp).color } ?? .primary)
            StatTile(title: "Utilisation CPU moyenne", value: d.totals[.cpu]?.avg.map(pct) ?? "—", symbol: "cpu")
            StatTile(title: "Consommation moyenne", value: d.totals[.power]?.avg.map { String(format: "%.1f W", $0) } ?? "—",
                     symbol: "bolt")
            StatTile(title: "Temps enregistré", value: d.minutes > 0 ? duration(Double(d.minutes * 60)) : "—",
                     detail: d.batteryMinutes > 0 ? "dont \(duration(Double(d.batteryMinutes * 60))) sur batterie" : nil,
                     symbol: "clock")
        }
    }
}

// MARK: - Tableau mois par mois (vue Année)

struct MonthTable: View {
    let months: [MonthSummary]

    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR"); f.dateFormat = "MMMM"; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mois par mois").font(.headline)
            Chart {
                ForEach(months.filter { $0.values[.cpuTemp]?.avg != nil }) { m in
                    BarMark(x: .value("Mois", m.month, unit: .month), y: .value("Temp. moyenne", m.values[.cpuTemp]!.avg!))
                        .foregroundStyle(Palette.s1)
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
                        .annotation(position: .top) {
                            Text(String(format: "%.0f°", m.values[.cpuTemp]!.avg!)).font(.caption2).foregroundStyle(.secondary)
                        }
                }
            }
            .chartXAxis { AxisMarks(values: .stride(by: .month)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated)) } }
            .chartYAxis { AxisMarks(position: .leading) { v in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d)) °C").font(.caption2) } }
            } }
            .frame(height: 140)

            Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    Text("Mois").gridColumnAlignment(.leading)
                    Text("Temp. CPU moy."); Text("Pic CPU"); Text("CPU moyen"); Text("GPU moyen")
                    Text("Conso moy."); Text("Enregistré"); Text("Sur batterie")
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Divider()
                ForEach(months) { m in
                    let has = m.minutes > 0
                    GridRow {
                        Text(Self.fmt.string(from: m.month).capitalizedFirst)
                        Text(has ? celsius(m.values[.cpuTemp]?.avg) : "—")
                        Text(has ? celsius(m.values[.cpuTempMax]?.max) : "—")
                        Text(has ? m.values[.cpu]?.avg.map(pct) ?? "—" : "—")
                        Text(has ? m.values[.gpu]?.avg.map(pct) ?? "—" : "—")
                        Text(has ? m.values[.power]?.avg.map { String(format: "%.1f W", $0) } ?? "—" : "—")
                        Text(has ? duration(Double(m.minutes * 60)) : "—")
                        Text(has ? duration(Double(m.batteryMinutes * 60)) : "—")
                    }
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(has ? .primary : .tertiary)
                }
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Pics de température

struct PeaksCard: View {
    let peaks: [Peak]
    let kind: PeriodKind

    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR"); f.dateFormat = "EEEE d MMMM yyyy 'à' HH'h'"; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Moments les plus chauds").font(.headline)
            if peaks.isEmpty {
                Text("Pas encore de données sur cette période").foregroundStyle(.secondary).font(.callout)
            }
            ForEach(peaks) { p in
                let h = Heat(p.temp)
                HStack {
                    Image(systemName: h.symbol).foregroundStyle(h.color).frame(width: 18)
                    Text(celsius(p.temp)).monospacedDigit().fontWeight(.semibold).frame(width: 55, alignment: .leading)
                    Text(h.label).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                    Text(Self.fmt.string(from: p.date).capitalizedFirst)
                    Spacer()
                    if let app = p.app {
                        Text("App la plus active : ").foregroundStyle(.secondary) + Text(app).fontWeight(.medium)
                    }
                }
                .font(.callout)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}
