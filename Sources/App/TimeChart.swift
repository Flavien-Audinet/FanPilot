import SwiftUI
import Charts

struct ChartSeries: Identifiable {
    let name: String
    let color: Color
    let points: [Point]
    var id: String { name }
}

/// Courbe(s) dans le temps sur une période, avec infobulle au survol.
/// Un seul axe Y : chaque graphique ne contient que des séries de même unité.
struct TimeChart: View {
    let title: String
    let series: [ChartSeries]
    let interval: DateInterval
    let format: (Double) -> String
    var domain: ClosedRange<Double>? = nil
    var zeroLine = false
    var pointLabel: (Date) -> String
    var height: CGFloat = 180

    @State private var hoverDate: Date?

    private var hasData: Bool { series.contains { !$0.points.isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if series.count > 1 { legend }
            }
            if hasData {
                chart.frame(height: height)
            } else {
                Text("Pas encore de données sur cette période")
                    .foregroundStyle(.secondary).font(.callout)
                    .frame(maxWidth: .infinity, minHeight: height * 0.6)
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var legend: some View {
        HStack(spacing: 12) {
            ForEach(series) { s in
                HStack(spacing: 5) {
                    Capsule().fill(s.color).frame(width: 14, height: 3)
                    Text(s.name).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var chart: some View {
        Chart {
            if zeroLine {
                RuleMark(y: .value("zéro", 0)).foregroundStyle(.secondary.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 1))
            }
            ForEach(series) { s in
                ForEach(s.points) { p in
                    LineMark(x: .value("Date", p.date), y: .value(s.name, p.value),
                             series: .value("Série", "\(s.name)#\(p.segment)"))
                        .foregroundStyle(s.color)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
            }
            if let h = hoverDate {
                RuleMark(x: .value("Survol", h))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                ForEach(series) { s in
                    if let p = nearest(s.points, to: h) {
                        PointMark(x: .value("Date", p.date), y: .value(s.name, p.value))
                            .symbolSize(70)
                            .foregroundStyle(s.color)
                    }
                }
            }
        }
        .chartXScale(domain: interval.start...interval.end)
        .chartYScale(domain: domain ?? autoDomain)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel { if let d = v.as(Double.self) { Text(format(d)).font(.caption2) } }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 7)) { _ in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisTick()
                AxisValueLabel()
            }
        }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let loc):
                            guard let plot = proxy.plotFrame else { return }
                            let x = loc.x - geo[plot].origin.x
                            hoverDate = proxy.value(atX: x, as: Date.self)
                        case .ended:
                            hoverDate = nil
                        }
                    }
                if let h = hoverDate, let plot = proxy.plotFrame, let x = proxy.position(forX: h) {
                    tooltip(for: h)
                        .fixedSize()
                        .position(x: min(max(geo[plot].origin.x + x, 90), geo.size.width - 90), y: 26)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    @ViewBuilder
    private func tooltip(for date: Date) -> some View {
        let rows = series.compactMap { s in nearest(s.points, to: date).map { (s, $0) } }
        if let first = rows.first {
            VStack(alignment: .leading, spacing: 3) {
                Text(pointLabel(first.1.date)).font(.caption.weight(.semibold))
                ForEach(rows, id: \.0.id) { s, p in
                    HStack(spacing: 6) {
                        Capsule().fill(s.color).frame(width: 10, height: 3)
                        Text(s.name).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text(format(p.value)).monospacedDigit()
                    }
                    .font(.caption)
                }
            }
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
        }
    }

    private func nearest(_ pts: [Point], to d: Date) -> Point? {
        guard let p = pts.min(by: { abs($0.date.timeIntervalSince(d)) < abs($1.date.timeIntervalSince(d)) }) else { return nil }
        // pas d'infobulle au milieu d'un trou
        let span = pts.count > 1 ? interval.duration / Double(max(pts.count, 12)) * 3 : interval.duration
        return abs(p.date.timeIntervalSince(d)) <= max(span, 3600) ? p : nil
    }

    private var autoDomain: ClosedRange<Double> {
        let vals = series.flatMap { $0.points.map(\.value) }
        guard let lo = vals.min(), let hi = vals.max() else { return 0...1 }
        let pad = max((hi - lo) * 0.1, 1)
        return (zeroLine ? min(lo - pad, 0) : max(0, lo - pad))...(hi + pad)
    }
}

/// Petite tuile de statistique.
struct StatTile: View {
    let title: String
    let value: String
    var detail: String? = nil
    var symbol: String? = nil
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).foregroundStyle(tint == .primary ? .secondary : tint) }
                Text(title).foregroundStyle(.secondary)
            }
            .font(.caption)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Barre de navigation : type de période + ‹ date › + « Aujourd'hui ».
struct PeriodBar: View {
    @EnvironmentObject var period: PeriodState

    var body: some View {
        HStack(spacing: 12) {
            Picker("Période", selection: $period.kind) {
                ForEach(PeriodKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)

            Spacer()
            Button { period.shift(-1) } label: { Image(systemName: "chevron.left") }
                .help("Période précédente")
            Text(period.label)
                .font(.title3.weight(.semibold))
                .frame(minWidth: 260)
            Button { period.shift(1) } label: { Image(systemName: "chevron.right") }
                .disabled(period.isCurrent)
                .help("Période suivante")
            DatePicker("", selection: $period.anchor, in: ...Date(), displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.field)
                .frame(width: 110)
                .help("Aller à une date")
            Button("Aujourd'hui") { period.anchor = Date() }
                .disabled(period.isCurrent)
        }
    }
}
