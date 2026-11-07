import Foundation

/// Accumule les mesures (toutes les 2 s) et écrit une moyenne par minute dans l'historique.
@MainActor
final class Recorder {
    private var minute = Int(Date().timeIntervalSince1970) / 60
    private var acc: [Metric: Agg] = [:]
    private var onBatteryTicks = 0, ticks = 0
    private let sampler = ProcessSampler()
    private let procQueue = DispatchQueue(label: "fanpilot.procs", qos: .utility)
    private let store = HistoryStore.shared

    init() {
        // Premier instantané des processus pour que le calcul différentiel démarre tout de suite.
        let sampler = sampler
        procQueue.async { _ = sampler.sample(useHelper: false) }
    }

    func add(_ values: [Metric: Double?], onBattery: Bool, battery: BatteryInfo?, helper: Bool) {
        let nowMinute = Int(Date().timeIntervalSince1970) / 60
        if nowMinute != minute {
            flush(battery: battery, helper: helper)
            minute = nowMinute
        }
        for (k, v) in values { if let v, v.isFinite { acc[k, default: Agg()].add(v) } }
        ticks += 1
        if onBattery { onBatteryTicks += 1 }
    }

    private func flush(battery: BatteryInfo?, helper: Bool) {
        guard ticks > 0 else { return }
        var values: [Metric: Double] = [:]
        for (k, a) in acc {
            values[k] = k == .cpuTempMax ? a.max : a.avg
        }
        let ts = minute * 60
        let onBattery = onBatteryTicks * 2 > ticks
        acc.removeAll(); ticks = 0; onBatteryTicks = 0

        let sampler = sampler, store = store
        procQueue.async {
            let apps = sampler.sample(useHelper: helper)
            let top = apps.max { $0.value.cpuSeconds < $1.value.cpuSeconds }?.key
            store.record(MinuteRecord(ts: ts, values: values, onBattery: onBattery, topApp: top, apps: apps,
                                      bundlePaths: sampler.bundlePaths,
                                      batteryHealth: battery?.health, batteryCycles: battery?.cycles))
        }
    }
}
