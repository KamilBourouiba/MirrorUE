import Foundation
import Darwin

/// USBMux device discovery via usbmuxd. MirrorUE only mirrors USB-attached phones.
public struct DeviceInfo: Sendable, Equatable {
    public var udid: String
    public var connectionType: String
    public var name: String?
    public var productType: String?
    public var productVersion: String?

    public init(
        udid: String,
        connectionType: String,
        name: String? = nil,
        productType: String? = nil,
        productVersion: String? = nil
    ) {
        self.udid = udid
        self.connectionType = connectionType
        self.name = name
        self.productType = productType
        self.productVersion = productVersion
    }

    public var displayTitle: String {
        let name = name ?? "iPhone"
        let model = productType ?? "unknown"
        return "\(name) (\(model))"
    }
}

public enum DeviceKitError: Error, CustomStringConvertible {
    case usbmuxUnavailable
    case sendFailed
    case recvFailed
    case badResponse(String)
    case noDevice

    public var description: String {
        switch self {
        case .usbmuxUnavailable: return "usbmuxd unavailable (/var/run/usbmuxd)"
        case .sendFailed: return "usbmux send failed"
        case .recvFailed: return "usbmux recv failed"
        case .badResponse(let s): return "usbmux bad response: \(s)"
        case .noDevice: return "no USB-paired iPhone (plug in a cable)"
        }
    }
}

/// Minimal usbmuxd client (plist packets over a UNIX socket).
public enum Usbmux {
    private static let socketPath = "/var/run/usbmuxd"

    public static func listDevices() throws -> [DeviceInfo] {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DeviceKitError.usbmuxUnavailable }
        defer { Darwin.close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                dst.withMemoryRebound(to: CChar.self, capacity: 104) { path in
                    _ = strncpy(path, src, 103)
                }
            }
        }
        let bindOk = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindOk == 0 else { throw DeviceKitError.usbmuxUnavailable }

        let body = try plistXML(["MessageType": "ListDevices"])
        try sendPacket(fd: fd, message: 8, tag: 1, payload: body)
        let resp = try recvPacket(fd: fd)
        guard let root = try? PropertyListSerialization.propertyList(from: resp, options: [], format: nil) as? [String: Any],
              let list = root["DeviceList"] as? [[String: Any]] else {
            throw DeviceKitError.badResponse("no DeviceList")
        }

        var out: [DeviceInfo] = []
        for entry in list {
            guard let props = entry["Properties"] as? [String: Any],
                  let udid = props["SerialNumber"] as? String else { continue }
            let conn: String
            if let n = props["ConnectionType"] as? String {
                conn = n
            } else if let n = props["ConnectionType"] as? Int {
                conn = n == 1 ? "Network" : "USB"
            } else {
                conn = "USB"
            }
            out.append(DeviceInfo(
                udid: udid,
                connectionType: conn,
                name: props["DeviceName"] as? String,
                productType: props["ProductType"] as? String,
                productVersion: props["ProductVersion"] as? String
            ))
        }
        return out
    }

    /// USB-attached phones only (needed for CoreMediaIO screen capture).
    public static func usbDevices() throws -> [DeviceInfo] {
        try listDevices().filter { $0.connectionType == "USB" }
    }

    public static func pick(udid: String? = nil) throws -> DeviceInfo {
        let usb = try usbDevices()
        if let udid {
            if let d = usb.first(where: { $0.udid == udid }) { return d }
            throw DeviceKitError.noDevice
        }
        if let d = usb.first { return d }
        throw DeviceKitError.noDevice
    }

    /// Peer used for the CoreDevice control tunnel.
    /// Prefer Network for the same UDID so USB stays free for the system
    /// screen-capture device (QuickTime / “iPhone Mirroring” DAL).
    public static func controlPeer(for udid: String) throws -> DeviceInfo {
        let all = try listDevices().filter { $0.udid == udid }
        if let net = all.first(where: { $0.connectionType == "Network" }) { return net }
        if let usb = all.first(where: { $0.connectionType == "USB" }) { return usb }
        throw DeviceKitError.noDevice
    }

    private static func plistXML(_ dict: [String: String]) throws -> Data {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        """
        for (k, v) in dict {
            xml += "<key>\(k)</key><string>\(v)</string>"
        }
        xml += "</dict></plist>"
        return Data(xml.utf8)
    }

    private static func sendPacket(fd: Int32, message: UInt32, tag: UInt32, payload: Data) throws {
        var header = Data(count: 16)
        let length = UInt32(16 + payload.count)
        header.withUnsafeMutableBytes { raw in
            guard let p = raw.bindMemory(to: UInt32.self).baseAddress else { return }
            p[0] = length.littleEndian
            p[1] = UInt32(1).littleEndian
            p[2] = message.littleEndian
            p[3] = tag.littleEndian
        }
        try writeAll(fd, header)
        try writeAll(fd, payload)
    }

    private static func recvPacket(fd: Int32) throws -> Data {
        var hdr = [UInt8](repeating: 0, count: 16)
        try readExact(fd, &hdr, 16)
        let length = UInt32(hdr[0]) | (UInt32(hdr[1]) << 8) | (UInt32(hdr[2]) << 16) | (UInt32(hdr[3]) << 24)
        let bodyLen = Int(length) - 16
        guard bodyLen > 0, bodyLen < 16_000_000 else { throw DeviceKitError.badResponse("len \(length)") }
        var body = [UInt8](repeating: 0, count: bodyLen)
        try readExact(fd, &body, bodyLen)
        return Data(body)
    }

    private static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { throw DeviceKitError.sendFailed }
            var off = 0
            let n = data.count
            while off < n {
                let w = Darwin.write(fd, base.advanced(by: off), n - off)
                if w <= 0 { throw DeviceKitError.sendFailed }
                off += w
            }
        }
    }

    private static func readExact(_ fd: Int32, _ buf: inout [UInt8], _ n: Int) throws {
        var off = 0
        while off < n {
            let r = buf.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return Darwin.read(fd, base.advanced(by: off), n - off)
            }
            if r <= 0 { throw DeviceKitError.recvFailed }
            off += r
        }
    }
}
