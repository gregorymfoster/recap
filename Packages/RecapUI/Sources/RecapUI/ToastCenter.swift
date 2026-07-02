import Foundation
import Observation
import SwiftUI

/// A transient banner: a message, an optional action button, and how long
/// it stays before auto-dismissing.
public struct Toast: Identifiable, Equatable {
    public struct Action: Equatable {
        public let title: String
        public let handler: @MainActor () -> Void

        public init(title: String, handler: @escaping @MainActor () -> Void) {
            self.title = title
            self.handler = handler
        }

        public static func == (lhs: Action, rhs: Action) -> Bool {
            lhs.title == rhs.title
        }
    }

    public let id = UUID()
    public let message: String
    public let action: Action?

    public init(message: String, action: Action? = nil) {
        self.message = message
        self.action = action
    }

    public static func == (lhs: Toast, rhs: Toast) -> Bool {
        lhs.id == rhs.id
    }
}

/// Queues and times out transient error/status banners. One toast shows at a
/// time; more are queued and shown in order. Owned by `AppStores` — never
/// build this in a view init (see the warning in AppStores.swift).
@MainActor
@Observable
public final class ToastCenter {
    /// The toast currently on screen, if any.
    public private(set) var current: Toast?

    /// Auto-dismiss delay; overridable for tests.
    private let dismissDelay: Duration
    private var queue: [Toast] = []
    private var dismissTask: Task<Void, Never>?

    public init(dismissDelay: Duration = .seconds(6)) {
        self.dismissDelay = dismissDelay
    }

    /// Enqueues a toast. If nothing is showing, it appears immediately;
    /// otherwise it waits behind whatever's already queued.
    public func show(_ toast: Toast) {
        if current == nil {
            present(toast)
        } else {
            queue.append(toast)
        }
    }

    /// Convenience for the common case of a plain message with no action.
    public func show(_ message: String, actionTitle: String? = nil, action: (@MainActor () -> Void)? = nil) {
        let toastAction: Toast.Action? = {
            guard let actionTitle, let action else { return nil }
            return Toast.Action(title: actionTitle, handler: action)
        }()
        show(Toast(message: message, action: toastAction))
    }

    /// Dismisses the current toast (manual close) and advances the queue.
    public func dismissCurrent() {
        dismissTask?.cancel()
        dismissTask = nil
        current = nil
        advance()
    }

    private func present(_ toast: Toast) {
        current = toast
        dismissTask?.cancel()
        dismissTask = Task { [weak self, dismissDelay] in
            try? await Task.sleep(for: dismissDelay)
            guard !Task.isCancelled else { return }
            self?.dismissCurrent()
        }
    }

    private func advance() {
        guard current == nil, !queue.isEmpty else { return }
        present(queue.removeFirst())
    }
}
