import Foundation
import Darwin

/// Shared-memory ring handed over by the engine, ready to be wrapped in Metal textures.
public struct RingBinding: @unchecked Sendable {
    public let base: UnsafeMutableRawPointer
    public let mappedBytes: Int
    public let slots: Int
    public let headerBytes: Int
    public let slotBytes: Int
    public let bytesPerRow: Int
    public let width: Int
    public let height: Int

    public func slotAddress(_ index: Int) -> UnsafeMutableRawPointer {
        base.advanced(by: headerBytes + index * slotBytes)
    }
}

/// A frame announcement: which slot holds it, and when the engine published it.
public struct SlotFrame: Sendable {
    public let seq: UInt32
    public let slot: Int
    public let producedNs: UInt64
}

/// MUVS/3 client — pairs with tools/engine/video_socket.py.
///
/// The socket carries nothing but 15-byte frame announcements. Pixels live in a
/// shared-memory ring whose descriptor arrives once over SCM_RIGHTS, and the
/// renderer builds Metal textures directly over those slots, so no pixel is ever
/// copied on this side.
///
/// `acknowledge` must be called once the GPU has finished reading a slot. That
/// both returns a credit to the engine and makes slot recycling safe.
public final class VideoSocketReader: @unchecked Sendable {
    public let path: String
    public var onBind: ((RingBinding) -> Void)?
    public var onFrame: ((SlotFrame) -> Void)?
    public private(set) var framesReceived: UInt64 = 0
    public let endToEndLatency = LatencyWindow()
    public private(set) var codecName: String = "muvs3"

    private var thread: Thread?
    private var stopFlag = false

    private let socketLock = NSLock()
    private var socketFd: Int32 = -1

    private var ring: UnsafeMutableRawPointer?
    private var ringSize = 0
    private var ringFd: Int32 = -1

    private static let magic: [UInt8] = Array("MUV3".utf8)
    private static let version: UInt16 = 3
    private static let msgHello: UInt8 = 0x01
    private static let msgBind: UInt8 = 0x11
    private static let msgFrame: UInt8 = 0x20
    private static let msgAck: UInt8 = 0x30

    public init(path: String = "/tmp/mirrorue_video.sock") {
        self.path = path
    }

    public var isAvailable: Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public func start() {
        stopFlag = false
        let t = Thread { [weak self] in self?.runLoop() }
        t.name = "mirrorue-muvs"
        t.qualityOfService = .userInteractive
        t.start()
        thread = t
    }

    public func stop() {
        stopFlag = true
        thread = nil
        socketLock.lock()
        socketFd = -1
        socketLock.unlock()
        unmapRing()
    }

    deinit { stop() }

    /// Safe to call from any thread, including a Metal completion handler.
    public func acknowledge(seq: UInt32, displayedNs: UInt64) {
        socketLock.lock()
        let fd = socketFd
        var ack = [UInt8]()
        ack.reserveCapacity(13)
        ack.append(Self.msgAck)
        appendLE32(&ack, seq)
        appendLE64(&ack, displayedNs)
        if fd >= 0 { _ = UnixSocketIO.writeAll(fd, ack) }
        socketLock.unlock()
    }

    private func runLoop() {
        while !stopFlag {
            if !session() {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }

    /// One full attach → stream → detach cycle. Returns false to back off.
    private func session() -> Bool {
        let fd = UnixSocketIO.connect(path: path)
        guard fd >= 0 else { return false }
        socketLock.lock()
        socketFd = fd
        socketLock.unlock()
        defer {
            socketLock.lock()
            socketFd = -1
            socketLock.unlock()
            Darwin.close(fd)
            unmapRing()
        }

        var hello = [UInt8]()
        hello.append(Self.msgHello)
        hello.append(contentsOf: Self.magic)
        appendLE16(&hello, Self.version)
        appendLE16(&hello, 0)
        guard UnixSocketIO.writeAll(fd, hello) else { return false }

        var scratch = [UInt8](repeating: 0, count: 64)

        while !stopFlag {
            guard let (kind, descriptor) = UnixSocketIO.readByteWithDescriptor(fd) else { return true }

            switch kind {
            case Self.msgBind:
                guard handleBind(fd, descriptor: descriptor, scratch: &scratch) else { return true }
            case Self.msgFrame:
                guard handleFrame(fd, scratch: &scratch) else { return true }
            default:
                if let descriptor { Darwin.close(descriptor) }
                return true
            }
        }
        return true
    }

    // BIND: magic(4) version(2) slots(2) stride(4) slotBytes(4) w(2) h(2) header(4) pathLen(2)
    private func handleBind(_ fd: Int32, descriptor: Int32?, scratch: inout [UInt8]) -> Bool {
        func fail() -> Bool {
            if let descriptor { Darwin.close(descriptor) }
            return false
        }
        guard UnixSocketIO.readAll(fd, into: &scratch, offset: 0, count: 26) else { return fail() }
        guard scratch[0] == Self.magic[0], scratch[1] == Self.magic[1],
              scratch[2] == Self.magic[2], scratch[3] == Self.magic[3] else { return fail() }

        let slots = Int(readLE16(scratch, 6))
        let bytesPerRow = Int(readLE32(scratch, 8))
        let slotBytes = Int(readLE32(scratch, 12))
        let width = Int(readLE16(scratch, 16))
        let height = Int(readLE16(scratch, 18))
        let headerBytes = Int(readLE32(scratch, 20))
        let pathLength = Int(readLE16(scratch, 24))

        var pathBytes = [UInt8](repeating: 0, count: max(1, pathLength))
        guard pathLength == 0
                || UnixSocketIO.readAll(fd, into: &pathBytes, offset: 0, count: pathLength)
        else { return fail() }
        let shmPath = pathLength > 0
            ? String(decoding: pathBytes[0..<pathLength], as: UTF8.self)
            : ""

        unmapRing()
        let size = headerBytes + slotBytes * slots

        // The passed descriptor is authoritative; the path only covers the case
        // where SCM_RIGHTS did not make it through.
        var mapFd = descriptor ?? -1
        let viaDescriptor = mapFd >= 0
        if !viaDescriptor, !shmPath.isEmpty {
            mapFd = open(shmPath, O_RDONLY)
        }
        guard mapFd >= 0 else { return false }

        let protection = viaDescriptor ? (PROT_READ | PROT_WRITE) : PROT_READ
        let mapped = mmap(nil, size, protection, MAP_SHARED, mapFd, 0)
        guard let mapped, mapped != MAP_FAILED else {
            Darwin.close(mapFd)
            return false
        }

        ring = mapped
        ringSize = size
        ringFd = mapFd

        fputs(
            "MediaKit MUVS/3 ring \(width)x\(height) stride=\(bytesPerRow) "
                + "×\(slots) slots via \(viaDescriptor ? "fd" : "path")\n",
            stderr
        )
        onBind?(
            RingBinding(
                base: mapped,
                mappedBytes: size,
                slots: slots,
                headerBytes: headerBytes,
                slotBytes: slotBytes,
                bytesPerRow: bytesPerRow,
                width: width,
                height: height
            )
        )
        return true
    }

    // FRAME: seq(4) slot(2) producedNs(8)
    private func handleFrame(_ fd: Int32, scratch: inout [UInt8]) -> Bool {
        guard UnixSocketIO.readAll(fd, into: &scratch, offset: 0, count: 14) else { return false }
        let seq = readLE32(scratch, 0)
        let slot = Int(readLE16(scratch, 4))
        let producedNs = readLE64(scratch, 6)

        guard ring != nil else {
            // Geometry moved under us; keep credits flowing until the next BIND.
            acknowledge(seq: seq, displayedNs: producedNs)
            return true
        }

        framesReceived &+= 1
        if producedNs > 0 {
            let now = monotonicNow()
            if now > producedNs {
                endToEndLatency.add(Double(now - producedNs) / 1_000_000.0)
            }
        }
        onFrame?(SlotFrame(seq: seq, slot: slot, producedNs: producedNs))
        return true
    }

    private func unmapRing() {
        if let ring, ringSize > 0 { munmap(ring, ringSize) }
        ring = nil
        ringSize = 0
        if ringFd >= 0 {
            Darwin.close(ringFd)
            ringFd = -1
        }
    }
}

@inline(__always) private func appendLE16(_ out: inout [UInt8], _ v: UInt16) {
    out.append(UInt8(v & 0xff))
    out.append(UInt8((v >> 8) & 0xff))
}

@inline(__always) private func appendLE32(_ out: inout [UInt8], _ v: UInt32) {
    for i in 0..<4 { out.append(UInt8((v >> (UInt32(i) * 8)) & 0xff)) }
}

@inline(__always) private func appendLE64(_ out: inout [UInt8], _ v: UInt64) {
    for i in 0..<8 { out.append(UInt8((v >> (UInt64(i) * 8)) & 0xff)) }
}

@inline(__always) private func readLE16(_ b: [UInt8], _ off: Int) -> UInt16 {
    UInt16(b[off]) | (UInt16(b[off + 1]) << 8)
}

@inline(__always) private func readLE32(_ b: [UInt8], _ off: Int) -> UInt32 {
    UInt32(b[off]) | (UInt32(b[off + 1]) << 8) | (UInt32(b[off + 2]) << 16)
        | (UInt32(b[off + 3]) << 24)
}

@inline(__always) private func readLE64(_ b: [UInt8], _ off: Int) -> UInt64 {
    var v: UInt64 = 0
    for i in 0..<8 { v |= UInt64(b[off + i]) << (UInt64(i) * 8) }
    return v
}

@inline(__always) public func monotonicNow() -> UInt64 {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC_RAW, &ts)
    return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
}
