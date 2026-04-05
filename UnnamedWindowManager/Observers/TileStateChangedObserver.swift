// Pure pub/sub relay for tile state changes. ReapplyHandler calls notify() directly.
final class TileStateChangedObserver: EventObserver<TileStateChangedEvent> {
    static let shared = TileStateChangedObserver()
}
