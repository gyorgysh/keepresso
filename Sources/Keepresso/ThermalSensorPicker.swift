import SwiftUI
import KeepressoCore

/// The fan boost strength: a fan glyph, a 30-100% slider in 5% steps, and a
/// readout. Committed only on drag end: every config write resets the guard's
/// dwell state (and mid-emergency would release the boost), so the knob must
/// not write through while it moves.
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
