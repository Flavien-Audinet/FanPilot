import Foundation
import AppKit

enum FanMode: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case manual = "Manuel"
    case curve = "Courbe"
    var id: String { rawValue }
}

/// Pilote les ventilateurs via le helper root installé dans /Library/Application Support/FanPilot.
@MainActor
final class FanController: ObservableObject {
    nonisolated static let installDir = "/Library/Application Support/FanPilot"
    nonisolated static let installedHelper = installDir + "/fanpilot-helper"
    static var bundledHelper: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/fanpilot-helper").path
    }

    @Published var helperInstalled = false
    @Published var helperOutdated = false   // installé, mais d'une version précédente de l'app
    @Published var lastError: String?
    @Published var modes: [Int: FanMode] = [:]
    @Published var manualRPM: [Int: Double] = [:]

    // Paramètres de la courbe : en dessous de `curveStart` macOS garde la main,
    // puis la vitesse monte linéairement jusqu'au max à `curveEnd`.
    @Published var curveStart: Double { didSet { UserDefaults.standard.set(curveStart, forKey: "curveStart") } }
    @Published var curveEnd: Double { didSet { UserDefaults.standard.set(curveEnd, forKey: "curveEnd") } }

    private var lastApply: [Int: Date] = [:]
    private var busy: Set<Int> = []

    init() {
        let d = UserDefaults.standard
        curveStart = d.object(forKey: "curveStart") as? Double ?? 60
        curveEnd = d.object(forKey: "curveEnd") as? Double ?? 90
        refreshHelperStatus()
    }

    func mode(_ fan: Int) -> FanMode { modes[fan] ?? .auto }

    // MARK: Installation du helper

    func refreshHelperStatus() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: Self.installedHelper),
              (attrs[.ownerAccountID] as? NSNumber)?.intValue == 0,
              let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue, perms & 0o4000 != 0 else {
            helperInstalled = false
            helperOutdated = false
            return
        }
        let same = fm.contentsEqual(atPath: Self.installedHelper, andPath: Self.bundledHelper)
        helperInstalled = same
        helperOutdated = !same
    }

    private func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private func runAsAdmin(_ shell: String) -> Bool {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&err)
        if let err, (err[NSAppleScript.errorNumber] as? Int) != -128 {   // -128 = annulé par l'utilisateur
            lastError = err[NSAppleScript.errorMessage] as? String ?? "Échec de l'installation"
        }
        return err == nil
    }

    func installHelper() {
        let dst = Self.installedHelper
        let cmd = "mkdir -p \(shq(Self.installDir)) && cp \(shq(Self.bundledHelper)) \(shq(dst))"
            + " && chown root:wheel \(shq(dst)) && chmod 4755 \(shq(dst))"
        if runAsAdmin(cmd) { lastError = nil }
        refreshHelperStatus()
    }

    func uninstallHelper() {
        restoreAll(sync: true)
        _ = runAsAdmin("rm -rf \(shq(Self.installDir))")
        refreshHelperStatus()
    }

    // MARK: Exécution

    private nonisolated static func runHelper(_ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: installedHelper)
        p.arguments = args
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        p.waitUntilExit()
        let msg = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (p.terminationStatus, msg.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func send(fan: Int, _ args: [String]) {
        guard helperInstalled, !busy.contains(fan) else { return }
        busy.insert(fan)
        lastApply[fan] = Date()
        Task.detached {
            let (code, msg) = Self.runHelper(args)
            await MainActor.run {
                self.busy.remove(fan)
                if code != 0 { self.lastError = msg.isEmpty ? "Le helper a échoué (code \(code))" : msg }
                else { self.lastError = nil }
            }
        }
    }

    // MARK: Actions utilisateur

    func setMode(_ mode: FanMode, fan: FanInfo) {
        modes[fan.index] = mode
        switch mode {
        case .auto:
            send(fan: fan.index, ["auto", "\(fan.index)"])
        case .manual:
            let rpm = manualRPM[fan.index] ?? max(fan.actual, fan.minimum)
            manualRPM[fan.index] = rpm
            send(fan: fan.index, ["set", "\(fan.index)", "\(Int(rpm))"])
        case .curve:
            lastApply[fan.index] = nil   // appliqué au prochain tick
        }
    }

    func setManualRPM(_ rpm: Double, fan: FanInfo) {
        manualRPM[fan.index] = rpm
        if mode(fan.index) == .manual {
            send(fan: fan.index, ["set", "\(fan.index)", "\(Int(rpm))"])
        }
    }

    func setAll(_ mode: FanMode, fans: [FanInfo], rpmFraction: Double? = nil) {
        for f in fans {
            if let fr = rpmFraction { manualRPM[f.index] = f.minimum + (f.maximum - f.minimum) * fr }
            setMode(mode, fan: f)
        }
    }

    /// Rend tous les ventilateurs à macOS (à la fermeture de l'app notamment).
    func restoreAll(sync: Bool = false) {
        let touched = modes.values.contains { $0 != .auto }
        modes.removeAll()
        guard helperInstalled, touched else { return }
        if sync { _ = Self.runHelper(["auto-all"]) }
        else { Task.detached { _ = Self.runHelper(["auto-all"]) } }
    }

    // MARK: Boucle de régulation (appelée à chaque rafraîchissement)

    func curveRPM(for temp: Double, fan: FanInfo) -> Double? {
        guard temp >= curveStart else { return nil }
        let span = max(1, curveEnd - curveStart)
        let f = min(1, (temp - curveStart) / span)
        return fan.minimum + (fan.maximum - fan.minimum) * f
    }

    func tick(fans: [FanInfo], cpuTemp: Double) {
        guard helperInstalled else { return }
        let now = Date()
        for fan in fans {
            let i = fan.index
            let recent = lastApply[i].map { now.timeIntervalSince($0) < 5 } ?? false
            switch mode(i) {
            case .auto:
                break
            case .manual:
                // macOS peut reprendre la main (veille, thermalmonitord) : on réapplique.
                guard let rpm = manualRPM[i], !recent else { continue }
                if !fan.manual || abs(fan.target - rpm) > 50 {
                    send(fan: i, ["set", "\(i)", "\(Int(rpm))"])
                }
            case .curve:
                guard !recent else { continue }
                if let rpm = curveRPM(for: cpuTemp, fan: fan) {
                    if !fan.manual || abs(fan.target - rpm) > 150 {
                        send(fan: i, ["set", "\(i)", "\(Int(rpm))"])
                    }
                } else if fan.manual && cpuTemp < curveStart - 2 {   // hystérésis de 2 °C
                    send(fan: i, ["auto", "\(i)"])
                }
            }
        }
    }
}
