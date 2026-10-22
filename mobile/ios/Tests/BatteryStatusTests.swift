import Foundation

// Compile with Core/Models/DeviceModels.swift and Core/Models/RouterSettingsModels.swift.
@main
struct BatteryStatusTests {
    static func main() {
        var battery = DeviceParser.parseBattery([
            "battery_capacity": 100, "battery_temperature": 41,
            "battery_time_to_full": 0, "battery_time_to_empty": 1166
        ])
        precondition(battery.capacityText == "100%")

        var powered = DeviceParser.parseKernelBattery(["capacity": 100, "status": "Charging", "current_ua": 552625, "voltage_uv": 4512691])
        DeviceParser.parseCharger(["charger_connect": 1, "charge_status": 4, "direct_power_supply_mode": "disable"], into: &powered)
        precondition(powered.charging == "charging", "Charger code 4 must not overwrite the fuel gauge's charging state")
        powered = DeviceParser.parseKernelBattery(["capacity": 100, "status": "Full"])
        DeviceParser.parseCharger(["charger_connect": 1, "charge_status": 4], into: &powered)
        precondition(powered.statusText == "Full")
        var unknown = BatteryStatus.empty
        DeviceParser.parseCharger([:], into: &unknown)
        precondition(unknown.charging.isEmpty, "Missing charger telemetry is not proof of discharge")
        DeviceParser.parseCharger(["charger_connect": 0, "charge_status": 0], into: &unknown)
        precondition(unknown.charging == "discharging")
        DeviceParser.parseCharger([
            "charger_connect": 1, "charge_status": 4
        ], into: &battery, chargeControl: ["charging_stopped": true])
        precondition(battery.charging == "stopped")
        precondition(battery.capacityText == "100%")

        // The complete percentage stays correct across both sides of a digit-width change.
        for capacity in [99, 100, 99, 9, 10, 0, 100] {
            battery.capacity = capacity
            precondition(battery.capacityText == "\(capacity)%")
        }
        for invalid in [-1, 101, 199] {
            battery.capacity = invalid
            precondition(battery.capacityPercent == nil)
            precondition(battery.capacityText == "—")
        }
        precondition(DeviceParser.parseThermal([:]).cpuTemp == nil)
        precondition(DeviceParser.parseBattery([:]).temperature == nil)
        let zones = DeviceParser.parseThermal(["sensors": [
            ["id": "16", "name": "cpuss-0", "temperature_c": 36.8],
            ["id": "17", "name": "cpuss-1", "temperature_c": 38.4],
            ["id": "33", "name": "sys-therm-5", "temperature_c": -40.96],
            ["id": "39", "name": "battery", "temperature_c": 0.0]
        ]])
        precondition(zones.cpuTemp == 38.4)
        precondition(zones.sensors[2].temperatureC == nil)
        precondition(zones.sensors[3].temperatureC == 0, "Zero Celsius is valid")
        precondition(DeviceParser.validTemperature(Double.nan) == nil)
        precondition(DeviceParser.validTemperature(-273) == nil)
        precondition(DeviceParser.parseKernelBattery(["temperature": 315]).temperature == 31.5)
        battery.voltageMV = 4200; battery.currentMA = 1250
        precondition(battery.powerWatts == 5.25 && battery.powerText == "+5.2 W")
        battery.voltageMV = 4000; battery.currentMA = -350
        precondition(battery.powerWatts == -1.4 && battery.powerText == "−1.4 W")
        battery.voltageMV = 4479; battery.currentMA = -3
        precondition(battery.powerText == "0.0 W", "Near-zero drain must not display negative zero")
        battery.currentMA = 0
        precondition(battery.powerWatts == 0 && battery.powerText == "0.0 W")
        battery.currentMA = nil
        precondition(battery.powerWatts == nil && battery.powerText == "— W")
        battery.currentMA = 100; battery.voltageMV = nil
        precondition(battery.powerWatts == nil)
        for invalidVoltage in [0, -1] {
            battery.voltageMV = invalidVoltage
            precondition(battery.powerWatts == nil && battery.powerText == "— W")
        }
        battery = DeviceParser.parseKernelBattery([
            "capacity": 50, "status": "Discharging", "voltage_uv": 4000000,
            "current_ua": -1000000, "charge_full_uah": 10214000, "current_avg_ua": -500000,
            "usb": ["role": "source", "online": true, "output_voltage_mv": 9000, "output_current_limit_ma": 2000]
        ])
        precondition(battery.estimatedRemainingMAH == 5107)
        precondition(battery.powerWatts == -4)
        precondition(battery.estimatedRuntimeMinutes == 612)
        precondition(battery.runtimeText == "≈ 10h 10m")
        precondition(battery.usbPower.outputLimitWatts == 18)
        precondition(battery.usbPower.inputWatts == nil)
        battery.averageCurrentMA = -1000
        precondition(battery.estimatedRuntimeMinutes == 306, "USB load must shorten runtime as measured draw increases")
        battery.charging = "charging"
        precondition(battery.estimatedRuntimeMinutes == nil)
        battery.charging = "stopped"
        precondition(battery.estimatedRuntimeMinutes == nil)
        battery.charging = "discharging"
        for average in [-49.0, 0, 500, Double.nan] {
            battery.averageCurrentMA = average
            precondition(battery.estimatedRuntimeMinutes == nil, "Noise, charging and unavailable current must not create a runtime")
        }
        battery.averageCurrentMA = -500
        battery.currentMA = 100
        precondition(battery.estimatedRuntimeMinutes == nil, "A stale discharge average must not survive a transition to charging")
        battery.currentMA = -1000
        battery.usbPower = USBPowerStatus(role: "sink", online: true, inputVoltageMV: 5000, inputCurrentMA: 356,
                                         outputVoltageMV: 9000, outputCurrentLimitMA: 2000)
        precondition(battery.usbPower.inputWatts == 1.78)
        precondition(battery.usbPower.outputLimitWatts == nil, "The previous output contract must not appear while receiving power")
        precondition(battery.estimatedRuntimeMinutes == nil, "Do not predict battery exhaustion while externally powered")
        battery.usbPower.online = false
        precondition(battery.usbPower.inputWatts == nil)
        precondition(battery.estimatedRuntimeMinutes == 612)
        for fullCharge in [0.0, -1, Double.nan, Double.infinity] {
            battery.fullChargeMAH = fullCharge
            precondition(battery.estimatedRemainingMAH == nil && battery.estimatedRuntimeMinutes == nil)
        }
        battery.fullChargeMAH = 10000
        battery.capacity = 0
        precondition(battery.estimatedRemainingMAH == 0 && battery.runtimeText == "< 5 min")
        battery.capacity = 1
        precondition(battery.runtimeText == "≈ 10m")
        battery.capacity = 101
        precondition(battery.estimatedRemainingMAH == nil && battery.estimatedRuntimeMinutes == nil)
        let legacy = DeviceParser.parseKernelBattery(["capacity": 50, "status": "Discharging", "current_ua": -1000000, "voltage_uv": 4000000])
        precondition(legacy.powerWatts == -4 && legacy.estimatedRuntimeMinutes == nil && legacy.usbPower.inputWatts == nil)
        print("Battery charge estimate, load-dependent runtime, USB direction and negotiated-limit checks passed")
        print("Thermal parsing, hottest CPU selection and invalid sensor checks passed")
        print("Battery percentage, charge-stopped and signed-power regression checks passed")
    }
}
