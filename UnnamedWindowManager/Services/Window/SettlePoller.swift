import Foundation

// Polls a condition at a fixed interval until it is satisfied or a timeout elapses.
enum SettlePoller {

    private static let pollInterval: TimeInterval = 0.02

    /// Polls `condition` every 20 ms on the main queue.
    /// Calls `completion(true)` when `condition` returns `true`,
    /// or `completion(false)` when `timeout` seconds have elapsed.
    static func poll(
        timeout: TimeInterval = Double(Config.animationDuration) + 0.1,
        condition: @escaping () -> Bool,
        completion: @escaping (Bool) -> Void
    ) {
        let deadline = DispatchTime.now() + timeout

        func tick() {
            if condition() {
                completion(true)
                return
            }
            if DispatchTime.now() >= deadline {
                completion(false)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) {
                tick()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) {
            tick()
        }
    }
}
