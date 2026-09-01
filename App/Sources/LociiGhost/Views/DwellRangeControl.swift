import SwiftUI
import LociiGhostCore

/// The "pause at each stop" control: a toggle plus a min–max pair.
///
/// One view rather than one per panel. Multi-stop and Random Walk both
/// offer this setting, and the v1.15.2 audit's P12 was precisely the
/// cost of two copies of one behaviour: the map's programmatic-fly
/// guard existed in one implementation and not the other, so a fix
/// landed in half the app. A control this small is not worth repeating.
///
/// The bindings are passed in rather than reached out of the
/// environment because Random Walk has to intercept edits while a walk
/// is running (change → stop → apply → restart), and Multi-Stop does
/// not. That difference belongs to the caller.
struct DwellRangeControl: View {
    @Binding var enabled: Bool
    @Binding var minSeconds: Int
    @Binding var maxSeconds: Int

    /// Label above the pair. Both panels say "at each stop", but the
    /// Random Walk one means "at each random target", so the caller
    /// supplies the wording.
    let title: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle(isOn: $enabled) {
                    Text(title).font(.caption)
                }
                .toggleStyle(.switch)
                Spacer(minLength: 6)
                if enabled {
                    Text(summary)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if enabled {
                HStack(spacing: 10) {
                    bound(
                        label: Text("Min", comment: "Dwell range — shortest pause"),
                        value: clampedMin,
                    )
                    bound(
                        label: Text("Max", comment: "Dwell range — longest pause"),
                        value: clampedMax,
                    )
                }
            }
        }
    }

    /// "5–20 s", or just "8 s" when both bounds match — a fixed pause
    /// is still a legitimate setting and shouldn't read as a broken
    /// range.
    private var summary: String {
        minSeconds == maxSeconds ? "\(minSeconds) s" : "\(minSeconds)–\(maxSeconds) s"
    }

    @ViewBuilder
    private func bound(label: Text, value: Binding<Int>) -> some View {
        Stepper(value: value, in: 1...3600, step: 1) {
            HStack(spacing: 4) {
                label
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(verbatim: "\(value.wrappedValue) s")
                    .font(.caption.monospacedDigit())
            }
            .frame(minWidth: 62, alignment: .leading)
        }
    }

    /// Raising the floor above the ceiling (or dropping the ceiling
    /// below the floor) pushes the other bound along instead of
    /// refusing the edit. Silently rejecting a stepper click reads as
    /// a broken control; `DwellRange` would normalise it anyway, but
    /// then the number on screen wouldn't match what runs.
    private var clampedMin: Binding<Int> {
        Binding(
            get: { minSeconds },
            set: { new in
                let v = max(1, new)
                minSeconds = v
                if maxSeconds < v { maxSeconds = v }
            },
        )
    }

    private var clampedMax: Binding<Int> {
        Binding(
            get: { maxSeconds },
            set: { new in
                let v = max(1, new)
                maxSeconds = v
                if minSeconds > v { minSeconds = v }
            },
        )
    }
}
