import SwiftUI

struct CellularCardView: View, Equatable {
    let wanIPv4: String
    let wanIPv6: String
    let speed: TrafficSpeed
    let trafficStats: TrafficStats
    let isTrafficAvailable: Bool
    let trafficUpdatedAt: Date?
    /// Measured seconds between distinct samples; sizes the odometer roll. See
    /// `DashboardViewModel.trafficSampleInterval`.
    var trafficSampleInterval: TimeInterval = 1
    var compact = false

    private func trafficCaption(at now: Date) -> String {
        Self.caption(updatedAt: trafficUpdatedAt, available: isTrafficAvailable, source: trafficStats.source, now: now)
    }

    static func caption(updatedAt: Date?, available: Bool, source: String, now: Date) -> String {
        guard let updatedAt else { return "Live traffic unavailable" }
        let age = max(0, Int(now.timeIntervalSince(updatedAt)))
        if !available || age >= 5 {
            return "Last traffic sample · \(age)s ago · waiting for device"
        }
        return source == "wwandst" ? "Live cellular traffic · all devices"
            : "Estimated cellular traffic · all devices"
    }

    var body: some View {
        CardView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Cellular traffic", systemImage: "arrow.up.arrow.down")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if compact { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                }

                if !compact && !wanIPv4.isEmpty {
                    HStack {
                        Text("WAN IP")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(wanIPv4)
                            .font(.caption.monospacedDigit())
                    }
                }
                if !compact && !wanIPv6.isEmpty {
                    HStack {
                        Text("WAN IPv6")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(wanIPv6)
                            .font(.caption2.monospacedDigit())
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let fresh = isTrafficAvailable && trafficUpdatedAt.map { context.date.timeIntervalSince($0) < 5 } == true
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Download", systemImage: "arrow.down").font(.caption).foregroundStyle(.secondary)
                            LiveTrafficValue(bytesPerSecond: fresh ? speed.downloadBytesPerSec : nil,
                                             sampleInterval: trafficSampleInterval)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Upload", systemImage: "arrow.up").font(.caption).foregroundStyle(.secondary)
                            LiveTrafficValue(bytesPerSecond: fresh ? speed.uploadBytesPerSec : nil,
                                             sampleInterval: trafficSampleInterval)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(trafficCaption(at: context.date))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if !compact {
                    Divider()
                    TrafficTotalRow(label: "Downloaded", bytes: trafficStats.rxBytes,
                                    sampleInterval: trafficSampleInterval)
                    TrafficTotalRow(label: "Uploaded", bytes: trafficStats.txBytes,
                                    sampleInterval: trafficSampleInterval)
                }
            }
        }
    }
}


private struct TrafficTotalRow: View {
    let label: String
    let bytes: UInt64
    let sampleInterval: TimeInterval
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let total = DeviceParser.bytesComponents(bytes)
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            AnimatedNumber(
                value: total.number,
                decimalPlaces: total.decimalPlaces,
                font: .caption.monospacedDigit(),
                textColor: .primary,
                animationDuration: NumberPresentation.trafficDuration(sampleInterval: sampleInterval,
                                                       reduceMotion: reduceMotion),
                suffix: total.unit
            )
        }
    }
}

struct LiveTrafficValue: View {
    let bytesPerSecond: Double?
    let sampleInterval: TimeInterval
    var font: Font = .title3.weight(.bold).monospacedDigit()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let bytesPerSecond {
                let components = DeviceParser.speedComponents(bytesPerSecond)
                // Keep the same text view across samples and unit changes. Availability is
                // based on having a sample, so a polling pause never recreates these digits.
                AnimatedNumber(
                    value: components.number,
                    decimalPlaces: components.decimalPlaces,
                    font: font,
                    textColor: .primary,
                    animationDuration: NumberPresentation.trafficDuration(sampleInterval: sampleInterval,
                                                           reduceMotion: reduceMotion),
                    suffix: components.unit
                )
            } else {
                Text("—").font(font)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }
}
