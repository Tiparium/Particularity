import AppKit
import SwiftUI

enum AppControlPalette {
    static let accent = Color(red: 0.64, green: 0.39, blue: 0.135)
    static let idleBackground = Color(nsColor: .quaternaryLabelColor).opacity(0.16)
    static let hoverBackground = accent.opacity(0.18)
    static let pressedBackground = accent.opacity(0.28)
    static let stroke = Color(nsColor: .separatorColor).opacity(0.45)
    static let destructiveIdleBackground = Color.red.opacity(0.14)
    static let destructiveHoverBackground = Color.red.opacity(0.30)
    static let destructivePressedBackground = Color.red.opacity(0.40)
}

enum AppButtonVariant {
    case standard
    case prominent
    case destructive
}

enum AppControlVariant {
    case neutral
    case accent
    case active
    case destructive
}

enum AppSliderTickBehavior {
    case hidden
    case visible
}

private struct RuntimeValidationReportEnvironmentKey: EnvironmentKey {
    static let defaultValue = RuntimeValidationReport(issues: [], projectedBytes: 0)
}

private struct HighlightedValidationFieldEnvironmentKey: EnvironmentKey {
    static let defaultValue: RuntimeValidationField? = nil
}

extension EnvironmentValues {
    var runtimeValidationReport: RuntimeValidationReport {
        get { self[RuntimeValidationReportEnvironmentKey.self] }
        set { self[RuntimeValidationReportEnvironmentKey.self] = newValue }
    }

    var highlightedValidationField: RuntimeValidationField? {
        get { self[HighlightedValidationFieldEnvironmentKey.self] }
        set { self[HighlightedValidationFieldEnvironmentKey.self] = newValue }
    }
}

struct ValidationControlDecoration: ViewModifier {
    let issue: RuntimeValidationIssue?
    let isHighlighted: Bool

    func body(content: Content) -> some View {
        content
            .padding(issue == nil ? 0 : 6)
            .background {
                if issue != nil {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.red.opacity(isHighlighted ? 0.22 : 0.10))
                }
            }
            .overlay {
                if issue != nil {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.red.opacity(0.95), lineWidth: isHighlighted ? 2.5 : 1.5)
                }
            }
    }
}

extension View {
    func validationDecoration(issue: RuntimeValidationIssue?, isHighlighted: Bool) -> some View {
        modifier(ValidationControlDecoration(issue: issue, isHighlighted: isHighlighted))
    }
}

struct AppSwitchSurface: View {
    let isOn: Bool
    let isHovered: Bool
    let isPressed: Bool
    let isDimmed: Bool

    init(isOn: Bool, isHovered: Bool, isPressed: Bool, isDimmed: Bool = false) {
        self.isOn = isOn
        self.isHovered = isHovered
        self.isPressed = isPressed
        self.isDimmed = isDimmed
    }

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(trackBackgroundColor)
            Capsule()
                .stroke(trackBorderColor, lineWidth: 1)

            Circle()
                .fill(knobColor)
                .frame(width: 16, height: 16)
                .padding(3)
                .shadow(color: Color.black.opacity(isOn ? 0.18 : 0.10), radius: 3, y: 1)
        }
        .frame(width: 40, height: 22)
        .opacity(isDimmed ? 0.55 : 1.0)
        .animation(.easeOut(duration: 0.14), value: isOn)
        .animation(.easeOut(duration: 0.12), value: isPressed)
    }

    private var trackBackgroundColor: Color {
        if isOn {
            if isPressed {
                return AppControlPalette.accent
            }
            return AppControlPalette.accent
        }
        if isPressed {
            return AppControlPalette.pressedBackground
        }
        if isHovered {
            return AppControlPalette.hoverBackground
        }
        return AppControlPalette.idleBackground
    }

    private var trackBorderColor: Color {
        if isOn || isHovered || isPressed {
            return AppControlPalette.accent.opacity(0.60)
        }
        return AppControlPalette.stroke
    }

    private var knobColor: Color {
        if isOn {
            return (isHovered || isPressed) ? .primary : Color.white.opacity(0.96)
        }
        return (isHovered || isPressed) ? Color.primary.opacity(0.92) : Color.secondary.opacity(0.88)
    }
}

struct AppIconControlSurface: View {
    let iconName: String
    let variant: AppControlVariant
    let isHovered: Bool
    let isPressed: Bool
    let isDimmed: Bool

    init(
        iconName: String,
        variant: AppControlVariant,
        isHovered: Bool,
        isPressed: Bool,
        isDimmed: Bool = false
    ) {
        self.iconName = iconName
        self.variant = variant
        self.isHovered = isHovered
        self.isPressed = isPressed
        self.isDimmed = isDimmed
    }

    var body: some View {
        Image(systemName: iconName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(foregroundColor)
            .frame(width: 36, height: 32)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(borderColor, lineWidth: 1)
            )
            .opacity(isDimmed ? 0.55 : 1.0)
    }

    private var foregroundColor: Color {
        switch variant {
        case .neutral, .accent:
            return (isHovered || isPressed) ? .primary : .secondary
        case .active:
            return isDimmed ? .secondary : Color.white.opacity(0.98)
        case .destructive:
            return (isHovered || isPressed) ? Color.red.opacity(0.95) : .secondary
        }
    }

    private var backgroundColor: Color {
        switch variant {
        case .neutral, .accent:
            return isPressed ? AppControlPalette.pressedBackground : (isHovered ? AppControlPalette.hoverBackground : AppControlPalette.idleBackground)
        case .active:
            if isDimmed {
                return AppControlPalette.idleBackground
            }
            if isPressed {
                return AppControlPalette.accent.opacity(0.92)
            }
            if isHovered {
                return AppControlPalette.accent.opacity(0.82)
            }
            return AppControlPalette.accent
        case .destructive:
            return isPressed ? AppControlPalette.destructivePressedBackground : (isHovered ? AppControlPalette.destructiveHoverBackground : AppControlPalette.idleBackground)
        }
    }

    private var borderColor: Color {
        switch variant {
        case .neutral, .accent:
            return (isHovered || isPressed) ? AppControlPalette.accent.opacity(0.55) : AppControlPalette.stroke
        case .active:
            return isDimmed ? AppControlPalette.stroke : AppControlPalette.accent.opacity(0.95)
        case .destructive:
            return (isHovered || isPressed) ? Color.red.opacity(0.75) : Color.red.opacity(0.55)
        }
    }
}

struct AppInteractiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .brightness(configuration.isPressed ? -0.02 : 0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct PressEventsModifier: ViewModifier {
    let onPress: () -> Void
    let onRelease: () -> Void

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    onPress()
                }
                .onEnded { _ in
                    onRelease()
                }
        )
    }
}

private extension View {
    func pressEvents(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) -> some View {
        modifier(PressEventsModifier(onPress: onPress, onRelease: onRelease))
    }
}

struct AppIconButton: View {
    let iconName: String
    let helpText: String
    let variant: AppControlVariant
    let isDimmed: Bool
    let action: () -> Void

    @State private var isHovered = false

    init(
        iconName: String,
        helpText: String,
        variant: AppControlVariant = .neutral,
        isDimmed: Bool = false,
        action: @escaping () -> Void
    ) {
        self.iconName = iconName
        self.helpText = helpText
        self.variant = variant
        self.isDimmed = isDimmed
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            AppIconControlSurface(
                iconName: iconName,
                variant: variant,
                isHovered: isHovered,
                isPressed: false,
                isDimmed: isDimmed
            )
        }
        .buttonStyle(AppInteractiveButtonStyle())
        .help(helpText)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

struct AppMenuIconLabel: View {
    let iconName: String
    let variant: AppControlVariant

    @State private var isHovered = false

    init(iconName: String, variant: AppControlVariant = .neutral) {
        self.iconName = iconName
        self.variant = variant
    }

    var body: some View {
        AppIconControlSurface(
            iconName: iconName,
            variant: variant,
            isHovered: isHovered,
            isPressed: false
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

struct AppCheckboxToggle: View {
    let title: String?
    @Binding var isOn: Bool
    let helpText: String?

    init(_ title: String? = nil, isOn: Binding<Bool>, helpText: String? = nil) {
        self.title = title
        self._isOn = isOn
        self.helpText = helpText
    }

    var body: some View {
        AppSwitchToggleBody(title: title, isOn: $isOn, helpText: helpText)
    }
}

private struct AppSwitchToggleBody: View {
    let title: String?
    @Binding var isOn: Bool
    let helpText: String?

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                if let title, !title.isEmpty {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle((isEnabled && (isHovered || isPressed || isOn)) ? .primary : .secondary)
                }

                AppSwitchSurface(
                    isOn: isOn,
                    isHovered: isHovered,
                    isPressed: isPressed,
                    isDimmed: !isEnabled
                )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1.0 : 0.5)
        .help(helpText ?? "")
        .onHover { hovering in
            guard isEnabled else {
                isHovered = false
                return
            }
            isHovered = hovering
        }
        .pressEvents(onPress: {
            guard isEnabled else { return }
            isPressed = true
        }, onRelease: {
            isPressed = false
        })
    }
}

struct AppSwitchToggle: View {
    let title: String?
    @Binding var isOn: Bool
    let helpText: String?

    init(_ title: String? = nil, isOn: Binding<Bool>, helpText: String? = nil) {
        self.title = title
        self._isOn = isOn
        self.helpText = helpText
    }

    var body: some View {
        AppSwitchToggleBody(title: title, isOn: $isOn, helpText: helpText)
    }
}

private struct AppFramedButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let variant: AppButtonVariant

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(borderColor, lineWidth: 1)
            )
            .opacity(isEnabled ? 1.0 : 0.5)
            .scaleEffect(configuration.isPressed && isEnabled ? 0.98 : 1.0)
            .brightness(configuration.isPressed && isEnabled ? -0.02 : 0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .onHover { hovering in
                isHovered = hovering
            }
    }

    private var horizontalPadding: CGFloat {
        switch variant {
        case .standard, .destructive:
            return 10
        case .prominent:
            return 12
        }
    }

    private var verticalPadding: CGFloat {
        switch variant {
        case .standard, .destructive:
            return 6
        case .prominent:
            return 7
        }
    }

    private var foregroundColor: Color {
        switch variant {
        case .standard, .prominent:
            if !isEnabled {
                return .secondary
            }
            return (isHovered || configuration.isPressed) ? .primary : Color.primary.opacity(0.82)
        case .destructive:
            if !isEnabled {
                return .secondary
            }
            return (isHovered || configuration.isPressed) ? Color.red.opacity(0.95) : Color.primary.opacity(0.82)
        }
    }

    private var backgroundColor: Color {
        switch variant {
        case .standard, .prominent:
            if !isEnabled {
                return AppControlPalette.idleBackground
            }
            if configuration.isPressed {
                return AppControlPalette.pressedBackground
            }
            if isHovered {
                return AppControlPalette.hoverBackground
            }
            return AppControlPalette.idleBackground.opacity(1.15)
        case .destructive:
            if !isEnabled {
                return AppControlPalette.idleBackground
            }
            if configuration.isPressed {
                return AppControlPalette.destructivePressedBackground
            }
            if isHovered {
                return AppControlPalette.destructiveHoverBackground
            }
            return AppControlPalette.destructiveIdleBackground
        }
    }

    private var borderColor: Color {
        switch variant {
        case .standard, .prominent:
            if !isEnabled {
                return AppControlPalette.stroke.opacity(0.8)
            }
            return (isHovered || configuration.isPressed) ? AppControlPalette.accent.opacity(0.55) : AppControlPalette.stroke.opacity(1.15)
        case .destructive:
            if !isEnabled {
                return AppControlPalette.stroke.opacity(0.8)
            }
            return (isHovered || configuration.isPressed) ? Color.red.opacity(0.75) : Color.red.opacity(0.55)
        }
    }
}

struct AppFramedButtonStyle: ButtonStyle {
    let variant: AppButtonVariant

    init(_ variant: AppButtonVariant = .standard) {
        self.variant = variant
    }

    func makeBody(configuration: Configuration) -> some View {
        AppFramedButtonBody(configuration: configuration, variant: variant)
    }
}

private struct SectionBracketMarker: View {
    var body: some View {
        GeometryReader { proxy in
            let height = max(0, proxy.size.height - 12)
            VStack(spacing: 0) {
                Capsule()
                    .fill(Color.secondary.opacity(0.55))
                    .frame(width: 14, height: 2)

                Rectangle()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 2, height: height)

                Capsule()
                    .fill(Color.secondary.opacity(0.55))
                    .frame(width: 14, height: 2)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 14)
        .allowsHitTesting(false)
    }
}

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

private struct AppSliderControl: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let tickBehavior: AppSliderTickBehavior
    let helpText: String?
    let onEditingEnded: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound, target: context.coordinator, action: #selector(Coordinator.valueChanged(_:)))
        slider.controlSize = .small
        slider.isContinuous = true
        slider.sendAction(on: [.leftMouseDragged, .leftMouseUp])
        configure(slider)
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.parent = self
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.doubleValue = clampedAndSnapped(value)
        slider.toolTip = helpText
        configure(slider)
    }

    private func configure(_ slider: NSSlider) {
        if let tickMarkCount {
            slider.numberOfTickMarks = tickMarkCount
            slider.tickMarkPosition = .below
            slider.allowsTickMarkValuesOnly = true
        } else {
            slider.numberOfTickMarks = 0
            slider.allowsTickMarkValuesOnly = false
        }
        slider.toolTip = helpText
    }

    private var tickMarkCount: Int? {
        guard tickBehavior == .visible else { return nil }
        let stepCount = Int(((range.upperBound - range.lowerBound) / step).rounded())
        return max(2, stepCount + 1)
    }

    private func clampedAndSnapped(_ proposedValue: Double) -> Double {
        let clamped = min(max(proposedValue, range.lowerBound), range.upperBound)
        let snapped = ((clamped - range.lowerBound) / step).rounded() * step + range.lowerBound
        return min(max(snapped, range.lowerBound), range.upperBound)
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: AppSliderControl

        init(_ parent: AppSliderControl) {
            self.parent = parent
        }

        @objc func valueChanged(_ sender: NSSlider) {
            let nextValue = parent.clampedAndSnapped(sender.doubleValue)
            if abs(sender.doubleValue - nextValue) > 0.000_001 {
                sender.doubleValue = nextValue
            }
            parent.value = nextValue

            if let eventType = NSApp.currentEvent?.type, eventType == .leftMouseUp {
                parent.onEditingEnded()
            }
        }
    }
}

struct EventuallyAppliedSlider: View {
    let title: String
    let field: RuntimeValidationField?
    @Binding var appliedValue: Double
    let range: ClosedRange<Double>
    let textEntryRange: ClosedRange<Double>
    let step: Double
    let tickBehavior: AppSliderTickBehavior
    let delay: TimeInterval
    let valueText: (Double) -> String

    @Environment(\.runtimeValidationReport) private var validationReport
    @Environment(\.highlightedValidationField) private var highlightedValidationField
    @State private var draftText: String
    @State private var draftValue: Double
    @State private var deferredCommit = DeferredActionHandler()

    init(
        title: String,
        field: RuntimeValidationField? = nil,
        appliedValue: Binding<Double>,
        range: ClosedRange<Double>,
        textEntryRange: ClosedRange<Double>? = nil,
        step: Double = 1,
        tickBehavior: AppSliderTickBehavior = .hidden,
        delay: TimeInterval = 1.0,
        valueText: @escaping (Double) -> String
    ) {
        self.title = title
        self.field = field
        _appliedValue = appliedValue
        self.range = range
        self.textEntryRange = textEntryRange ?? range
        self.step = step
        self.tickBehavior = tickBehavior
        self.delay = delay
        self.valueText = valueText
        _draftText = State(initialValue: Self.editingText(for: appliedValue.wrappedValue))
        _draftValue = State(initialValue: appliedValue.wrappedValue)
    }

    var body: some View {
        let issue = validationIssue
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(issue == nil ? Color.primary : Color.red.opacity(0.95))
                Spacer()
                InlineEditableValueLabel(
                    text: $draftText,
                    width: 72,
                    commit: commitTextEntry
                )
            }

            AppSliderControl(
                value: Binding(
                    get: { min(max(draftValue, range.lowerBound), range.upperBound) },
                    set: { nextValue in
                        draftValue = min(max(nextValue, range.lowerBound), range.upperBound)
                        draftText = Self.editingText(for: draftValue)
                        scheduleCommit()
                    }
                ),
                range: range,
                step: step,
                tickBehavior: tickBehavior,
                helpText: nil,
                onEditingEnded: flushCommit
            )

            if let issue {
                Text(issue.message)
                    .font(.caption2)
                    .foregroundStyle(Color.red.opacity(0.95))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .validationDecoration(issue: issue, isHighlighted: field != nil && highlightedValidationField == field)
        .onChange(of: appliedValue) { _, nextValue in
            draftValue = nextValue
            draftText = Self.editingText(for: nextValue)
        }
    }

    private var validationIssue: RuntimeValidationIssue? {
        guard let field else { return nil }
        return validationReport.issue(for: field)
    }

    private func commitTextEntry() {
        guard let parsed = Self.parseNumericText(draftText) else {
            draftText = Self.editingText(for: appliedValue)
            return
        }

        let snapped = (parsed / step).rounded() * step
        draftValue = min(max(snapped, textEntryRange.lowerBound), textEntryRange.upperBound)
        deferredCommit.cancel()
        appliedValue = draftValue
        draftText = Self.editingText(for: draftValue)
    }

    private func scheduleCommit() {
        deferredCommit.schedule(after: delay) {
            appliedValue = draftValue
        }
    }

    private func flushCommit() {
        deferredCommit.flush {
            appliedValue = draftValue
        }
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
    let field: RuntimeValidationField?
    @Binding var appliedValue: Bool
    let delay: TimeInterval
    @Environment(\.runtimeValidationReport) private var validationReport
    @Environment(\.highlightedValidationField) private var highlightedValidationField

    init(title: String, field: RuntimeValidationField? = nil, appliedValue: Binding<Bool>, delay: TimeInterval = 1.0) {
        self.title = title
        self.field = field
        _appliedValue = appliedValue
        self.delay = delay
    }

    var body: some View {
        let issue = validationIssue
        VStack(alignment: .leading, spacing: 4) {
            AppCheckboxToggle(title, isOn: $appliedValue)
            if let issue {
                Text(issue.message)
                    .font(.caption2)
                    .foregroundStyle(Color.red.opacity(0.95))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .validationDecoration(issue: issue, isHighlighted: field != nil && highlightedValidationField == field)
    }

    private var validationIssue: RuntimeValidationIssue? {
        guard let field else { return nil }
        return validationReport.issue(for: field)
    }
}

struct EventuallyAppliedIntSlider: View {
    let title: String
    let field: RuntimeValidationField?
    @Binding var appliedValue: Int
    let range: ClosedRange<Int>
    let textEntryRange: ClosedRange<Int>
    let tickBehavior: AppSliderTickBehavior
    let delay: TimeInterval
    let helpText: String?

    @Environment(\.runtimeValidationReport) private var validationReport
    @Environment(\.highlightedValidationField) private var highlightedValidationField
    @State private var draftText: String
    @State private var draftValue: Int
    @State private var deferredCommit = DeferredActionHandler()

    init(
        title: String,
        field: RuntimeValidationField? = nil,
        appliedValue: Binding<Int>,
        range: ClosedRange<Int>,
        textEntryRange: ClosedRange<Int>? = nil,
        tickBehavior: AppSliderTickBehavior = .hidden,
        delay: TimeInterval = 1.0,
        helpText: String? = nil
    ) {
        self.title = title
        self.field = field
        _appliedValue = appliedValue
        self.range = range
        self.textEntryRange = textEntryRange ?? range
        self.tickBehavior = tickBehavior
        self.delay = delay
        self.helpText = helpText
        _draftText = State(initialValue: "\(appliedValue.wrappedValue)")
        _draftValue = State(initialValue: appliedValue.wrappedValue)
    }

    var body: some View {
        let issue = validationIssue
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(issue == nil ? Color.primary : Color.red.opacity(0.95))
                Spacer()
                InlineEditableValueLabel(
                    text: $draftText,
                    width: 86,
                    commit: commitTextEntry
                )
            }

            AppSliderControl(
                value: Binding(
                    get: { Double(min(max(draftValue, range.lowerBound), range.upperBound)) },
                    set: { nextValue in
                        draftValue = Int(nextValue.rounded())
                        draftText = "\(draftValue)"
                        scheduleCommit()
                    }
                ),
                range: Double(range.lowerBound)...Double(range.upperBound),
                step: 1,
                tickBehavior: tickBehavior,
                helpText: helpText,
                onEditingEnded: flushCommit
            )

            if let issue {
                Text(issue.message)
                    .font(.caption2)
                    .foregroundStyle(Color.red.opacity(0.95))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .validationDecoration(issue: issue, isHighlighted: field != nil && highlightedValidationField == field)
        .onChange(of: appliedValue) { _, nextValue in
            draftValue = nextValue
            draftText = "\(nextValue)"
        }
    }

    private var validationIssue: RuntimeValidationIssue? {
        guard let field else { return nil }
        return validationReport.issue(for: field)
    }

    private func commitTextEntry() {
        let digitsOnly = draftText.filter(\.isNumber)
        guard let parsed = Int(digitsOnly), parsed >= textEntryRange.lowerBound else {
            draftValue = appliedValue
            draftText = "\(appliedValue)"
            return
        }

        draftValue = min(textEntryRange.upperBound, parsed)
        deferredCommit.cancel()
        appliedValue = draftValue
        draftText = "\(draftValue)"
    }

    private func scheduleCommit() {
        deferredCommit.schedule(after: delay) {
            appliedValue = draftValue
        }
    }

    private func flushCommit() {
        deferredCommit.flush {
            appliedValue = draftValue
        }
    }
}

struct EventuallyAppliedSegmentedPicker<Option: Hashable>: View {
    let title: String
    let field: RuntimeValidationField?
    @Binding var appliedValue: Option
    let options: [Option]
    let delay: TimeInterval
    let optionTitle: (Option) -> String
    @Environment(\.runtimeValidationReport) private var validationReport
    @Environment(\.highlightedValidationField) private var highlightedValidationField

    init(
        title: String,
        field: RuntimeValidationField? = nil,
        appliedValue: Binding<Option>,
        options: [Option],
        delay: TimeInterval = 1.0,
        optionTitle: @escaping (Option) -> String
    ) {
        self.title = title
        self.field = field
        _appliedValue = appliedValue
        self.options = options
        self.delay = delay
        self.optionTitle = optionTitle
    }

    var body: some View {
        let issue = validationIssue
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(issue == nil ? Color.primary : Color.red.opacity(0.95))

            Picker(title, selection: $appliedValue) {
                ForEach(options, id: \.self) { option in
                    Text(optionTitle(option)).tag(option)
                }
            }
            .pickerStyle(.segmented)

            if let issue {
                Text(issue.message)
                    .font(.caption2)
                    .foregroundStyle(Color.red.opacity(0.95))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .validationDecoration(issue: issue, isHighlighted: field != nil && highlightedValidationField == field)
    }

    private var validationIssue: RuntimeValidationIssue? {
        guard let field else { return nil }
        return validationReport.issue(for: field)
    }
}

struct ExpandableSettingsSection<Accessory: View, Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content

    init(
        title: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self._isExpanded = isExpanded
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CollapsibleSectionHeader(
                title: title,
                isExpanded: $isExpanded,
                accessory: { accessory }
            )

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    content
                }
                .padding(.top, 12)
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
                .overlay(alignment: .leading) {
                    SectionBracketMarker()
                        .padding(.top, 12)
                        .padding(.bottom, 14)
                        .offset(x: -16)
                }
            }
        }
        .background(.quaternary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct CollapsibleSectionHeader<Accessory: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    let titleFont: Font
    let titleColor: Color
    let minHeight: CGFloat
    let cornerRadius: CGFloat
    let backgroundOpacity: Double
    @ViewBuilder let accessory: Accessory

    init(
        title: String,
        isExpanded: Binding<Bool>,
        titleFont: Font = .caption.weight(.semibold),
        titleColor: Color = .primary,
        minHeight: CGFloat = 34,
        cornerRadius: CGFloat = 8,
        backgroundOpacity: Double = 0.10,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self._isExpanded = isExpanded
        self.titleFont = titleFont
        self.titleColor = titleColor
        self.minHeight = minHeight
        self.cornerRadius = cornerRadius
        self.backgroundOpacity = backgroundOpacity
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isExpanded ? "chevron.down.circle.fill" : "chevron.right.circle.fill")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(titleFont)
                        .foregroundStyle(titleColor)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            accessory
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(backgroundOpacity), in: RoundedRectangle(cornerRadius: cornerRadius))
    }
}
