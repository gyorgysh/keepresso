import SwiftUI
import KeepressoCore

/// The "pause above this temperature" control: a thermometer glyph, a slider
/// over the clamped °C range in 1° steps, and a readout. Committed only when
/// the drag ends, for the same reason as ``BatteryThresholdSlider``: writing
/// through mid-drag would let the live guard latch a pause while the knob
/// merely passes the current die temperature.
struct TemperatureThresholdSlider: View {
    @Binding var celsius: Double

    @State private var dragValue: Double?

    /// Mirrors the range Core clamps the config to.
    private static let range = ThermalSafetyConfig.celsiusRange

    private var clamped: Double {
        min(max(celsius, Self.range.lowerBound), Self.range.upperBound)
    }

    private var shown: Int { Int(dragValue ?? clamped) }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "thermometer.medium")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Slider(
                value: Binding(
                    get: { dragValue ?? clamped },
                    set: { newValue in
                        if dragValue != nil {
                            dragValue = newValue
                        } else {
                            celsius = newValue
                        }
                    }
                ),
                in: Self.range,
                step: 1
            ) {
                Text("Temperature threshold")
            } onEditingChanged: { editing in
                if editing {
                    dragValue = clamped
                } else {
                    if let value = dragValue { celsius = value }
                    dragValue = nil
                }
            }
            .labelsHidden()
            .accessibilityValue(Text(verbatim: "\(shown) °C"))
            Text(verbatim: "\(shown) °C")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .trailing)
        }
    }
}

/// The fan boost strength: a fan glyph, a 30-100% slider in 5% steps, and a
/// readout. Committed only on drag end: every config write resets the guard's
/// dwell state (and mid-emergency would release the boost), so the knob must
/// not write through while it moves.
struct FanBoostSlider: View {
    @Binding var percent: Int

    @State private var dragValue: Double?

    private static let range = Double(ThermalSafetyConfig.boostPercentRange.lowerBound)
        ... Double(ThermalSafetyConfig.boostPercentRange.upperBound)

    private var clamped: Double {
        min(max(Double(percent), Self.range.lowerBound), Self.range.upperBound)
    }

    private var shown: Int { Int(dragValue ?? clamped) }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "fanblades")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Slider(
                value: Binding(
                    get: { dragValue ?? clamped },
                    set: { newValue in
                        if dragValue != nil {
                            dragValue = newValue
                        } else {
                            percent = Int(newValue)
                        }
                    }
                ),
                in: Self.range,
                step: 5
            ) {
                Text("Fan boost")
            } onEditingChanged: { editing in
                if editing {
                    dragValue = clamped
                } else {
                    if let value = dragValue { percent = Int(value) }
                    dragValue = nil
                }
            }
            .labelsHidden()
            .accessibilityValue(Text(verbatim: "\(shown)%"))
            Text(verbatim: "\(shown)%")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 38, alignment: .trailing)
        }
    }
}

/// A checklist of this machine's temperature sensors with a live °C column,
/// bound to the selected sensor ids of the thermal safety config. Readings
/// refresh once a second while visible (through the backend's TTL cache, so
/// the guard's own tick shares the same probe).
struct ThermalSensorPicker: View {
    let model: AppModel
    @Binding var selectedIDs: [String]

    @State private var sensors: [ThermalSensor] = []
    @State private var readings: [String: Double] = [:]
    @State private var windowVisible = true
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if sensors.isEmpty {
                Text("No temperature sensors found on this Mac. The thermal pressure signal above still works.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(sensors) { sensor in
                    HStack(spacing: 8) {
                        Toggle(sensor.name, isOn: Binding(
                            get: { selectedIDs.contains(sensor.id) },
                            set: { include in
                                if include {
                                    if !selectedIDs.contains(sensor.id) { selectedIDs.append(sensor.id) }
                                } else {
                                    selectedIDs.removeAll { $0 == sensor.id }
                                }
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(readings[sensor.id].map { String(format: "%.0f °C", $0) } ?? "–")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                // A persisted sensor that no longer resolves stays selected
                // (never silently substituted) but is flagged: unreadable
                // sensors feed the guard no verdict, which holds, not cools.
                if selectedIDs.contains(where: { id in !sensors.contains { $0.id == id } }) {
                    Label("Some selected sensors are unavailable on this Mac.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .onAppear {
            sensors = model.thermalGuard.discoverSensors()
            refresh()
        }
        // The closed window keeps this content alive (see WindowVisibilityReader),
        // so the sensor poll would keep reading the SMC unseen. Pause it while
        // hidden and refresh on reopen.
        .background(WindowVisibilityReader(isVisible: $windowVisible))
        .onChange(of: windowVisible) { _, visible in
            if visible { refresh() }
        }
        .onReceive(tick) { _ in
            guard windowVisible else { return }
            refresh()
        }
    }

    private func refresh() {
        guard !sensors.isEmpty else { return }
        readings = model.thermalGuard.liveReadings(ids: sensors.map(\.id))
    }
}
