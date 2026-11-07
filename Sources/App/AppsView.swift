import SwiftUI
import Charts

enum AppSort: String, CaseIterable, Identifiable {
    case cpu = "Processeur", energy = "Énergie", battery = "Sur batterie", heat = "Chauffe"
    var id: String { rawValue }
    var help: String {
        switch self {
        case .cpu: return "Temps de calcul utilisé"
        case .energy: return "Énergie consommée (estimation de macOS)"
        case .battery: return "Énergie consommée pendant que le Mac était sur batterie"
        case .heat: return "Temps CPU utilisé pendant que le CPU dépassait \(Int(HistoryStore.hotThreshold)) °C"
        }
    }
}

struct AppsView: View {
    @EnvironmentObject var period: PeriodState
    @EnvironmentObject var loader: HistoryLoader
    @EnvironmentObject var fans: FanController
    @State private var sort: AppSort = .cpu
    @State private var selection: String?
    @State private var detail: [Point] = []

    private var rows: [AppUsage] {
        let a = loader.apps.apps
        switch sort {
        case .cpu: return a.sorted { $0.cpuSeconds > $1.cpuSeconds }
        case .energy: return a.sorted { $0.energyJ > $1.energyJ }
        case .battery: return a.filter { $0.batteryEnergyJ > 0 }.sorted { $0.batteryEnergyJ > $1.batteryEnergyJ }
        case .heat: return a.filter { $0.hotCpuSeconds > 0 }.sorted { $0.hotCpuSeconds > $1.hotCpuSeconds }
        }
    }

    var body: some View {
        let d = loader.apps
        VStack(alignment: .leading, spacing: 14) {
            PeriodBar()
            HStack {
                Picker("Classer par", selection: $sort) {
                    ForEach(AppSort.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 420)
                Text(sort.help).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !fans.helperInstalled {
                    Label("Sans l'utilitaire, seules tes apps sont comptées (pas les processus système).",
                          systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
            }

            top3(d)

            Table(rows, selection: $selection) {
                TableColumn("Application") { a in
                    HStack(spacing: 8) { AppIcon(path: a.path); Text(a.name).lineLimit(1) }
                }
                .width(min: 180, ideal: 240)
                TableColumn("Temps CPU") { a in Text(duration(a.cpuSeconds)).monospacedDigit() }
                    .width(90)
                TableColumn("CPU moyen") { a in
                    Text(d.recordedSeconds > 0 ? String(format: "%.1f %%", a.cpuSeconds / d.recordedSeconds * 100) : "—")
                        .monospacedDigit().help("100 % = un cœur occupé en permanence")
                }
                .width(80)
                TableColumn("Part du CPU") { a in share(a.cpuSeconds, d.totalCPU) }.width(110)
                TableColumn("Énergie") { a in
                    HStack { share(a.energyJ, d.totalEnergy); Text(energy(a.energyJ)).font(.caption).foregroundStyle(.secondary) }
                }
                .width(170)
                TableColumn("Sur batterie") { a in
                    a.batteryEnergyJ > 0 ? AnyView(share(a.batteryEnergyJ, d.totalBattery)) : AnyView(Text("—").foregroundStyle(.tertiary))
                }
                .width(110)
                TableColumn("Temp. CPU pendant son activité") { a in
                    if let t = a.avgTemp {
                        let h = Heat(t)
                        HStack(spacing: 4) {
                            Image(systemName: h.symbol).foregroundStyle(h.color)
                            Text(celsius(t)).monospacedDigit()
                        }
                    } else { Text("—").foregroundStyle(.tertiary) }
                }
                .width(min: 120, ideal: 180)
                TableColumn("Quand ça chauffe") { a in
                    a.hotCpuSeconds > 0 ? AnyView(share(a.hotCpuSeconds, d.totalHot)) : AnyView(Text("—").foregroundStyle(.tertiary))
                }
                .width(110)
            }
            .frame(minHeight: 280)

            detailChart
        }
        .padding(20)
        .modifier(ReloadOnPeriod())
        .onChange(of: selection) { loadDetail() }
        .onChange(of: period.anchor) { loadDetail() }
        .onChange(of: period.kind) { loadDetail() }
    }

    private func share(_ v: Double, _ total: Double) -> some View {
        let s = total > 0 ? v / total : 0
        return HStack(spacing: 6) {
            Bar(value: s, tint: Palette.s1, height: 5).frame(width: 50)
            Text(pct(s)).monospacedDigit()
        }
    }

    /// Résumé : quelle app consomme le plus / fait le plus chauffer.
    @ViewBuilder
    private func top3(_ d: AppsData) -> some View {
        let cpu = d.apps.max { $0.cpuSeconds < $1.cpuSeconds }
        let en = d.apps.max { $0.energyJ < $1.energyJ }
        let hot = d.apps.filter { $0.hotCpuSeconds > 0 }.max { $0.hotCpuSeconds < $1.hotCpuSeconds }
        let bat = d.apps.filter { $0.batteryEnergyJ > 0 }.max { $0.batteryEnergyJ < $1.batteryEnergyJ }
        HStack(spacing: 12) {
            StatTile(title: "Utilise le plus le processeur", value: cpu?.name ?? "—",
                     detail: cpu.map { "\(duration($0.cpuSeconds)) de calcul" }, symbol: "cpu")
            StatTile(title: "Consomme le plus d'énergie", value: en?.name ?? "—",
                     detail: en.map { d.totalEnergy > 0 ? "\(pct($0.energyJ / d.totalEnergy)) du total" : "" }, symbol: "bolt")
            StatTile(title: "Vide le plus la batterie", value: bat?.name ?? "—",
                     detail: bat.map { "\(pct($0.batteryEnergyJ / max(d.totalBattery, 0.001))) sur batterie" } ?? "rien sur batterie",
                     symbol: "battery.25")
            StatTile(title: "Fait le plus chauffer", value: hot?.name ?? "—",
                     detail: hot.map { "\(pct($0.hotCpuSeconds / max(d.totalHot, 0.001))) du CPU quand > \(Int(HistoryStore.hotThreshold)) °C" }
                        ?? "le Mac n'a pas dépassé \(Int(HistoryStore.hotThreshold)) °C",
                     symbol: "flame", tint: hot == nil ? .primary : .orange)
        }
    }

    @ViewBuilder
    private var detailChart: some View {
        if let app = selection {
            TimeChart(title: "\(app) — utilisation CPU (100 % = un cœur)",
                      series: [ChartSeries(name: app, color: Palette.s1, points: detail)],
                      interval: period.interval, format: { String(format: "%.0f %%", $0) },
                      pointLabel: period.pointLabel, height: 150)
        } else {
            Text("Sélectionne une application pour voir son utilisation dans le temps.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func loadDetail() {
        guard let app = selection else { detail = []; return }
        let kind = period.kind, i = period.interval, cal = period.calendar
        Task.detached {
            let pts = AppsData.series(app: app, kind: kind, interval: i, calendar: cal)
            await MainActor.run { if selection == app { detail = pts } }
        }
    }
}
