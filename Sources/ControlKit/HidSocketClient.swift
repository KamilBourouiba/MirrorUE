import Foundation
import Darwin

/// Low-latency HID control via Unix domain socket (pairs with tools/engine/hid_socket.py).
///
/// Protocol v1 is write-only: the engine never ACKs. A successful `write`
/// only means the kernel accepted bytes for the engine worker — not that
/// Indigo/UniversalHID has applied the event. Waiting for a reply after
/// every key/touch caused asyncio `socket.send() raised exception` spam
/// once the peer half-closed.
///
/// Touch moves are coalesced on the HID queue. On disconnect the engine
/// drains already-queued work before tearing down the worker.
public final class HidSocketClient: @unchecked Sendable {
    public let path: String
    private let queue = DispatchQueue(label: "mirrorue.hid", qos: .userInteractive)
    private var fd: Int32 = -1
    private let lock = NSLock()

    private var touchBuf: [(contact: Bool, x: Int, y: Int)] = []
    private var touchPumping = false

    public init(path: String = "/tmp/mirrorue_hid.sock") {
        self.path = path
    }

    public var isAvailable: Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public func touch(type: String, x: Int, y: Int) {
        let contact = type != "release"
        queue.async { [weak self] in
            guard let self else { return }
            if contact, let last = self.touchBuf.last, last.contact {
                self.touchBuf[self.touchBuf.count - 1] = (true, x, y)
            } else {
                self.touchBuf.append((contact, x, y))
            }
            guard !self.touchPumping else { return }
            self.touchPumping = true
            while !self.touchBuf.isEmpty {
                let ev = self.touchBuf.removeFirst()
                self.sendTouch(contact: ev.contact, x: ev.x, y: ev.y)
            }
            self.touchPumping = false
        }
    }

    /// Atomic tap on the HID queue (contact → hold → release). Avoids coalescing
    /// a press into the next move when contact/release are posted separately.
    /// Default hold is intentionally firm — short contacts are often ignored by iOS.
    public func tap(x: Int, y: Int, holdMs: useconds_t = 160_000) {
        queue.async { [weak self] in
            guard let self else { return }
            // Drain any pending move stream first.
            while !self.touchBuf.isEmpty {
                let ev = self.touchBuf.removeFirst()
                self.sendTouch(contact: ev.contact, x: ev.x, y: ev.y)
            }
            self.sendTouch(contact: true, x: x, y: y)
            // Settle + reaffirm so Indigo doesn't treat a single report as a ghost.
            usleep(45_000)
            self.sendTouch(contact: true, x: x, y: y)
            usleep(max(holdMs, 100_000))
            self.sendTouch(contact: false, x: x, y: y)
        }
    }

    /// Release after ensuring the finger has been down at least `minHoldUs`.
    /// Used for mouse clicks that would otherwise be too brief for the digitizer.
    public func release(x: Int, y: Int, minHoldUs: useconds_t, pressedAt: UInt64) {
        queue.async { [weak self] in
            guard let self else { return }
            while !self.touchBuf.isEmpty {
                let ev = self.touchBuf.removeFirst()
                self.sendTouch(contact: ev.contact, x: ev.x, y: ev.y)
            }
            let now = DispatchTime.now().uptimeNanoseconds
            let elapsedUs = useconds_t(min(UInt64(useconds_t.max), (now &- pressedAt) / 1_000))
            if elapsedUs < minHoldUs {
                usleep(minHoldUs - elapsedUs)
            }
            self.sendTouch(contact: false, x: x, y: y)
        }
    }

    public func button(_ name: String, state: String) {
        queue.async { [weak self] in
            self?.sendButton(name: name, state: state)
        }
    }

    public func instant(hard: Bool) {
        queue.async { [weak self] in
            self?.sendInstant(hard: hard)
        }
    }

    public func musicSafe(_ on: Bool) {
        queue.async { [weak self] in
            self?.sendMusic(on: on)
        }
    }

    /// Clear the phone's virtual keyboard bitmap (empty HID report).
    public func keyboardReset() {
        queue.async { [weak self] in
            _ = self?.writeAll(Data([0x06]))
        }
    }

    /// Inject a key. Prefer `character` when the Mac layout differs from the
    /// phone's — the engine maps the resolved glyph; `usage` covers specials.
    public func key(down: Bool, usage: UInt16, character: String, mods: UInt8) {
        queue.async { [weak self] in
            self?.sendKey(down: down, usage: usage, character: character, mods: mods)
        }
    }

    private func sendTouch(contact: Bool, x: Int, y: Int) {
        var body = Data(count: 6)
        body[0] = 0x01
        body[1] = contact ? 1 : 0
        body[2] = UInt8(x & 0xff)
        body[3] = UInt8((x >> 8) & 0xff)
        body[4] = UInt8(y & 0xff)
        body[5] = UInt8((y >> 8) & 0xff)
        _ = writeAll(body)
    }

    private func sendButton(name: String, state: String) {
        let utf = Array(name.utf8.prefix(255))
        var body = Data()
        body.append(0x02)
        body.append(UInt8(utf.count))
        body.append(contentsOf: utf)
        body.append(state == "press" ? 1 : 0)
        _ = writeAll(body)
    }

    private func sendInstant(hard: Bool) {
        _ = writeAll(Data([0x03, hard ? 1 : 0]))
    }

    private func sendMusic(on: Bool) {
        _ = writeAll(Data([0x04, on ? 1 : 0]))
    }

    private func sendKey(down: Bool, usage: UInt16, character: String, mods: UInt8) {
        let utf = Array(character.utf8.prefix(255))
        var body = Data()
        body.reserveCapacity(6 + utf.count)
        body.append(0x05)
        body.append(down ? 1 : 0)
        body.append(UInt8(usage & 0xff))
        body.append(UInt8((usage >> 8) & 0xff))
        body.append(mods)
        body.append(UInt8(utf.count))
        body.append(contentsOf: utf)
        _ = writeAll(body)
    }

    @discardableResult
    private func writeAll(_ payload: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard ensureConnected() else { return false }
        var sent = 0
        payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            sent = Darwin.write(fd, base, payload.count)
        }
        if sent != payload.count {
            closeFd()
            return false
        }
        return true
    }

    private func ensureConnected() -> Bool {
        if fd >= 0 { return true }
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        // Avoid blocking forever if the engine is wedged.
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxLen else {
            closeFd()
            return false
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            path.withCString { cstr in
                strncpy(ptr, cstr, maxLen - 1)
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, len) == 0
            }
        }
        if !ok {
            closeFd()
            return false
        }
        return true
    }

    private func closeFd() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    deinit { closeFd() }
}
