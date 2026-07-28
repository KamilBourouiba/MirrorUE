import Foundation

/// Rolling latency percentiles (p50 / p95) for the status strip.
public final class LatencyWindow: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Double] = []
    private let cap: Int

    public init(capacity: Int = 512) {
        self.cap = max(32, capacity)
    }

    public func add(_ ms: Double) {
        lock.lock()
        samples.append(ms)
        if samples.count > cap { samples.removeFirst(samples.count - cap) }
        lock.unlock()
    }

    public struct Snapshot {
        public let p50Ms: Double
        public let p95Ms: Double
        public let count: Int

        public init(p50Ms: Double, p95Ms: Double, count: Int) {
            self.p50Ms = p50Ms
            self.p95Ms = p95Ms
            self.count = count
        }
    }

    public func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        guard !samples.isEmpty else { return Snapshot(p50Ms: 0, p95Ms: 0, count: 0) }
        let sorted = samples.sorted()
        let n = sorted.count
        return Snapshot(
            p50Ms: sorted[n / 2],
            p95Ms: sorted[min(n - 1, Int(Double(n - 1) * 0.95))],
            count: n
        )
    }
}
