import Foundation
import IOKit
import Darwin

// MARK: - Températures

enum SensorGroup: String, CaseIterable, Identifiable {
    case cpuP = "CPU – cœurs performance"
    case cpuE = "CPU – cœurs efficacité"
    case gpu = "GPU"
    case ssd = "SSD"
    case battery = "Batterie"
    case wifi = "Wi-Fi"
    case palm = "Repose-poignets"
    case other = "Autres"
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .cpuP, .cpuE: return "cpu"
        case .gpu: return "rectangle.3.group"
        case .ssd: return "internaldrive"
        case .battery: return "battery.75"
        case .wifi: return "wifi"
        case .palm: return "hand.raised"
        case .other: return "thermometer.medium"
        }
    }

    static func classify(_ key: String) -> SensorGroup {
        #if arch(x86_64)
        if ["TC0P", "TC0D", "TC0E", "TC0F", "TCXC"].contains(key) || key.hasPrefix("TC") && key.hasSuffix("C") { return .cpuP }
        if key.hasPrefix("TG0") { return .gpu }
        #else
        if key.hasPrefix("Tp") { return .cpuP }
        if key.hasPrefix("Te") { return .cpuE }
        if key.hasPrefix("Tg") { return .gpu }
        #endif
        if key.hasPrefix("TH0") { return .ssd }
        if key.hasPrefix("TB") && key.hasSuffix("T") { return .battery }
        if key == "TW0P" { return .wifi }
        if key == "Ts0P" || key == "Ts1P" { return .palm }
        return .other
    }
}

struct Sensor: Identifiable {
    let key: String
    let group: SensorGroup
    var value: Double
    var id: String { key }
}

struct GroupReading: Identifiable {
    let group: SensorGroup
    let average: Double
    let maximum: Double
    let count: Int
    var id: String { group.id }
}

/// Valeur crédible pour une température (°C).
private func plausible(_ t: Double) -> Bool { t > 5 && t < 125 }

final class TemperatureReader {
    private let smc: SMC
    private var keys: [(SMCValue, String, SensorGroup)] = []

    init(smc: SMC) {
        self.smc = smc
        // Énumération unique au démarrage : on garde les clés "T…" de type numérique
        // avec une valeur réaliste (les valeurs figées à 40.00 sont des consignes, pas des capteurs).
        for key in smc.allKeys() where key.hasPrefix("T") {
            guard var v = smc.readValue(key) else { continue }
            let t = withUnsafeBytes(of: v.type) { String(decoding: $0.prefix(4), as: UTF8.self) }
            guard t == "flt " || t == "sp78", let d = smc.refresh(&v), plausible(d), d != 40.0 else { continue }
            keys.append((v, key, SensorGroup.classify(key)))
        }
    }

    func read() -> [Sensor] {
        var out: [Sensor] = []
        out.reserveCapacity(keys.count)
        for i in keys.indices {
            guard let d = smc.refresh(&keys[i].0), plausible(d) else { continue }
            out.append(Sensor(key: keys[i].1, group: keys[i].2, value: d))
        }
        return out
    }

    static func summarize(_ sensors: [Sensor]) -> [GroupReading] {
        SensorGroup.allCases.compactMap { g in
            let vals = sensors.filter { $0.group == g }.map(\.value)
            guard !vals.isEmpty else { return nil }
            return GroupReading(group: g, average: vals.reduce(0, +) / Double(vals.count),
                                maximum: vals.max()!, count: vals.count)
        }
    }
}

// MARK: - Ventilateurs

struct FanInfo: Identifiable {
    let index: Int
    var actual: Double
    var minimum: Double
    var maximum: Double
    var target: Double
    var manual: Bool
    var id: Int { index }

    var name: String {
        switch index {
        case 0: return "Ventilateur gauche"
        case 1: return "Ventilateur droit"
        default: return "Ventilateur \(index + 1)"
        }
    }

    /// Pourcentage de la plage min…max.
    var percent: Double {
        guard maximum > minimum else { return 0 }
        return max(0, min(1, (actual - minimum) / (maximum - minimum)))
    }
}

final class FanReader {
    private let smc: SMC
    let count: Int

    init(smc: SMC) {
        self.smc = smc
        count = Int(smc.read("FNum") ?? 0)
    }

    func read() -> [FanInfo] {
        (0..<count).map { i in
            FanInfo(index: i,
                    actual: smc.read("F\(i)Ac") ?? 0,
                    minimum: smc.read("F\(i)Mn") ?? 0,
                    maximum: smc.read("F\(i)Mx") ?? 0,
                    target: smc.read("F\(i)Tg") ?? 0,
                    manual: Int(smc.read("F\(i)Md") ?? 0) == 1)
        }
    }
}

// MARK: - CPU

final class CPUReader {
    private var previous: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)] = []

    /// Retourne (usage total, usage par cœur) en 0…1.
    func read() -> (total: Double, cores: [Double]) {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                  &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return (0, []) }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        var current: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)] = []
        for i in 0..<Int(cpuCount) {
            let b = i * Int(CPU_STATE_MAX)
            current.append((UInt32(bitPattern: info[b + Int(CPU_STATE_USER)]),
                            UInt32(bitPattern: info[b + Int(CPU_STATE_SYSTEM)]),
                            UInt32(bitPattern: info[b + Int(CPU_STATE_IDLE)]),
                            UInt32(bitPattern: info[b + Int(CPU_STATE_NICE)])))
        }
        defer { previous = current }
        guard previous.count == current.count else { return (0, Array(repeating: 0, count: current.count)) }

        var busyTotal = 0.0, allTotal = 0.0
        var cores: [Double] = []
        for (c, p) in zip(current, previous) {
            let busy = Double((c.user &- p.user) &+ (c.system &- p.system) &+ (c.nice &- p.nice))
            let all = busy + Double(c.idle &- p.idle)
            cores.append(all > 0 ? busy / all : 0)
            busyTotal += busy
            allTotal += all
        }
        return (allTotal > 0 ? busyTotal / allTotal : 0, cores)
    }

    /// Nombre de cœurs efficacité (Apple Silicon), placés en tête de liste.
    static let efficiencyCores: Int = {
        var n: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.perflevel1.logicalcpu", &n, &size, nil, 0) == 0 ? Int(n) : 0
    }()
}

// MARK: - Mémoire

struct MemoryInfo {
    var used: UInt64 = 0
    var total: UInt64 = 0
    var percent: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

enum MemoryReader {
    static let total: UInt64 = {
        var v: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &v, &size, nil, 0)
        return v
    }()

    /// Même calcul que le Moniteur d'activité : mémoire des apps + câblée + compressée.
    static func read() -> MemoryInfo {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return MemoryInfo(used: 0, total: total) }
        let page = UInt64(vm_kernel_page_size)
        let app = UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)
        let used = (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        return MemoryInfo(used: used, total: total)
    }
}

// MARK: - GPU

enum GPUReader {
    /// Utilisation GPU en 0…1, lue dans les statistiques de l'IOAccelerator.
    static func read() -> Double? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }
        var best: Double?
        while case let entry = IOIteratorNext(iter), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let prop = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0),
                  let perf = prop.takeRetainedValue() as? [String: Any],
                  let util = perf["Device Utilization %"] as? NSNumber else { continue }
            best = max(best ?? 0, util.doubleValue / 100)
        }
        return best
    }
}

// MARK: - Disque

struct DiskInfo {
    var used: Int64 = 0
    var total: Int64 = 0
    var percent: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

enum DiskReader {
    static func read() -> DiskInfo {
        let url = URL(fileURLWithPath: "/")
        guard let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = v.volumeTotalCapacity,
              let free = v.volumeAvailableCapacityForImportantUsage else { return DiskInfo() }
        return DiskInfo(used: Int64(total) - free, total: Int64(total))
    }
}
