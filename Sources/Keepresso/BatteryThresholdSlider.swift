import SwiftUI
import KeepressoCore

struct BatteryThresholdSlider: View {
    @Binding var percent: Int

    @State private var dragValue: Double?

    private static let range = Double(KeepressoSettings.batteryPausePercentRange.lowerBound)
        ... Double(KeepressoSettings.batteryPausePercentRange.upperBound)

    private var clamped: Double {
        Double(percent).clamped(to: Self.range)
    }

    private var shown: Int { Int(dragValue ?? clamped) }

    private var glyph: String {
        switch shown {
        case ...30: "battery.25"
        case ...55: "battery.50"
        case ...80: "battery.75"
        default: "battery.100"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: glyph)
                .foregroundStyle(.secondary)
                .contentTransition(.symbolEffect(.replace))
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
                Text("Battery threshold")
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

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
