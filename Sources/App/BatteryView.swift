import SwiftUI
import Charts

struct BatteryView: View {
    @EnvironmentObject var monitor: SystemMonitor
    @EnvironmentObject var period: PeriodState
    @EnvironmentObject var loader: HistoryLoader

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let b = monitor.battery {
                    current(b)
                } else {
                    Label("Aucune batterie détectée sur ce Mac.", systemImage: "battery.0").foregroundStyle(.secondary)
                }
                PeriodBar()
                let d = loader.data, i = period.interval
                periodSummary(d)
                TimeChart(title: "Niveau de charge",
                          series: [ChartSeries(name: "Charge", color: Palette.s1, points: d.points(.battPct))],
                          interval: i, format: { String(format: "%.0f %%", $0) }, domain: 0...100,
                          pointLabel: period.pointLabel)
                HStack(alignment: .top, spacing: 14) {
                    TimeChart(title: "Température de la batterie",
                              series: [ChartSeries(name: "Température", color: Palette.s2, points: d.points(.battTemp))],
                              interval: i, format: { String(format: "%.0f °C", $0) },
                              pointLabel: period.pointLabel, height: 150)
                    TimeChart(title: "Puissance batterie (+ charge / − décharge)",
                              series: [ChartSeries(name: "Puissance", color: Palette.s1, points: d.points(.battPower))],
                              interval: i, format: { String(format: "%+.0f W", $0) }, zeroLine: true,
                              pointLabel: period.pointLabel, height: 150)
                }
                HStack(alignment: .top, spacing: 14) {
                    drainers
                    healthChart
                }
            }
            .padding(20)
        }
        .modifier(ReloadOnPeriod())
    }

    // MARK: État actuel

    private func current(_ b: BatteryInfo) -> some View {
        HStack(spacing: 12) {
            StatTile(title: "Charge", value: "\(Int(b.percent)) %", detail: b.stateLabel,
                     symbol: b.charging ? "battery.100.bolt" : "battery.75")
            StatTile(title: b.power >= 0 ? "Entrée" : "Consommation", value: String(format: "%.1f W", abs(b.power)),
                     detail: b.minutesRemaining.map { (b.charging ? "plein dans " : "reste ") + duration(Double($0 * 60)) },
                     symbol: "bolt")
            // Une batterie est « chaude » bien plus tôt qu'un processeur.
            let t = b.temperature
            StatTile(title: "Température", value: String(format: "%.1f °C", t),
                     detail: t < 35 ? "Normale" : t < 45 ? "Tiède" : "Chaude, évite de la laisser chauffer en charge",
                     symbol: t < 35 ? "checkmark.circle.fill" : t < 45 ? "thermometer.medium" : "exclamationmark.triangle.fill",
                     tint: t < 35 ? .green : t < 45 ? .yellow : .orange)
            StatTile(title: "Santé", value: pct(b.health),
                     detail: "\(b.capacityNow) / \(b.capacityDesign) mAh d'origine",
                     symbol: b.health >= 0.8 ? "heart.fill" : "exclamationmark.triangle.fill",
                     tint: b.health >= 0.8 ? .green : .orange)
            StatTile(title: "Cycles", value: "\(b.cycles)", detail: "Apple garantit 1 000 cycles", symbol: "arrow.triangle.2.circlepath")
        }
    }

    private func periodSummary(_ d: PeriodData) -> some View {
        let drain = d.points(.battPower).filter { $0.value < 0 }.map { -$0.value }
        return HStack(spacing: 12) {
            StatTile(title: "Temps sur batterie", value: d.batteryMinutes > 0 ? duration(Double(d.batteryMinutes * 60)) : "0 min",
                     detail: d.minutes > 0 ? "sur \(duration(Double(d.minutes * 60))) enregistrées" : nil, symbol: "battery.50")
            StatTile(title: "Charge minimale", value: d.totals[.battPct].map { String(format: "%.0f %%", $0.min) } ?? "—",
                     symbol: "battery.25")
            StatTile(title: "Décharge moyenne", value: drain.isEmpty ? "—" : String(format: "%.1f W", drain.reduce(0, +) / Double(drain.count)),
                     symbol: "bolt.slash")
            StatTile(title: "Temp. batterie max", value: d.totals[.battTemp].map { String(format: "%.0f °C", $0.max) } ?? "—",
                     symbol: "thermometer.high")
        }
    }

    // MARK: Ce qui vide la batterie

    private var drainers: some View {
        let a = loader.apps
        let top = a.apps.filter { $0.batteryEnergyJ > 0 }.sorted { $0.batteryEnergyJ > $1.batteryEnergyJ }.prefix(8)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Ce qui vide la batterie").font(.headline)
            Text("Énergie consommée par chaque app pendant que le Mac était sur batterie.")
                .font(.caption).foregroundStyle(.secondary)
            if top.isEmpty {
                Text("Rien d'enregistré sur batterie pendant cette période.").foregroundStyle(.secondary).font(.callout)
            }
            ForEach(Array(top)) { app in
                let share = a.totalBattery > 0 ? app.batteryEnergyJ / a.totalBattery : 0
                HStack(spacing: 8) {
                    AppIcon(path: app.path)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(app.name).lineLimit(1)
                            Spacer()
                            Text(pct(share)).monospacedDigit().fontWeight(.semibold)
                            Text(energy(app.batteryEnergyJ)).monospacedDigit().foregroundStyle(.secondary).font(.caption)
                        }
                        Bar(value: share, tint: Palette.s1, height: 5)
                    }
                }
                .font(.callout)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Santé dans le temps

    private var healthChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Santé de la batterie dans le temps").font(.headline)
            if loader.health.count < 2 {
                Text("La courbe apparaîtra après quelques jours d'utilisation (une mesure par jour).")
                    .foregroundStyle(.secondary).font(.callout)
                if let h = loader.health.last {
                    Text("Aujourd'hui : \(pct(h.1)) · \(h.2) cycles").font(.callout)
                }
            } else {
                Chart {
                    ForEach(loader.health, id: \.0) { d, h, _ in
                        LineMark(x: .value("Jour", d), y: .value("Santé", h * 100))
                            .foregroundStyle(Palette.s3)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    RuleMark(y: .value("Seuil", 80)).foregroundStyle(.orange.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("80 % : remplacement conseillé").font(.caption2).foregroundStyle(.secondary)
                        }
                }
                .chartYScale(domain: 60...100)
                .chartYAxis { AxisMarks(position: .leading) { v in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d)) %").font(.caption2) } }
                } }
                .frame(height: 160)
                if let first = loader.health.first, let last = loader.health.last {
                    Text("\(pct(first.1)) → \(pct(last.1)) · \(last.2 - first.2) cycles depuis le début de l'enregistrement")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct AppIcon: View {
    let path: String?
    var size: CGFloat = 20

    var body: some View {
        Group {
            if let path, FileManager.default.fileExists(atPath: path) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable()
            } else {
                Image(systemName: "gearshape.fill").resizable().foregroundStyle(.secondary).padding(2)
            }
        }
        .frame(width: size, height: size)
    }
}
