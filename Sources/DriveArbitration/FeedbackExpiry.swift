import Foundation

/// Access from the same serial queue that owns the message.
package final class FeedbackExpiry {
    private let after: (TimeInterval, @escaping () -> Void) -> Void
    private var current: UUID?

    init(after: @escaping (TimeInterval, @escaping () -> Void) -> Void) {
        self.after = after
    }

    package convenience init(queue: DispatchQueue) {
        self.init { delay, callback in
            queue.asyncAfter(deadline: .now() + delay) { callback() }
        }
    }

    package func schedule(_ clear: @escaping () -> Void) {
        let token = UUID()
        current = token
        after(10) { [weak self] in
            guard let self, self.current == token else { return }
            self.current = nil
            clear()
        }
    }

    package func cancel() { current = nil }
}
