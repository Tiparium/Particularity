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

    @State private var draftValue: Double
    @State private var draftText: String
    @State private var applyWorkItem: DispatchWorkItem?
    @State private var isPending = false

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
        _draftValue = State(initialValue: appliedValue.wrappedValue)
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
                    get: { draftValue },
                    set: {
                        draftValue = min(max($0, range.lowerBound), range.upperBound)
                        draftText = Self.editingText(for: draftValue)
                        scheduleApply()
                    }
                ),
                in: range,
                step: step
            )

            pendingStatusRow
        }
        .onChange(of: appliedValue) {
            if !isPending {
                draftValue = appliedValue
                draftText = Self.editingText(for: appliedValue)
            }
        }
    }

    @ViewBuilder
    private var pendingStatusRow: some View {
        Group {
            if isPending && draftValue != appliedValue {
                Text("Applying \(valueText(draftValue)) after 1s idle. Active: \(valueText(appliedValue))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Color.clear
            }
        }
        .frame(height: 16, alignment: .leading)
    }

    private func commitTextEntry() {
        guard let parsed = Self.parseNumericText(draftText) else {
            draftText = Self.editingText(for: draftValue)
            return
        }

        let snapped = (parsed / step).rounded() * step
        draftValue = min(max(snapped, range.lowerBound), range.upperBound)
        draftText = Self.editingText(for: draftValue)
        scheduleApply()
    }

    private func scheduleApply() {
        isPending = true
        applyWorkItem?.cancel()

        let workItem = DispatchWorkItem {
            appliedValue = draftValue
            isPending = false
            applyWorkItem = nil
        }
        applyWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
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

    @State private var draftValue: Bool
    @State private var applyWorkItem: DispatchWorkItem?
    @State private var isPending = false

    init(title: String, appliedValue: Binding<Bool>, delay: TimeInterval = 1.0) {
        self.title = title
        _appliedValue = appliedValue
        self.delay = delay
        _draftValue = State(initialValue: appliedValue.wrappedValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: Binding(
                get: { draftValue },
                set: {
                    draftValue = $0
                    scheduleApply()
                }
            ))
            .font(.caption)

            Group {
                if isPending && draftValue != appliedValue {
                    Text("Applying \(draftValue ? "On" : "Off") after 1s idle. Active: \(appliedValue ? "On" : "Off")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Color.clear
                }
            }
            .frame(height: 16, alignment: .leading)
        }
        .onChange(of: appliedValue) {
            if !isPending {
                draftValue = appliedValue
            }
        }
    }

    private func scheduleApply() {
        isPending = true
        applyWorkItem?.cancel()

        let workItem = DispatchWorkItem {
            appliedValue = draftValue
            isPending = false
            applyWorkItem = nil
        }
        applyWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
}

struct EventuallyAppliedIntSlider: View {
    let title: String
    @Binding var appliedValue: Int
    let range: ClosedRange<Int>
    let delay: TimeInterval
    let helpText: String?

    @State private var draftValue: Int
    @State private var draftText: String
    @State private var applyWorkItem: DispatchWorkItem?
    @State private var isPending = false
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
        _draftValue = State(initialValue: appliedValue.wrappedValue)
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
                    get: { Double(draftValue) },
                    set: {
                        draftValue = Int($0.rounded())
                        draftText = "\(draftValue)"
                        scheduleApply()
                    }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: 1
            )
            .help(helpText ?? "")

            Group {
                if isPending && draftValue != appliedValue {
                    Text("Applying \(draftValue.formatted()) after 1s idle. Active: \(appliedValue.formatted())")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Color.clear
                }
            }
            .frame(height: 16, alignment: .leading)
        }
        .onChange(of: appliedValue) {
            if !isPending {
                draftValue = appliedValue
                draftText = "\(appliedValue)"
            }
        }
    }

    private func commitTextEntry() {
        let digitsOnly = draftText.filter(\.isNumber)
        guard let parsed = Int(digitsOnly), parsed >= range.lowerBound else {
            draftText = "\(draftValue)"
            return
        }

        draftValue = min(range.upperBound, parsed)
        draftText = "\(draftValue)"
        scheduleApply()
    }

    private func scheduleApply() {
        isPending = true
        applyWorkItem?.cancel()

        let workItem = DispatchWorkItem {
            appliedValue = draftValue
            isPending = false
            applyWorkItem = nil
        }
        applyWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
}

struct EventuallyAppliedSegmentedPicker<Option: Hashable>: View {
    let title: String
    @Binding var appliedValue: Option
    let options: [Option]
    let delay: TimeInterval
    let optionTitle: (Option) -> String

    @State private var draftValue: Option
    @State private var applyWorkItem: DispatchWorkItem?
    @State private var isPending = false

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
        _draftValue = State(initialValue: appliedValue.wrappedValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)

            Picker(
                title,
                selection: Binding(
                    get: { draftValue },
                    set: {
                        draftValue = $0
                        scheduleApply()
                    }
                )
            ) {
                ForEach(options, id: \.self) { option in
                    Text(optionTitle(option)).tag(option)
                }
            }
            .pickerStyle(.segmented)

            Group {
                if isPending && draftValue != appliedValue {
                    Text("Applying \(optionTitle(draftValue)) after 1s idle. Active: \(optionTitle(appliedValue))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Color.clear
                }
            }
            .frame(height: 16, alignment: .leading)
        }
        .onChange(of: appliedValue) {
            if !isPending {
                draftValue = appliedValue
            }
        }
    }

    private func scheduleApply() {
        isPending = true
        applyWorkItem?.cancel()

        let workItem = DispatchWorkItem {
            appliedValue = draftValue
            isPending = false
            applyWorkItem = nil
        }
        applyWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
}
