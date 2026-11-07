import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var monitor: SystemMonitor
    @EnvironmentObject var fans: FanController
    @State private var showSensors = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if !monitor.smcAvailable {
                    Label("Impossible d'accéder au SMC : températures et ventilateurs indisponibles.",
                          systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                usageRow
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 16) { temperatureCard; historyCard }
                    VStack(spacing: 16) { fanCard; coresCard }
                }
                allSensors
            }
            .padding(20)
        }
        .frame(minWidth: 860, minHeight: 640)
    }

    // MARK: En-tête

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("FanPilot").font(.largeTitle.bold())
                Text(Host.current().localizedName ?? "Mac").foregroundStyle(.secondary)
            }
            Spacer()
            if let p = monitor.power {
                Label(String(format: "%.1f W", p), systemImage: "bolt.fill")
                    .font(.title3.monospacedDigit())
                    .help("Consommation électrique totale du système")
            }
            if let t = monitor.cpuTemp {
                let h = Heat(monitor.cpuTempMax ?? t)
                Label("CPU \(celsius(t)) · \(h.label)", systemImage: h.symbol)
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(h.color)
                    .padding(.leading, 12)
            }
        }
    }

    // MARK: Utilisation

    private var usageRow: some View {
        HStack(spacing: 12) {
            RingGauge(title: "CPU", value: monitor.cpuTotal,
                      detail: "\(monitor.cpuCores.count) cœurs · \(celsius(monitor.cpuTemp))")
            RingGauge(title: "GPU", value: monitor.gpu ?? 0,
                      detail: monitor.gpu == nil ? "indisponible" : celsius(monitor.gpuTemp))
            RingGauge(title: "Mémoire", value: monitor.memory.percent,
                      detail: "\(bytes(Int64(monitor.memory.used))) / \(bytes(Int64(monitor.memory.total)))")
            RingGauge(title: "Disque", value: monitor.disk.percent,
                      detail: "\(bytes(monitor.disk.used)) / \(bytes(monitor.disk.total))")
        }
    }

    // MARK: Températures

    private var temperatureCard: some View {
        Card(title: "Températures", symbol: "thermometer.medium") {
            if monitor.groups.isEmpty {
                Text("Aucun capteur détecté").foregroundStyle(.secondary)
            }
            ForEach(monitor.groups.filter { $0.group != .other }) { g in
                let heat = Heat(g.maximum)
                HStack(spacing: 10) {
                    Image(systemName: g.group.symbol).frame(width: 18).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(g.group.rawValue)
                            Spacer()
                            Text(celsius(g.average)).monospacedDigit().fontWeight(.semibold)
                            Text("max \(celsius(g.maximum))").monospacedDigit()
                                .foregroundStyle(.secondary).font(.caption)
                        }
                        Bar(value: (g.average - 20) / 85, tint: heat.color)
                    }
                    Image(systemName: heat.symbol).foregroundStyle(heat.color)
                        .help(heat.label)
                }
            }
        }
    }

    private var historyCard: some View {
        Card(title: "Historique (3 min)", symbol: "chart.xyaxis.line") {
            Text("Utilisation CPU").font(.caption).foregroundStyle(.secondary)
            Sparkline(values: monitor.cpuHistory, range: 0...1, format: pct)
                .frame(height: 60)
            Text("Température CPU").font(.caption).foregroundStyle(.secondary)
            Sparkline(values: monitor.tempHistory, range: 20...105, format: { celsius($0) }, tint: .orange)
                .frame(height: 60)
        }
    }

    // MARK: Ventilateurs

    private var fanCard: some View {
        Card(title: "Ventilateurs", symbol: "fan") {
            if !fans.helperInstalled {
                VStack(alignment: .leading, spacing: 8) {
                    Text(fans.helperOutdated
                         ? "Une nouvelle version de l'utilitaire système est disponible (elle ajoute le suivi des processus système dans l'historique)."
                         : "Le contrôle des ventilateurs nécessite un petit utilitaire système (droits administrateur, une seule fois).")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(fans.helperOutdated ? "Mettre à jour l'utilitaire…" : "Activer le contrôle des ventilateurs…") {
                        fans.installHelper()
                    }
                    .buttonStyle(.borderedProminent)
                }
                Divider()
            }
            if monitor.fans.isEmpty {
                Text("Aucun ventilateur détecté").foregroundStyle(.secondary)
            }
            ForEach(monitor.fans) { fan in
                FanRow(fan: fan, cpuTemp: monitor.cpuTempMax ?? 0)
            }
            if fans.helperInstalled && !monitor.fans.isEmpty {
                HStack {
                    Button("Tout en auto") { fans.setAll(.auto, fans: monitor.fans) }
                    Button("Tout au max") { fans.setAll(.manual, fans: monitor.fans, rpmFraction: 1) }
                    Button("Tout en courbe") { fans.setAll(.curve, fans: monitor.fans) }
                }
                curveEditor
            }
            if let err = fans.lastError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            if fans.helperInstalled {
                Button("Désinstaller l'utilitaire de contrôle…") { fans.uninstallHelper() }
                    .buttonStyle(.link).font(.caption)
            }
        }
    }

    private var curveEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Courbe : macOS gère les ventilateurs sous le seuil, puis la vitesse monte jusqu'au maximum.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Démarrage").frame(width: 80, alignment: .leading)
                Slider(value: $fans.curveStart, in: 40...85, step: 1)
                Text(celsius(fans.curveStart)).monospacedDigit().frame(width: 50)
            }
            HStack {
                Text("Maximum à").frame(width: 80, alignment: .leading)
                Slider(value: $fans.curveEnd, in: max(fans.curveStart + 5, 50)...105, step: 1)
                Text(celsius(fans.curveEnd)).monospacedDigit().frame(width: 50)
            }
        }
        .font(.callout)
        .padding(.top, 4)
    }

    // MARK: Cœurs

    private var coresCard: some View {
        Card(title: "Cœurs CPU", symbol: "square.grid.3x3") {
            let e = CPUReader.efficiencyCores
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 8) {
                ForEach(Array(monitor.cpuCores.enumerated()), id: \.offset) { i, v in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(i < e ? "E\(i + 1)" : "P\(i - e + 1)").font(.caption2.weight(.medium))
                            Spacer()
                            Text(pct(v)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Bar(value: v, tint: i < e ? .teal : .accentColor, height: 5)
                    }
                    .help(i < e ? "Cœur efficacité \(i + 1)" : "Cœur performance \(i - e + 1)")
                }
            }
            if e > 0 {
                HStack(spacing: 12) {
                    Label("E = efficacité", systemImage: "circle.fill").foregroundStyle(.teal)
                    Label("P = performance", systemImage: "circle.fill").foregroundStyle(Color.accentColor)
                }
                .font(.caption2)
                .labelStyle(LegendLabel())
            }
        }
    }

    // MARK: Liste complète

    private var allSensors: some View {
        DisclosureGroup("Tous les capteurs (\(monitor.sensors.count))", isExpanded: $showSensors) {
            if showSensors { sensorGrid }
        }
    }

    private var sensorGrid: some View {
        Group {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), alignment: .leading, spacing: 4) {
                ForEach(monitor.sensors) { s in
                    HStack {
                        Text(s.key).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text(String(format: "%.1f °C", s.value)).font(.caption.monospacedDigit())
                    }
                    .help(s.group.rawValue)
                }
            }
            .padding(.top, 6)
        }
    }
}

private struct LegendLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 6))
            configuration.title.foregroundStyle(.secondary)
        }
    }
}

// MARK: - Ligne d'un ventilateur

struct FanRow: View {
    let fan: FanInfo
    let cpuTemp: Double
    @EnvironmentObject var fans: FanController
    @State private var draft: Double?

    var body: some View {
        let mode = fans.mode(fan.index)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "fan.fill").foregroundStyle(.secondary)
                Text(fan.name).fontWeight(.medium)
                Spacer()
                Text(fan.actual > 0 ? rpm(fan.actual) : "À l'arrêt")
                    .font(.title3.monospacedDigit().weight(.semibold))
            }
            Bar(value: fan.percent)
            Text("Plage \(Int(fan.minimum))–\(Int(fan.maximum)) tr/min · "
                 + (fan.manual ? "cible \(Int(fan.target)) · contrôle manuel"
                    : fan.actual > 0 ? "géré par macOS" : "arrêté par macOS (Mac froid)"))
                .font(.caption).foregroundStyle(.secondary)

            if fans.helperInstalled {
                Picker("Mode", selection: Binding(get: { mode }, set: { fans.setMode($0, fan: fan) })) {
                    ForEach(FanMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if mode == .manual {
                    let value = draft ?? fans.manualRPM[fan.index] ?? fan.minimum
                    HStack {
                        Slider(value: Binding(get: { value }, set: { draft = $0 }),
                               in: fan.minimum...max(fan.minimum + 1, fan.maximum), step: 50) { editing in
                            if !editing, let d = draft {
                                fans.setManualRPM(d, fan: fan)
                                draft = nil
                            }
                        }
                        Text(rpm(value)).monospacedDigit().frame(width: 95, alignment: .trailing)
                    }
                } else if mode == .curve {
                    let target = fans.curveRPM(for: cpuTemp, fan: fan)
                    Text(target.map { "CPU max \(celsius(cpuTemp)) → \(rpm($0))" }
                         ?? "CPU max \(celsius(cpuTemp)) < \(celsius(fans.curveStart)) : macOS garde la main")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
