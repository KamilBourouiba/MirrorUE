import CoreVideo
import Foundation
import Metal

/// Retained CoreMediaIO frames for uninterrupted display.
///
/// Each slot holds a strong reference to the CVPixelBuffer (so its IOSurface
/// stays alive) and the CVMetalTexture built over it. Nothing is copied — the
/// GPU samples the same bytes the system produced — but we keep many frames
/// resident so a brief stall never blanks the window. Depth is intentional:
/// 32 slots of 1206×2622 BGRA is on the order of 400 MB of live surfaces.
public final class CaptureFrameRing: @unchecked Sendable {
    public struct Slot {
        public let texture: MTLTexture
        public let hold: CVMetalTexture
        public let pixels: CVPixelBuffer
    }

    public let slots: Int
    public private(set) var framesStored: UInt64 = 0

    private var ring: [Slot?]
    private var write = 0
    private var latest = -1
    private let lock = NSLock()
    private var cache: CVMetalTextureCache?

    public init(device: MTLDevice, slots: Int = 32) {
        self.slots = max(4, slots)
        self.ring = Array(repeating: nil, count: self.slots)
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        fputs(
            "MediaKit: capture ring ×\(self.slots) slots (retain IOSurfaces, zero-copy)\n",
            stderr
        )
    }

    public var current: Slot? {
        lock.lock()
        defer { lock.unlock() }
        guard latest >= 0 else { return nil }
        return ring[latest]
    }

    /// Retain one frame. Overwrites the oldest slot when full.
    @discardableResult
    public func push(_ pixelBuffer: CVPixelBuffer) -> Slot? {
        guard let cache else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return nil }

        var holder: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
                  kCFAllocatorDefault, cache, pixelBuffer, nil,
                  .bgra8Unorm, width, height, 0, &holder
              ) == kCVReturnSuccess,
              let holder,
              let texture = CVMetalTextureGetTexture(holder) else { return nil }

        let slot = Slot(texture: texture, hold: holder, pixels: pixelBuffer)
        lock.lock()
        let index = write
        ring[index] = slot
        write = (write + 1) % slots
        latest = index
        framesStored &+= 1
        lock.unlock()

        // Let the cache reclaim intermediate textures we no longer reference.
        if framesStored & 63 == 0 {
            CVMetalTextureCacheFlush(cache, 0)
        }
        return slot
    }
}
