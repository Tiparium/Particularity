import Foundation

@MainActor
final class DeferredActionHandler {
    private var workItem: DispatchWorkItem?

    func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) {
        workItem?.cancel()
        let workItem = DispatchWorkItem {
            Task { @MainActor in
                action()
            }
        }
        self.workItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func flush(action: @escaping @MainActor () -> Void) {
        workItem?.cancel()
        workItem = nil
        action()
    }

    func cancel() {
        workItem?.cancel()
        workItem = nil
    }
}
