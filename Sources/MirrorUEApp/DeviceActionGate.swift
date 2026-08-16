import Foundation

/// Serializes agent HID batches against direct UI/API control.
///
/// The model may pause at many `await` points while typing or running macros.
/// A plain MainActor hop does not provide exclusivity because the actor is
/// re-entrant, so a small synchronous lease is used by every manual entry point.
final class DeviceActionGate: @unchecked Sendable {
    private enum ExclusiveOwner {
        case agentBatch
        case workflowPlayback
    }

    private let lock = NSLock()
    private var exclusiveOwner: ExclusiveOwner?
    private var manualLeaseCount = 0

    var allowsManualActions: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exclusiveOwner == nil
    }

    func beginAgentBatch() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard exclusiveOwner == nil, manualLeaseCount == 0 else { return false }
        exclusiveOwner = .agentBatch
        return true
    }

    func endAgentBatch() {
        lock.lock()
        if exclusiveOwner == .agentBatch {
            exclusiveOwner = nil
        }
        lock.unlock()
    }

    /// Holds the device for one complete deterministic workflow. Unlike a
    /// short manual lease, this excludes direct UI/API input as well as model
    /// action batches until playback finishes or is cancelled.
    func beginWorkflowPlayback() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard exclusiveOwner == nil, manualLeaseCount == 0 else { return false }
        exclusiveOwner = .workflowPlayback
        return true
    }

    func endWorkflowPlayback() {
        lock.lock()
        if exclusiveOwner == .workflowPlayback {
            exclusiveOwner = nil
        }
        lock.unlock()
    }

    func beginManualAction() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard exclusiveOwner == nil else { return false }
        manualLeaseCount += 1
        return true
    }

    func endManualAction() {
        lock.lock()
        manualLeaseCount = max(0, manualLeaseCount - 1)
        lock.unlock()
    }
}
