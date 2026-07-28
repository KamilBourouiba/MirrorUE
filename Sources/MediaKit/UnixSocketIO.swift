import Foundation
import Darwin

/// Unix domain socket primitives, including SCM_RIGHTS descriptor passing.
///
/// Darwin exposes CMSG_SPACE / CMSG_LEN / CMSG_DATA as C macros, which Swift
/// cannot import, so the (simple) alignment arithmetic is reproduced here.
enum UnixSocketIO {
    /// Darwin aligns control message components on 4 bytes (__DARWIN_ALIGN32).
    @inline(__always) static func cmsgAlign(_ n: Int) -> Int { (n + 3) & ~3 }
    @inline(__always) static var cmsgHeaderLength: Int { cmsgAlign(MemoryLayout<cmsghdr>.size) }
    @inline(__always) static func cmsgSpace(_ payload: Int) -> Int {
        cmsgHeaderLength + cmsgAlign(payload)
    }
    @inline(__always) static func cmsgLength(_ payload: Int) -> Int {
        cmsgHeaderLength + payload
    }

    static func connect(path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < capacity else {
            Darwin.close(fd)
            return -1
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                _ = path.withCString { strncpy(dst, $0, capacity - 1) }
            }
        }

        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, length) == 0
            }
        }
        if !connected {
            Darwin.close(fd)
            return -1
        }
        return fd
    }

    static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress?.advanced(by: sent) else { return -1 }
                return Darwin.write(fd, base, bytes.count - sent)
            }
            if n <= 0 {
                if n < 0 && errno == EINTR { continue }
                return false
            }
            sent += n
        }
        return true
    }

    static func readAll(_ fd: Int32, into buffer: inout [UInt8], offset: Int, count: Int) -> Bool {
        var got = 0
        while got < count {
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress?.advanced(by: offset + got) else { return -1 }
                return Darwin.read(fd, base, count - got)
            }
            if n <= 0 {
                if n < 0 && errno == EINTR { continue }
                return false
            }
            got += n
        }
        return true
    }

    /// Read one byte, collecting any descriptor the peer attached to that segment.
    /// Returns nil on EOF or error.
    static func readByteWithDescriptor(_ fd: Int32) -> (byte: UInt8, descriptor: Int32?)? {
        var scratch: UInt8 = 0
        var received: Int32?
        var result: Int = -1

        withUnsafeMutablePointer(to: &scratch) { bytePtr in
            var io = iovec(iov_base: UnsafeMutableRawPointer(bytePtr), iov_len: 1)
            let controlSize = cmsgSpace(MemoryLayout<Int32>.size)
            var control = [UInt8](repeating: 0, count: controlSize)

            withUnsafeMutablePointer(to: &io) { ioPtr in
                control.withUnsafeMutableBytes { controlBuffer in
                    var message = msghdr()
                    message.msg_name = nil
                    message.msg_namelen = 0
                    message.msg_iov = ioPtr
                    message.msg_iovlen = 1
                    message.msg_control = controlBuffer.baseAddress
                    message.msg_controllen = socklen_t(controlSize)
                    message.msg_flags = 0

                    repeat {
                        result = recvmsg(fd, &message, 0)
                    } while result < 0 && errno == EINTR

                    guard result > 0,
                          message.msg_controllen >= socklen_t(cmsgLength(MemoryLayout<Int32>.size)),
                          let controlBase = controlBuffer.baseAddress else { return }

                    let header = controlBase.assumingMemoryBound(to: cmsghdr.self).pointee
                    guard header.cmsg_level == SOL_SOCKET, header.cmsg_type == SCM_RIGHTS else { return }
                    received = controlBase
                        .advanced(by: cmsgHeaderLength)
                        .assumingMemoryBound(to: Int32.self)
                        .pointee
                }
            }
        }

        guard result > 0 else { return nil }
        return (scratch, received)
    }
}
