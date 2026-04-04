import Foundation

struct DragInteractionState {
    enum ClickThenDragEndBehavior {
        case explicitOnly
        case explicitOrIndirectTouchLift
    }

    let clickThenDragEndBehavior: ClickThenDragEndBehavior

    private(set) var isDirectDragActive = false
    private(set) var isClickThenDragActive = false
    private var activeIndirectTouchIDs: Set<ObjectIdentifier> = []

    init(clickThenDragEndBehavior: ClickThenDragEndBehavior) {
        self.clickThenDragEndBehavior = clickThenDragEndBehavior
    }

    mutating func beginInteraction(for mode: ProgramSettingsStore.DragInputMode) -> Bool {
        switch mode {
        case .clickAndDrag:
            isDirectDragActive = true
            return true
        case .clickThenDrag:
            isClickThenDragActive.toggle()
            if !isClickThenDragActive {
                activeIndirectTouchIDs.removeAll()
            }
            return isClickThenDragActive
        }
    }

    mutating func endPrimaryInteraction(for mode: ProgramSettingsStore.DragInputMode) {
        if mode == .clickAndDrag {
            isDirectDragActive = false
        }
    }

    mutating func endClickThenDragInteraction() {
        isClickThenDragActive = false
        activeIndirectTouchIDs.removeAll()
    }

    mutating func registerIndirectTouches(_ touchIDs: some Sequence<ObjectIdentifier>) {
        activeIndirectTouchIDs.formUnion(touchIDs)
    }

    mutating func unregisterIndirectTouches(
        _ touchIDs: some Sequence<ObjectIdentifier>,
        isPrimaryButtonPressed: Bool
    ) -> Bool {
        for touchID in touchIDs {
            activeIndirectTouchIDs.remove(touchID)
        }

        guard clickThenDragEndBehavior == .explicitOrIndirectTouchLift else {
            return isClickThenDragActive
        }

        if activeIndirectTouchIDs.isEmpty, !isPrimaryButtonPressed {
            isClickThenDragActive = false
        }
        return isClickThenDragActive
    }

    func isActive(for mode: ProgramSettingsStore.DragInputMode) -> Bool {
        switch mode {
        case .clickAndDrag:
            return isDirectDragActive
        case .clickThenDrag:
            return isClickThenDragActive
        }
    }

    mutating func reset() {
        isDirectDragActive = false
        isClickThenDragActive = false
        activeIndirectTouchIDs.removeAll()
    }
}
