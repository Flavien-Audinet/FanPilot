import Foundation
import IOKit

struct BatteryInfo {
    var percent: Double            // 0…100
    var temperature: Double        // °C
    var power: Double              // W ; > 0 en charge, < 0 en décharge
    var health: Double             // capacité réelle / capacité d'origine, 0…1
    var cycles: Int
    var onAC: Bool
    var charging: Bool
    var fullyCharged: Bool
    var minutesRemaining: Int?     // jusqu'à vide (batterie) ou plein (charge)
    var capacityNow: Int           // mAh
    var capacityDesign: Int        // mAh

    var stateLabel: String {
        if charging { return "En charge" }
        if onAC { return fullyCharged ? "Chargée, sur secteur" : "Sur secteur (charge en pause)" }
        return "Sur batterie"
    }
}

enum BatteryReader {
    static func read() -> BatteryInfo? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any] else { return nil }

        func int(_ k: String) -> Int? { (d[k] as? NSNumber)?.intValue }
        func bool(_ k: String) -> Bool { (d[k] as? NSNumber)?.boolValue ?? false }
        // L'ampérage est signé mais parfois publié comme entier non signé 64 bits.
        func signed(_ k: String) -> Int {
            guard let n = d[k] as? NSNumber else { return 0 }
            return Int(truncatingIfNeeded: Int64(bitPattern: n.uint64Value))
        }

        guard let pct = int("CurrentCapacity") else { return nil }
        let design = int("DesignCapacity") ?? 0
        let nominal = int("NominalChargeCapacity") ?? int("AppleRawMaxCapacity") ?? 0
        let volts = Double(int("Voltage") ?? 0) / 1000
        let amps = Double(signed("InstantAmperage") != 0 ? signed("InstantAmperage") : signed("Amperage")) / 1000
        let remaining = int("TimeRemaining").flatMap { $0 > 0 && $0 < 6000 ? $0 : nil }

        return BatteryInfo(
            percent: Double(pct),
            temperature: Double(int("Temperature") ?? 0) / 100,
            power: volts * amps,
            health: design > 0 ? min(1, Double(nominal) / Double(design)) : 0,
            cycles: int("CycleCount") ?? 0,
            onAC: bool("ExternalConnected"),
            charging: bool("IsCharging"),
            fullyCharged: bool("FullyCharged"),
            minutesRemaining: remaining,
            capacityNow: nominal,
            capacityDesign: design)
    }
}
