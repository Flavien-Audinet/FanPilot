import SwiftUI
import ServiceManagement

enum Screen: String, CaseIterable, Identifiable {
    case dashboard = "Tableau de bord"
    case history = "Historique"
    case battery = "Batterie"
    case apps = "Applications"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.50percent"
        case .history: return "chart.xyaxis.line"
        case .battery: return "battery.75"
        case .apps: return "square.grid.2x2"
        }
    }
}

struct RootView: View {
    // Debug : FANPILOT_SCREEN=Historique|Batterie|Applications pour ouvrir directement un écran.
    @State private var screen: Screen? = ProcessInfo.processInfo.environment["FANPILOT_SCREEN"]
        .flatMap(Screen.init(rawValue:)) ?? .dashboard

    var body: some View {
        NavigationSplitView {
            List(Screen.allCases, selection: $screen) { s in
                Label(s.rawValue, systemImage: s.symbol).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .bottom) { SidebarFooter() }
        } detail: {
            switch screen ?? .dashboard {
            case .dashboard: DashboardView()
            case .history: HistoryView()
            case .battery: BatteryView()
            case .apps: AppsView()
            }
        }
        .frame(minWidth: 1080, minHeight: 700)
    }
}

/// Bas de la barre latérale : lancement au démarrage + taille de l'historique.
struct SidebarFooter: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var info = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Ouvrir au démarrage", isOn: $launchAtLogin)
                .toggleStyle(.switch).controlSize(.small)
                .help("Pour un historique sans trous, FanPilot doit tourner en permanence.")
                .onChange(of: launchAtLogin) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        error = nil
                    } catch {
                        self.error = error.localizedDescription
                    }
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                    if SMAppService.mainApp.status == .requiresApproval {
                        self.error = "À autoriser dans Réglages Système › Général › Ouverture"
                        SMAppService.openSystemSettingsLoginItems()
                    }
                }
            if let error { Text(error).font(.caption2).foregroundStyle(.orange) }
            Text(info).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .onAppear(perform: refresh)
        .onReceive(Timer.publish(every: 300, on: .main, in: .common).autoconnect()) { _ in refresh() }
    }

    private func refresh() {
        let size = ByteCountFormatter.string(fromByteCount: HistoryStore.shared.fileSize, countStyle: .file)
        if let first = HistoryStore.shared.firstDate() {
            let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR"); f.dateFormat = "d MMM yyyy"
            info = "Historique depuis le \(f.string(from: first)) · \(size)"
        } else {
            info = "Historique : démarrage de l'enregistrement…"
        }
    }
}
