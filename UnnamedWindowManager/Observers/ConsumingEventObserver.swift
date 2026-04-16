import Foundation

// Base class for observers where subscribers can consume events, stopping further propagation.
// Handlers return true to consume the event (preventing downstream subscribers from receiving it).
class ConsumingEventObserver<E: AppEvent> {
    struct Subscription {
        let id: UUID
        let message: String
        let handler: (E) -> Bool
    }

    private(set) var subscriptions: [Subscription] = []

    @discardableResult
    func subscribe(_ message: String, handler: @escaping (E) -> Bool) -> UUID {
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

    // Notifies subscribers in order; stops and returns true if any subscriber consumes the event.
    @discardableResult
    func notify(_ event: E) -> Bool {
        for subscription in subscriptions {
            if subscription.handler(event) { return true }
        }
        return false
    }
}
