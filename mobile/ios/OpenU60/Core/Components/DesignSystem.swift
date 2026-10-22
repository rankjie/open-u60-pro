import SwiftUI

/// Shared measures and building blocks. Screens compose these instead of styling ad hoc, so type,
/// spacing and status colour read the same everywhere.
enum Design {
    static let gap: CGFloat = 12
    static let corner: CGFloat = 22
    /// Below this width, tile grids use two columns; above it they fill the row.
    static let tileMinWidth: CGFloat = 158

    static func value(_ size: Font.TextStyle = .title2) -> Font {
        .system(size, design: .rounded).weight(.semibold).monospacedDigit()
    }
}

/// A titled surface that opens a detail. The whole tile is the tap target.
struct Tile<Content: View>: View {
    let title: String
    let icon: String
    var tint: Color = .secondary
    var action: (() -> Void)?
    @ViewBuilder let content: Content

    var body: some View {
        if let action {
            Button(action: action) { surface.contentShape(.rect(cornerRadius: Design.corner)) }
                .buttonStyle(TileButtonStyle())
                .accessibilityHint("Opens \(title.lowercased()) details")
        } else {
            surface
        }
    }

    private var surface: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(tint).imageScale(.small)
                Text(title).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if action != nil {
                    Image(systemName: "chevron.right").imageScale(.small).foregroundStyle(.tertiary)
                }
            }
            .font(.footnote.weight(.semibold))
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: Design.corner))
        .accessibilityElement(children: .combine)
    }
}

struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

/// A primary reading: large number, small unit. A missing value reads as a dash, never zero.
struct Metric: View {
    let value: String?
    var unit: String = ""
    var style: Font.TextStyle = .title2
    var color: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value ?? "—")
                .font(Design.value(style))
                .foregroundStyle(value == nil ? .secondary : color)
                .contentTransition(.numericText())
            if value != nil, !unit.isEmpty {
                Text(unit).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

/// Secondary facts under a metric, joined with thin separators; empty parts are skipped.
struct Facts: View {
    let parts: [String]
    init(_ parts: String?...) { self.parts = parts.compactMap { $0 }.filter { !$0.isEmpty } }

    var body: some View {
        Text(parts.isEmpty ? " " : parts.joined(separator: " · "))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

/// A coloured dot with a word, for states such as Online or Charging.
struct StatusLabel: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption.weight(.semibold)).foregroundStyle(color == .secondary ? .secondary : color)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Measured samples only, oldest first. Fewer than two samples draw nothing.
struct Sparkline: Shape {
    let values: [Double]
    var ceiling: Double?
    /// Closes the line down to the baseline, for an area fill under it.
    var area = false
    /// Slots the chart spans, so a short history starts at the right edge and grows leftwards.
    var capacity: Int?

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        let top = max(ceiling ?? 0, values.max() ?? 0, 1)
        let slots = max(capacity ?? values.count, values.count)
        let step = rect.width / CGFloat(slots - 1)
        let start = CGFloat(slots - values.count) * step
        let points = values.enumerated().map { index, value in
            CGPoint(x: start + CGFloat(index) * step, y: rect.maxY - CGFloat(max(0, value) / top) * rect.height)
        }
        path.addLines(points)
        if area, let first = points.first, let last = points.last {
            path.addLine(to: CGPoint(x: last.x, y: rect.maxY))
            path.addLine(to: CGPoint(x: first.x, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

/// A single-row signal or battery level, drawn as segmented bars.
struct LevelBars: View {
    let level: Int
    var count = 4
    var color: Color = .primary

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<count, id: \.self) { bar in
                let fill: Color = bar < level ? color : Color(uiColor: .quaternaryLabel)
                RoundedRectangle(cornerRadius: 1)
                    .fill(fill)
                    .frame(width: 3, height: CGFloat(5 + bar * 3))
            }
        }
        .accessibilityHidden(true)
    }
}
