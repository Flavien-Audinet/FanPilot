import Foundation
import Combine

@MainActor
final class SystemMonitor: ObservableObject {
    @Published var sensors: [Sensor] = []
    @Published var groups: [GroupReading] = []
    @Published var fans: [FanInfo] = []
    @Published var cpuTotal: Double = 0
    @Published var cpuCores: [Double] = []
    @Published var gpu: Double?
    @Published var memory = MemoryInfo()
    @Published var disk = DiskInfo()
    @Published var power: Double?
    @Published var cpuHistory: [Double] = []
    @Published var tempHistory: [Double] = []
    @Published var smcAvailable = true
    @Published var battery: BatteryInfo?

    let controller: FanController
    private let smc: SMC?
    private let temps: TemperatureReader?
    private let fanReader: FanReader?
    private let cpu = CPUReader()
    private var timer: Timer?
    private var tickCount = 0
    private let recorder = Recorder()

    init(controller: FanController) {
        self.controller = controller
        smc = SMC()
        smcAvailable = smc != nil
        temps = smc.map(TemperatureReader.init)
        fanReader = smc.map(FanReader.init)
        _ = cpu.read()   // amorce le calcul différentiel
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Température CPU affichée : moyenne des cœurs performance (sinon efficacité).
    var cpuTemp: Double? {
        groups.first { $0.group == .cpuP }?.average ?? groups.first { $0.group == .cpuE }?.average
    }
    var cpuTempMax: Double? {
        groups.filter { $0.group == .cpuP || $0.group == .cpuE }.map(\.maximum).max()
    }
    var gpuTemp: Double? { groups.first { $0.group == .gpu }?.average }

    func refresh() {
        tickCount += 1
        if let temps {
            sensors = temps.read()
            groups = TemperatureReader.summarize(sensors)
        }
        if let fanReader { fans = fanReader.read() }
        let c = cpu.read()
        cpuTotal = c.total
        cpuCores = c.cores
        gpu = GPUReader.read()
        memory = MemoryReader.read()
        if tickCount % 15 == 1 { disk = DiskReader.read() }
        power = smc?.read("PSTR")

        if tickCount % 5 == 1 { battery = BatteryReader.read() }   // toutes les 10 s suffit

        let f = fans
        recorder.add([.cpu: cpuTotal, .gpu: gpu, .mem: memory.percent,
                      .cpuTemp: cpuTemp, .cpuTempMax: cpuTempMax, .gpuTemp: gpuTemp,
                      .fan0: f.count > 0 ? f[0].actual : nil, .fan1: f.count > 1 ? f[1].actual : nil,
                      .power: power, .battPct: battery?.percent, .battTemp: battery?.temperature,
                      .battPower: battery?.power],
                     onBattery: battery.map { !$0.onAC } ?? false, battery: battery,
                     helper: controller.helperInstalled)

        push(&cpuHistory, cpuTotal)
        if let t = cpuTemp { push(&tempHistory, t) }

        controller.tick(fans: fans, cpuTemp: cpuTempMax ?? 0)
    }

    private func push(_ arr: inout [Double], _ v: Double) {
        arr.append(v)
        if arr.count > 90 { arr.removeFirst(arr.count - 90) }   // 3 minutes d'historique
    }
}
