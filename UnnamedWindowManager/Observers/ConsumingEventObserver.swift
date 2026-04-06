import Foundation

// Base class for observers where subscribers can consume events, stopping further propagation.
// Handlers return true to consume the event (preventing downstream subscribers from receiving it).
class ConsumingEventObserver<E: AppEvent> {
    struct Subscription {
        let id: UUID
        let handler: (E) -> Bool
    }

    private(set) var subscriptions: [Subscription] = []

    @discardableResult
    func subscribe(handler: @escaping (E) -> Bool) -> UUID {
        let id = UUID()
        subscriptions.append(Subscription(id: id, handler: handler))
        return id
    }

    func unsubscribe(id: UUID) {
        subscriptions.removeAll { $0.id == id }
    }

    // Notifies subscribers in order; stops and returns true if any subscriber consumes the event.
    @discardableResult
    func notify(_ event: E) -> Bool {
        for subscription in subscriptions {
            if subscription.handler(event) { return true }
        }
        return false
    }
}
