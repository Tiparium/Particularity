import SwiftUI
import AppKit

private final class InteractionAwareSplitView: NSSplitView {
    var onInteractionEnded: (() -> Void)?
    var shouldDrawDividers = true

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        onInteractionEnded?()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        onInteractionEnded?()
    }

    override func drawDivider(in rect: NSRect) {
        guard shouldDrawDividers else { return }
        super.drawDivider(in: rect)
    }
}

struct PersistentThreePaneSplitView<Left: View, Center: View, Right: View>: NSViewControllerRepresentable {
    let defaultLeftWidth: CGFloat
    let defaultRightWidth: CGFloat
    let initialLeftWidth: CGFloat
    let initialRightWidth: CGFloat
    let leftPanelVisible: Bool
    let rightPanelVisible: Bool
    let minSideWidth: CGFloat
    let maxSideWidthRatio: CGFloat
    let onWidthsChanged: (CGFloat, CGFloat) -> Void
    let left: Left
    let center: Center
    let right: Right

    func makeNSViewController(context: Context) -> Controller {
        Controller(
            defaultLeftWidth: defaultLeftWidth,
            defaultRightWidth: defaultRightWidth,
            initialLeftWidth: initialLeftWidth,
            initialRightWidth: initialRightWidth,
            leftPanelVisible: leftPanelVisible,
            rightPanelVisible: rightPanelVisible,
            minSideWidth: minSideWidth,
            maxSideWidthRatio: maxSideWidthRatio,
            onWidthsChanged: onWidthsChanged,
            left: NSHostingView(rootView: left),
            center: NSHostingView(rootView: center),
            right: NSHostingView(rootView: right)
        )
    }

    func updateNSViewController(_ controller: Controller, context: Context) {
        controller.update(
            left: left,
            center: center,
            right: right,
            leftPanelVisible: leftPanelVisible,
            rightPanelVisible: rightPanelVisible,
            onWidthsChanged: onWidthsChanged
        )
    }

    final class Controller: NSViewController, NSSplitViewDelegate {
        private let defaultLeftWidth: CGFloat
        private let defaultRightWidth: CGFloat
        private let initialLeftWidth: CGFloat
        private let initialRightWidth: CGFloat
        private var leftPanelVisible: Bool
        private var rightPanelVisible: Bool
        private let minSideWidth: CGFloat
        private let maxSideWidthRatio: CGFloat
        private let splitView = InteractionAwareSplitView()
        private let leftHost: NSHostingView<Left>
        private let centerHost: NSHostingView<Center>
        private let rightHost: NSHostingView<Right>
        private var onWidthsChanged: (CGFloat, CGFloat) -> Void
        private var hasAppliedInitialLayout = false
        private var currentLeftWidth: CGFloat?
        private var currentRightWidth: CGFloat?

        init(
            defaultLeftWidth: CGFloat,
            defaultRightWidth: CGFloat,
            initialLeftWidth: CGFloat,
            initialRightWidth: CGFloat,
            leftPanelVisible: Bool,
            rightPanelVisible: Bool,
            minSideWidth: CGFloat,
            maxSideWidthRatio: CGFloat,
            onWidthsChanged: @escaping (CGFloat, CGFloat) -> Void,
            left: NSHostingView<Left>,
            center: NSHostingView<Center>,
            right: NSHostingView<Right>
        ) {
            self.defaultLeftWidth = defaultLeftWidth
            self.defaultRightWidth = defaultRightWidth
            self.initialLeftWidth = initialLeftWidth
            self.initialRightWidth = initialRightWidth
            self.leftPanelVisible = leftPanelVisible
            self.rightPanelVisible = rightPanelVisible
            self.minSideWidth = minSideWidth
            self.maxSideWidthRatio = maxSideWidthRatio
            self.onWidthsChanged = onWidthsChanged
            self.leftHost = left
            self.centerHost = center
            self.rightHost = right
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func loadView() {
            splitView.isVertical = true
            splitView.dividerStyle = .thin
            splitView.delegate = self
            splitView.translatesAutoresizingMaskIntoConstraints = false
            splitView.onInteractionEnded = { [weak self] in
                self?.persistCurrentWidths()
            }

            leftHost.translatesAutoresizingMaskIntoConstraints = false
            centerHost.translatesAutoresizingMaskIntoConstraints = false
            rightHost.translatesAutoresizingMaskIntoConstraints = false

            leftHost.identifier = NSUserInterfaceItemIdentifier("left")
            centerHost.identifier = NSUserInterfaceItemIdentifier("center")
            rightHost.identifier = NSUserInterfaceItemIdentifier("right")

            splitView.addArrangedSubview(leftHost)
            splitView.addArrangedSubview(centerHost)
            splitView.addArrangedSubview(rightHost)

            let container = NSView()
            container.addSubview(splitView)
            NSLayoutConstraint.activate([
                splitView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                splitView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                splitView.topAnchor.constraint(equalTo: container.topAnchor),
                splitView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            view = container
        }

        override func viewDidLayout() {
            super.viewDidLayout()
            guard !hasAppliedInitialLayout else { return }
            guard splitView.bounds.width > 0 else { return }
            applyInitialLayoutIfNeeded()
            hasAppliedInitialLayout = true
        }

        func update(
            left: Left,
            center: Center,
            right: Right,
            leftPanelVisible: Bool,
            rightPanelVisible: Bool,
            onWidthsChanged: @escaping (CGFloat, CGFloat) -> Void
        ) {
            leftHost.rootView = left
            centerHost.rootView = center
            rightHost.rootView = right
            let visibilityChanged = self.leftPanelVisible != leftPanelVisible || self.rightPanelVisible != rightPanelVisible
            self.leftPanelVisible = leftPanelVisible
            self.rightPanelVisible = rightPanelVisible
            self.onWidthsChanged = onWidthsChanged
            if visibilityChanged, splitView.bounds.width > 0 {
                applyVisibilityState()
            }
        }

        private func applyInitialLayoutIfNeeded() {
            let totalWidth = splitView.bounds.width
            let dividerThickness = splitView.dividerThickness
            let maxSideWidth = max(minSideWidth, min(460, totalWidth * maxSideWidthRatio))
            let leftWidth = min(max(initialLeftWidth, minSideWidth), maxSideWidth)
            let rightWidth = min(max(initialRightWidth, minSideWidth), maxSideWidth)
            currentLeftWidth = leftWidth
            currentRightWidth = rightWidth
            applyVisibilityState(dividerThickness: dividerThickness)
        }

        private func applyVisibilityState(dividerThickness: CGFloat? = nil) {
            let totalWidth = splitView.bounds.width
            guard totalWidth > 0 else { return }
            let dividerThickness = dividerThickness ?? splitView.dividerThickness

            let maxSideWidth = max(minSideWidth, min(460, totalWidth * maxSideWidthRatio))
            let leftWidth = min(max(currentLeftWidth ?? defaultLeftWidth, minSideWidth), maxSideWidth)
            let rightWidth = min(max(currentRightWidth ?? defaultRightWidth, minSideWidth), maxSideWidth)

            leftHost.isHidden = !leftPanelVisible
            rightHost.isHidden = !rightPanelVisible

            switch (leftPanelVisible, rightPanelVisible) {
            case (true, true):
                splitView.shouldDrawDividers = true
                splitView.setPosition(leftWidth, ofDividerAt: 0)
                let rightDividerPosition = totalWidth - rightWidth - dividerThickness
                splitView.setPosition(max(leftWidth + dividerThickness + 1, rightDividerPosition), ofDividerAt: 1)
            case (true, false):
                splitView.shouldDrawDividers = true
                splitView.setPosition(leftWidth, ofDividerAt: 0)
                splitView.setPosition(totalWidth, ofDividerAt: 1)
            case (false, true):
                splitView.shouldDrawDividers = true
                splitView.setPosition(0, ofDividerAt: 0)
                let rightDividerPosition = totalWidth - rightWidth - dividerThickness
                splitView.setPosition(max(dividerThickness, rightDividerPosition), ofDividerAt: 1)
            case (false, false):
                splitView.shouldDrawDividers = false
                splitView.setPosition(0, ofDividerAt: 0)
                splitView.setPosition(totalWidth, ofDividerAt: 1)
            }

            splitView.adjustSubviews()
            splitView.needsDisplay = true
            cacheCurrentWidths()
        }

        func splitViewDidResizeSubviews(_ notification: Notification) {
            cacheCurrentWidths()
        }

        func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
            false
        }

        func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
            switch dividerIndex {
            case 0:
                if !leftPanelVisible {
                    return 0
                }
                return minSideWidth
            case 1:
                if !rightPanelVisible {
                    return splitView.bounds.width
                }
                let totalWidth = splitView.bounds.width
                let maxSideWidth = max(minSideWidth, min(460, totalWidth * maxSideWidthRatio))
                return totalWidth - maxSideWidth
            default:
                return proposedMinimumPosition
            }
        }

        func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
            let totalWidth = splitView.bounds.width
            switch dividerIndex {
            case 0:
                if !leftPanelVisible {
                    return 0
                }
                let maxSideWidth = max(minSideWidth, min(460, totalWidth * maxSideWidthRatio))
                return maxSideWidth
            case 1:
                if !rightPanelVisible {
                    return totalWidth
                }
                return totalWidth - minSideWidth
            default:
                return proposedMaximumPosition
            }
        }

        private func cacheCurrentWidths() {
            guard splitView.arrangedSubviews.count == 3 else { return }
            if leftPanelVisible {
                currentLeftWidth = splitView.arrangedSubviews[0].frame.width
            }
            if rightPanelVisible {
                currentRightWidth = splitView.arrangedSubviews[2].frame.width
            }
        }

        private func persistCurrentWidths() {
            guard let currentLeftWidth, let currentRightWidth else { return }
            onWidthsChanged(currentLeftWidth, currentRightWidth)
        }
    }
}

struct PersistentVerticalSplitView<Top: View, Bottom: View>: NSViewControllerRepresentable {
    let defaultBottomHeight: CGFloat
    let initialBottomHeight: CGFloat
    let bottomPanelVisible: Bool
    let minBottomHeight: CGFloat
    let maxBottomHeightRatio: CGFloat
    let onBottomHeightChanged: (CGFloat) -> Void
    let top: Top
    let bottom: Bottom

    func makeNSViewController(context: Context) -> Controller {
        Controller(
            defaultBottomHeight: defaultBottomHeight,
            initialBottomHeight: initialBottomHeight,
            bottomPanelVisible: bottomPanelVisible,
            minBottomHeight: minBottomHeight,
            maxBottomHeightRatio: maxBottomHeightRatio,
            onBottomHeightChanged: onBottomHeightChanged,
            top: NSHostingView(rootView: top),
            bottom: NSHostingView(rootView: bottom)
        )
    }

    func updateNSViewController(_ controller: Controller, context: Context) {
        controller.update(
            top: top,
            bottom: bottom,
            bottomPanelVisible: bottomPanelVisible,
            onBottomHeightChanged: onBottomHeightChanged
        )
    }

    final class Controller: NSViewController, NSSplitViewDelegate {
        private let defaultBottomHeight: CGFloat
        private let initialBottomHeight: CGFloat
        private var bottomPanelVisible: Bool
        private let minBottomHeight: CGFloat
        private let maxBottomHeightRatio: CGFloat
        private let splitView = InteractionAwareSplitView()
        private let topHost: NSHostingView<Top>
        private let bottomHost: NSHostingView<Bottom>
        private var onBottomHeightChanged: (CGFloat) -> Void
        private var hasAppliedInitialLayout = false
        private var currentBottomHeight: CGFloat?

        init(
            defaultBottomHeight: CGFloat,
            initialBottomHeight: CGFloat,
            bottomPanelVisible: Bool,
            minBottomHeight: CGFloat,
            maxBottomHeightRatio: CGFloat,
            onBottomHeightChanged: @escaping (CGFloat) -> Void,
            top: NSHostingView<Top>,
            bottom: NSHostingView<Bottom>
        ) {
            self.defaultBottomHeight = defaultBottomHeight
            self.initialBottomHeight = initialBottomHeight
            self.bottomPanelVisible = bottomPanelVisible
            self.minBottomHeight = minBottomHeight
            self.maxBottomHeightRatio = maxBottomHeightRatio
            self.onBottomHeightChanged = onBottomHeightChanged
            self.topHost = top
            self.bottomHost = bottom
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func loadView() {
            splitView.isVertical = false
            splitView.dividerStyle = .thin
            splitView.delegate = self
            splitView.translatesAutoresizingMaskIntoConstraints = false
            splitView.onInteractionEnded = { [weak self] in
                self?.persistCurrentBottomHeight()
            }

            topHost.translatesAutoresizingMaskIntoConstraints = false
            bottomHost.translatesAutoresizingMaskIntoConstraints = false

            topHost.identifier = NSUserInterfaceItemIdentifier("top")
            bottomHost.identifier = NSUserInterfaceItemIdentifier("bottom")

            splitView.addArrangedSubview(topHost)
            splitView.addArrangedSubview(bottomHost)

            let container = NSView()
            container.addSubview(splitView)
            NSLayoutConstraint.activate([
                splitView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                splitView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                splitView.topAnchor.constraint(equalTo: container.topAnchor),
                splitView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            view = container
        }

        override func viewDidLayout() {
            super.viewDidLayout()
            guard !hasAppliedInitialLayout else { return }
            guard splitView.bounds.height > 0 else { return }
            applyInitialLayoutIfNeeded()
            hasAppliedInitialLayout = true
        }

        func update(
            top: Top,
            bottom: Bottom,
            bottomPanelVisible: Bool,
            onBottomHeightChanged: @escaping (CGFloat) -> Void
        ) {
            topHost.rootView = top
            bottomHost.rootView = bottom
            let visibilityChanged = self.bottomPanelVisible != bottomPanelVisible
            self.bottomPanelVisible = bottomPanelVisible
            self.onBottomHeightChanged = onBottomHeightChanged
            if visibilityChanged, splitView.bounds.height > 0 {
                applyVisibilityState()
            }
        }

        private func applyInitialLayoutIfNeeded() {
            let totalHeight = splitView.bounds.height
            let dividerThickness = splitView.dividerThickness
            let maxBottomHeight = max(minBottomHeight, min(420, totalHeight * maxBottomHeightRatio))
            let bottomHeight = min(max(initialBottomHeight, minBottomHeight), maxBottomHeight)
            currentBottomHeight = bottomHeight
            applyVisibilityState(dividerThickness: dividerThickness)
        }

        private func applyVisibilityState(dividerThickness: CGFloat? = nil) {
            let totalHeight = splitView.bounds.height
            guard totalHeight > 0 else { return }
            let dividerThickness = dividerThickness ?? splitView.dividerThickness

            if bottomPanelVisible {
                splitView.shouldDrawDividers = true
                bottomHost.isHidden = false
                let maxBottomHeight = max(minBottomHeight, min(420, totalHeight * maxBottomHeightRatio))
                let bottomHeight = min(max(currentBottomHeight ?? defaultBottomHeight, minBottomHeight), maxBottomHeight)
                let dividerPosition = totalHeight - bottomHeight - dividerThickness
                splitView.setPosition(max(320, dividerPosition), ofDividerAt: 0)
            } else {
                splitView.shouldDrawDividers = false
                splitView.setPosition(totalHeight, ofDividerAt: 0)
                bottomHost.isHidden = true
            }

            splitView.adjustSubviews()
            splitView.needsDisplay = true
            cacheCurrentBottomHeight()
        }

        func splitViewDidResizeSubviews(_ notification: Notification) {
            cacheCurrentBottomHeight()
        }

        func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
            false
        }

        func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
            guard dividerIndex == 0 else { return proposedMinimumPosition }
            let totalHeight = splitView.bounds.height
            let maxBottomHeight = max(minBottomHeight, min(420, totalHeight * maxBottomHeightRatio))
            return max(320, totalHeight - maxBottomHeight)
        }

        func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
            guard dividerIndex == 0 else { return proposedMaximumPosition }
            let totalHeight = splitView.bounds.height
            return totalHeight - minBottomHeight
        }

        private func cacheCurrentBottomHeight() {
            guard splitView.arrangedSubviews.count == 2, bottomPanelVisible else { return }
            currentBottomHeight = splitView.arrangedSubviews[1].frame.height
        }

        private func persistCurrentBottomHeight() {
            guard let currentBottomHeight else { return }
            onBottomHeightChanged(currentBottomHeight)
        }
    }
}
