import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: FanController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Debug : FANPILOT_CLOSE=1 -> ferme la fenêtre (mesure de la conso en arrière-plan).
        if ProcessInfo.processInfo.environment["FANPILOT_CLOSE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                NSApp.windows.filter { $0.canBecomeMain }.forEach { NSLog("fermeture: %@", $0.title); $0.close() }
            }
        }
        // Debug : FANPILOT_SNAPSHOT=/chemin.png -> capture de la fenêtre après 6 s.
        guard let path = ProcessInfo.processInfo.environment["FANPILOT_SNAPSHOT"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            guard let view = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.title == "FanPilot" })?.contentView?.superview,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Ne jamais laisser les ventilateurs bloqués en manuel après la fermeture.
        MainActor.assumeIsolated { controller?.restoreAll(sync: true) }
    }
}

@main
struct FanPilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var controller: FanController
    @StateObject private var monitor: SystemMonitor
    @StateObject private var period = PeriodState()
    @StateObject private var loader = HistoryLoader()

    init() {
        let c = FanController()
        _controller = StateObject(wrappedValue: c)
        _monitor = StateObject(wrappedValue: SystemMonitor(controller: c))
    }

    var body: some Scene {
        Window("FanPilot", id: "main") {
            RootView()
                .environmentObject(monitor)
                .environmentObject(controller)
                .environmentObject(period)
                .environmentObject(loader)
                .onAppear { delegate.controller = controller }
        }
        .defaultSize(width: 1240, height: 820)

        MenuBarExtra {
            MenuBarView()
                .environmentObject(monitor)
                .environmentObject(controller)
                .onAppear { delegate.controller = controller }
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var monitor: SystemMonitor
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "fan")
            Text(monitor.cpuTemp.map { String(format: "%.0f°", $0) } ?? "—")
                .monospacedDigit()
        }
    }
}

struct MenuBarView: View {
    @EnvironmentObject var monitor: SystemMonitor
    @EnvironmentObject var fans: FanController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                row("CPU", pct(monitor.cpuTotal), celsius(monitor.cpuTemp), monitor.cpuTotal)
                row("GPU", monitor.gpu.map(pct) ?? "—", celsius(monitor.gpuTemp), monitor.gpu ?? 0)
                row("Mémoire", pct(monitor.memory.percent), bytes(Int64(monitor.memory.used)), monitor.memory.percent)
                row("Disque", pct(monitor.disk.percent), bytes(monitor.disk.used), monitor.disk.percent)
            }
            Divider()
            ForEach(monitor.fans) { f in
                HStack {
                    Image(systemName: "fan.fill").foregroundStyle(.secondary)
                    Text(f.name)
                    Spacer()
                    Text(f.actual > 0 ? rpm(f.actual) : "À l'arrêt").monospacedDigit()
                    Text(fans.mode(f.index).rawValue).font(.caption).foregroundStyle(.secondary)
                        .frame(width: 50, alignment: .trailing)
                }
            }
            if fans.helperInstalled && !monitor.fans.isEmpty {
                HStack {
                    Button("Auto") { fans.setAll(.auto, fans: monitor.fans) }
                    Button("Max") { fans.setAll(.manual, fans: monitor.fans, rpmFraction: 1) }
                    Button("Courbe") { fans.setAll(.curve, fans: monitor.fans) }
                }
                .controlSize(.small)
            }
            Divider()
            HStack {
                Button("Ouvrir FanPilot") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quitter") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    @ViewBuilder
    private func row(_ name: String, _ value: String, _ detail: String, _ frac: Double) -> some View {
        GridRow {
            Text(name).fontWeight(.medium)
            Bar(value: frac).frame(width: 90)
            Text(value).monospacedDigit().gridColumnAlignment(.trailing)
            Text(detail).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}
