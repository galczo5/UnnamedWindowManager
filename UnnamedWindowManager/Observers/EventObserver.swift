import Foundation

// Generic base class providing pub/sub mechanics for all observers.
// Subclasses override `start()` to wire up their platform-specific observation
// mechanism and call `notify(_:)` when an event occurs.
class EventObserver<E: AppEvent> {
    struct Subscription {
        let id: UUID
        let message: String
        let handler: (E) -> Void
    }

    private(set) var subscriptions: [Subscription] = []

    @discardableResult
    func subscribe(_ message: String, handler: @escaping (E) -> Void) -> UUID {
        let id = UUID()
        subscriptions.append(Subscription(id: id, message: message, handler: handler))
        Logger.shared.log("[\(E.self)] subscribed '\(message)' id=\(id), total=\(subscriptions.count)")
        return id
    }

    func unsubscribe(id: UUID) {
        let message = subscriptions.first { $0.id == id }?.message ?? "unknown"
        subscriptions.removeAll { $0.id == id }
        Logger.shared.log("[\(E.self)] unsubscribed '\(message)' id=\(id), total=\(subscriptions.count)")
    }

    func notify(_ event: E) {
        for subscription in subscriptions {
            subscription.handler(event)
        }
    }
}
