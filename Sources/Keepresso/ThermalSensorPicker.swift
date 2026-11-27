import SwiftUI
import KeepressoCore

struct TemperatureThresholdSlider: View {
    @Binding var celsius: Double

    @State private var dragValue: Double?

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

struct FanBoostSlider: View {
    @Binding var percent: Int
    var percentRange: ClosedRange<Int> = ThermalSafetyConfig.boostPercentRange

    @State private var dragValue: Double?

    private var range: ClosedRange<Double> { Double(percentRange.lowerBound)...Double(percentRange.upperBound) }

    private var clamped: Double {
        min(max(Double(percent), range.lowerBound), range.upperBound)
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
                in: range,
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

struct ThermalSensorPicker: View {
    let model: AppModel
    @Binding var selectedIDs: [String]

    @State private var sensors: [ThermalSensor] = []
    @State private var readings: [String: Double] = [:]

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
        .onDisappear {
            sensors = []
            readings = [:]
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            refresh()
        }
    }

    private func refresh() {
        guard !sensors.isEmpty else { return }
        readings = model.thermalGuard.liveReadings(ids: sensors.map(\.id))
    }
}
