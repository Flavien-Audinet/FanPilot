import SwiftUI

// MARK: - Formatage

func pct(_ v: Double) -> String { "\(Int((v * 100).rounded())) %" }
func celsius(_ v: Double?) -> String { v.map { String(format: "%.0f °C", $0) } ?? "—" }
func rpm(_ v: Double) -> String { "\(Int(v.rounded())) tr/min" }
func bytes(_ v: Int64) -> String { ByteCountFormatter.string(fromByteCount: v, countStyle: .memory) }

// MARK: - État thermique (couleur + icône + libellé, jamais la couleur seule)

enum Heat {
    case normal, warm, hot, critical

    init(_ t: Double) {
        switch t {
        case ..<65: self = .normal
        case ..<80: self = .warm
        case ..<95: self = .hot
        default: self = .critical
        }
    }

    var color: Color {
        switch self {
        case .normal: return .green
        case .warm: return .yellow
        case .hot: return .orange
        case .critical: return .red
        }
    }

    var symbol: String {
        switch self {
        case .normal: return "checkmark.circle.fill"
        case .warm: return "thermometer.medium"
        case .hot: return "exclamationmark.triangle.fill"
        case .critical: return "flame.fill"
        }
    }

    var label: String {
        switch self {
        case .normal: return "Normal"
        case .warm: return "Tiède"
        case .hot: return "Chaud"
        case .critical: return "Critique"
        }
    }
}

// MARK: - Carte

struct Card<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(.secondary)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Jauge circulaire (tuile de statistique)

struct RingGauge: View {
    let title: String
    let value: Double          // 0…1
    let detail: String
    var tint: Color = .accentColor

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 8)
                Circle()
                    .trim(from: 0, to: max(0.001, min(1, value)))
                    .stroke(tint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(pct(value))
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .monospacedDigit()
            }
            .frame(width: 84, height: 84)
            Text(title).font(.subheadline.weight(.medium))
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(pct(value)), \(detail)")
    }
}

// MARK: - Barre horizontale fine

struct Bar: View {
    let value: Double   // 0…1
    var tint: Color = .accentColor
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint)
                    .frame(width: max(height, g.size.width * max(0, min(1, value))))
            }
        }
        .frame(height: height)
    }
}

// MARK: - Courbe d'historique avec survol

struct Sparkline: View {
    let values: [Double]
    let range: ClosedRange<Double>
    let format: (Double) -> String
    var tint: Color = .accentColor
    var interval: Double = 2      // secondes entre deux points

    @State private var hover: Int?

    var body: some View {
        GeometryReader { g in
            let pts = points(in: g.size)
            ZStack(alignment: .topLeading) {
                // grille discrète
                Path { p in
                    for f in [0.0, 0.5, 1.0] {
                        let y = g.size.height * f
                        p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: g.size.width, y: y))
                    }
                }.stroke(.quaternary, lineWidth: 0.5)

                if pts.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: g.size.height))
                        pts.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: pts.last!.x, y: g.size.height))
                        p.closeSubpath()
                    }.fill(tint.opacity(0.12))
                    Path { p in p.addLines(pts) }
                        .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }

                if let h = hover, h < pts.count {
                    let pt = pts[h]
                    Path { p in p.move(to: CGPoint(x: pt.x, y: 0)); p.addLine(to: CGPoint(x: pt.x, y: g.size.height)) }
                        .stroke(.secondary, lineWidth: 1)
                    Circle().fill(tint).frame(width: 8, height: 8)
                        .overlay(Circle().stroke(.background, lineWidth: 2))
                        .position(pt)
                    let ago = Int(Double(values.count - 1 - h) * interval)
                    Text("\(format(values[h]))  ·  il y a \(ago) s")
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                        .offset(x: min(max(0, pt.x - 60), g.size.width - 130), y: 2)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let loc) where pts.count > 1:
                    let step = g.size.width / CGFloat(max(1, pts.count - 1))
                    hover = min(pts.count - 1, max(0, Int((loc.x / step).rounded())))
                default: hover = nil
                }
            }
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let span = range.upperBound - range.lowerBound
        let step = size.width / CGFloat(values.count - 1)
        return values.enumerated().map { i, v in
            let f = span > 0 ? (min(max(v, range.lowerBound), range.upperBound) - range.lowerBound) / span : 0
            return CGPoint(x: CGFloat(i) * step, y: size.height * (1 - f))
        }
    }
}
