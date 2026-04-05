import Foundation

// Generic base class providing pub/sub mechanics for all observers.
// Subclasses override `start()` to wire up their platform-specific observation
// mechanism and call `notify(_:)` when an event occurs.
class EventObserver<E: AppEvent> {
    struct Subscription {
        let id: UUID
        let handler: (E) -> Void
    }

    private(set) var subscriptions: [Subscription] = []

    @discardableResult
    func subscribe(handler: @escaping (E) -> Void) -> UUID {
        let id = UUID()
        subscriptions.append(Subscription(id: id, handler: handler))
        return id
    }

    func unsubscribe(id: UUID) {
        subscriptions.removeAll { $0.id == id }
    }

    func notify(_ event: E) {
        for subscription in subscriptions {
            subscription.handler(event)
        }
    }
}
