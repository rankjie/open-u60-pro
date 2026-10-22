import SwiftUI

struct BatteryOverviewCard: View {
    let battery: BatteryStatus
    let updatedAt: Date?
    let powerbankActive: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { context in
            let fresh = updatedAt.map { context.date.timeIntervalSince($0) < 10 } ?? false
            let current = fresh ? battery : .empty
            CardView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Label("Battery & power", systemImage: "battery.100").font(.headline)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    HStack(alignment: .top, spacing: 16) {
                        metric("Remaining", value: current.capacityText, detail: current.remainingChargeText)
                        metric(current.powerWatts.map { $0 > 0.05 ? "Battery charging" : powerbankActive ? "Total battery draw" : "Battery draw" } ?? "Battery power",
                               value: current.powerWatts.map { String(format: "%.1f W", abs($0)) } ?? "— W",
                               detail: current.statusText)
                    }
                    Divider()
                    powerRow("Estimated runtime", value: current.usbPower.externalPower == true ? "External power" : current.runtimeText)
                    if let input = current.usbPower.inputWatts {
                        powerRow("USB input", value: String(format: "%.1f W", input))
                    }
                    if powerbankActive || current.usbPower.role == "source" {
                        powerRow("USB output", value: "Live power unavailable")
                        if let limit = current.usbPower.outputLimitWatts {
                            powerRow("Negotiated limit", value: String(format: "Up to %.1f W", limit))
                        }
                    }
                    if !fresh {
                        Text("No recent battery data").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .accessibilityIdentifier("dashboard-battery-power")
        .accessibilityHint("Opens battery details")
    }

    private func metric(_ title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func powerRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }
}

struct BatteryDetailSheet: View {
    let battery: BatteryStatus
    let updatedAt: Date?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 2)) { context in
                let fresh = updatedAt.map { context.date.timeIntervalSince($0) < 10 } ?? false
                List {
                    if !fresh { Text("No recent battery data").foregroundStyle(.secondary) }
                    if fresh {
                        row("Capacity", icon: batteryIcon(battery.capacity), value: battery.capacityText)
                        row("Estimated remaining", icon: "battery.75", value: battery.remainingChargeText)
                        if let full = battery.fullChargeMAH, full.isFinite, full > 0 {
                            numericRow("Full charge capacity", icon: "battery.100", value: full, decimals: 0, unit: " mAh")
                        }
                        row("Status", icon: "bolt.fill", value: battery.statusText)
                        if let mv = battery.voltageMV {
                            numericRow("Voltage", icon: "bolt.circle", value: Double(mv) / 1000, decimals: 3, unit: " V")
                        }
                        if let ma = battery.currentMA {
                            numericRow("Current", icon: "arrow.left.arrow.right", value: Double(ma), decimals: 0, unit: " mA")
                        }
                        if let watts = battery.powerWatts {
                            numericRow(watts > 0.05 ? "Battery charging" : "Battery draw", icon: "flame", value: abs(watts), decimals: 1, unit: " W")
                        }
                        HStack {
                            Label("Temperature", systemImage: "thermometer.medium")
                            Spacer()
                            TemperatureValueText(value: battery.temperature).foregroundStyle(.secondary)
                        }
                        row("Time to Full", icon: "battery.100.bolt", value: battery.charging == "charging" && battery.timeToFull > 0 ? formatETA(battery.timeToFull) : "—")
                        row("Estimated runtime", icon: "clock", value: battery.usbPower.externalPower == true ? "External power" : battery.runtimeText)
                        if let input = battery.usbPower.inputWatts {
                            numericRow("USB input", icon: "arrow.down", value: input, decimals: 1, unit: " W")
                        }
                        if battery.usbPower.role == "source" {
                            row("USB output", icon: "arrow.up", value: "Live power unavailable")
                            if let limit = battery.usbPower.outputLimitWatts {
                                numericRow("Negotiated output limit", icon: "bolt", value: limit, decimals: 1, unit: " W")
                            }
                            Text("The router reports its USB power contract, but not the actual output current.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Remaining charge uses the fuel gauge percentage and full charge capacity. Runtime uses recent average battery current and changes with network load and USB charging.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Battery draw includes the router, conversion losses and connected USB devices. USB input includes battery charging.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .navigationTitle("Battery Details")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func numericRow(_ label: String, icon: String, value: Double, decimals: Int, unit: String) -> some View {
        HStack {
            Label(label, systemImage: icon)
            Spacer()
            AnimatedNumber(value: value, decimalPlaces: decimals, font: .body,
                textColor: .secondary, animationDuration: reduceMotion ? 0 : 0.3, suffix: unit)
        }
    }

    private func row(_ label: String, icon: String, value: String) -> some View {
        HStack {
            Label(label, systemImage: icon)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func formatETA(_ minutes: Int) -> String {
        if minutes >= 1440 {
            let d = minutes / 1440, h = (minutes % 1440) / 60, m = minutes % 60
            return "\(d)d \(h)h \(m)m"
        }
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    private func batteryIcon(_ percent: Int) -> String {
        guard (0...100).contains(percent) else { return "battery.0" }
        if percent >= 75 { return "battery.100" }
        if percent >= 50 { return "battery.75" }
        if percent >= 25 { return "battery.50" }
        return "battery.25"
    }
}
