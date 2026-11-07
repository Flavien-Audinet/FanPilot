import Foundation

/// Consommation d'une application pendant un intervalle.
struct AppDelta {
    var cpuSeconds: Double = 0
    var energyJoules: Double = 0
}

/// Prend un instantané de tous les processus et calcule, par application,
/// le temps CPU et l'énergie consommés depuis l'instantané précédent.
final class ProcessSampler: @unchecked Sendable {   // utilisé uniquement sur la file "fanpilot.procs"
    private struct Proc { let responsible: Int32; let cpuNs: UInt64; let energyNj: UInt64; let path: String }
    private var previous: [Int32: Proc] = [:]
    /// Chemin du bundle .app pour chaque application vue (pour afficher son icône).
    private(set) var bundlePaths: [String: String] = [:]

    /// Retourne les deltas par application (vide au premier appel).
    func sample(useHelper: Bool) -> [String: AppDelta] {
        let current = (useHelper ? Self.snapshotViaHelper() : nil) ?? Self.snapshotLocal()
        defer { previous = current }
        guard !previous.isEmpty else { return [:] }

        var result: [String: AppDelta] = [:]
        for (pid, p) in current {
            guard let old = previous[pid], old.path == p.path, p.cpuNs >= old.cpuNs else { continue }
            let cpu = Double(p.cpuNs - old.cpuNs) / 1e9
            let energy = p.energyNj >= old.energyNj ? Double(p.energyNj - old.energyNj) / 1e9 : 0
            guard cpu > 0.001 || energy > 0.001 else { continue }
            let (name, bundle) = appIdentity(path: p.path, responsiblePath: current[p.responsible]?.path)
            if let bundle { bundlePaths[name] = bundle }
            result[name, default: AppDelta()].cpuSeconds += cpu
            result[name, default: AppDelta()].energyJoules += energy
        }
        return result
    }

    /// Regroupe les processus par application :
    /// - un exécutable dans un .app → l'app la plus externe (Chrome Helper → Google Chrome) ;
    /// - un service XPC / extension → l'app qui en est responsable (décodeur vidéo → Firefox) ;
    /// - sinon le nom de l'exécutable.
    private func appIdentity(path: String, responsiblePath: String?) -> (String, String?) {
        func outerApp(_ p: String) -> (String, String)? {
            guard let r = p.range(of: ".app/") else { return nil }
            let bundle = String(p[..<r.lowerBound]) + ".app"
            return ((bundle as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: ""), bundle)
        }
        if path.contains(".xpc/") || path.contains(".appex/"), let rp = responsiblePath, let app = outerApp(rp) {
            return app
        }
        if let app = outerApp(path) { return app }
        let name = (path as NSString).lastPathComponent
        return (name.isEmpty ? path : name, nil)
    }

    // MARK: Sources

    private static func snapshotLocal() -> [Int32: Proc] {
        let cap = 8192
        let buf = UnsafeMutablePointer<ProcSample>.allocate(capacity: cap)
        defer { buf.deallocate() }
        let n = Int(proc_snapshot(buf, Int32(cap)))
        var out: [Int32: Proc] = [:]
        out.reserveCapacity(n)
        for i in 0..<n {
            var s = buf[i]
            let path = withUnsafeBytes(of: &s.path) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            out[s.pid] = Proc(responsible: s.responsible_pid, cpuNs: s.cpu_ns, energyNj: s.energy_nj, path: path)
        }
        return out
    }

    /// Via le helper root : inclut aussi les processus système (WindowServer, kernel_task…).
    private static func snapshotViaHelper() -> [Int32: Proc]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: FanController.installedHelper)
        p.arguments = ["procs"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        var out: [Int32: Proc] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let f = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
            guard f.count == 5, let pid = Int32(f[0]), let resp = Int32(f[1]),
                  let cpu = UInt64(f[2]), let en = UInt64(f[3]) else { continue }
            out[pid] = Proc(responsible: resp, cpuNs: cpu, energyNj: en, path: String(f[4]))
        }
        return out.isEmpty ? nil : out
    }
}
