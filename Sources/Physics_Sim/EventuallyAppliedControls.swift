import SwiftUI

private struct InlineEditableValueLabel: View {
    @Binding var text: String
    let width: CGFloat
    let commit: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: .trailing)
            .focused($isFocused)
            .onSubmit(commit)
            .onChange(of: isFocused) { _, focused in
                if !focused {
                    commit()
                }
            }
    }
}

struct EventuallyAppliedSlider: View {
    let title: String
    @Binding var appliedValue: Double
    let range: ClosedRange<Double>
    let step: Double
    let delay: TimeInterval
    let valueText: (Double) -> String

    @State private var draftText: String

    init(
        title: String,
        appliedValue: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double = 1,
        delay: TimeInterval = 1.0,
        valueText: @escaping (Double) -> String
    ) {
        self.title = title
        _appliedValue = appliedValue
        self.range = range
        self.step = step
        self.delay = delay
        self.valueText = valueText
        _draftText = State(initialValue: Self.editingText(for: appliedValue.wrappedValue))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption)
                Spacer()
                InlineEditableValueLabel(
                    text: $draftText,
                    width: 72,
                    commit: commitTextEntry
                )
            }

            Slider(
                value: Binding(
                    get: { appliedValue },
                    set: {
                        appliedValue = min(max($0, range.lowerBound), range.upperBound)
                        draftText = Self.editingText(for: appliedValue)
                    }
                ),
                in: range,
                step: step
            )

            statusRow(valueText(appliedValue))
        }
        .onChange(of: appliedValue) { _, nextValue in
            draftText = Self.editingText(for: nextValue)
        }
    }

    @ViewBuilder
    private func statusRow(_ text: String) -> some View {
        Text("Active: \(text)")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(height: 16, alignment: .leading)
    }

    private func commitTextEntry() {
        guard let parsed = Self.parseNumericText(draftText) else {
            draftText = Self.editingText(for: appliedValue)
            return
        }

        let snapped = (parsed / step).rounded() * step
        appliedValue = min(max(snapped, range.lowerBound), range.upperBound)
        draftText = Self.editingText(for: appliedValue)
    }

    private static func editingText(for value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(value)
    }

    private static func parseNumericText(_ text: String) -> Double? {
        let filtered = text
            .replacingOccurrences(of: ",", with: "")
            .filter { $0.isNumber || $0 == "." || $0 == "-" }
        guard !filtered.isEmpty else { return nil }
        return Double(filtered)
    }
}

struct EventuallyAppliedToggle: View {
    let title: String
    @Binding var appliedValue: Bool
    let delay: TimeInterval

    init(title: String, appliedValue: Binding<Bool>, delay: TimeInterval = 1.0) {
        self.title = title
        _appliedValue = appliedValue
        self.delay = delay
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: $appliedValue)
                .font(.caption)

            Text("Active: \(appliedValue ? "On" : "Off")")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(height: 16, alignment: .leading)
        }
    }
}

struct EventuallyAppliedIntSlider: View {
    let title: String
    @Binding var appliedValue: Int
    let range: ClosedRange<Int>
    let delay: TimeInterval
    let helpText: String?

    @State private var draftText: String

    init(
        title: String,
        appliedValue: Binding<Int>,
        range: ClosedRange<Int>,
        delay: TimeInterval = 1.0,
        helpText: String? = nil
    ) {
        self.title = title
        _appliedValue = appliedValue
        self.range = range
        self.delay = delay
        self.helpText = helpText
        _draftText = State(initialValue: "\(appliedValue.wrappedValue)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption)
                Spacer()
                InlineEditableValueLabel(
                    text: $draftText,
                    width: 86,
                    commit: commitTextEntry
                )
            }

            Slider(
                value: Binding(
                    get: { Double(appliedValue) },
                    set: {
                        appliedValue = Int($0.rounded())
                        draftText = "\(appliedValue)"
                    }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: 1
            )
            .help(helpText ?? "")

            Text("Active: \(appliedValue.formatted())")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(height: 16, alignment: .leading)
        }
        .onChange(of: appliedValue) { _, nextValue in
            draftText = "\(nextValue)"
        }
    }

    private func commitTextEntry() {
        let digitsOnly = draftText.filter(\.isNumber)
        guard let parsed = Int(digitsOnly), parsed >= range.lowerBound else {
            draftText = "\(appliedValue)"
            return
        }

        appliedValue = min(range.upperBound, parsed)
        draftText = "\(appliedValue)"
    }
}

struct EventuallyAppliedSegmentedPicker<Option: Hashable>: View {
    let title: String
    @Binding var appliedValue: Option
    let options: [Option]
    let delay: TimeInterval
    let optionTitle: (Option) -> String

    init(
        title: String,
        appliedValue: Binding<Option>,
        options: [Option],
        delay: TimeInterval = 1.0,
        optionTitle: @escaping (Option) -> String
    ) {
        self.title = title
        _appliedValue = appliedValue
        self.options = options
        self.delay = delay
        self.optionTitle = optionTitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)

            Picker(title, selection: $appliedValue) {
                ForEach(options, id: \.self) { option in
                    Text(optionTitle(option)).tag(option)
                }
            }
            .pickerStyle(.segmented)

            Text("Active: \(optionTitle(appliedValue))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(height: 16, alignment: .leading)
        }
    }
}
