import Foundation

/// Session metadata written by MirrorUEEngine to `/tmp/mirrorue_rsd.json`.
public struct RsdSession: Sendable {
    public let host: String
    public let hidSocketPath: String
    public let videoSocketPath: String

    public static let defaultMetaPath = "/tmp/mirrorue_rsd.json"

    public init(host: String, hidSocketPath: String, videoSocketPath: String) {
        self.host = host
        self.hidSocketPath = hidSocketPath
        self.videoSocketPath = videoSocketPath
    }
}

public enum CoreDeviceBridge {
    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/CoreDevice.framework/CoreDevice"

    /// True when Apple's private CoreDevice.framework is present on this Mac.
    public static var isFrameworkAvailable: Bool {
        FileManager.default.isReadableFile(atPath: frameworkPath)
    }

    /// Load RSD metadata published after DisplayService comes up.
    public static func loadSession(path: String = RsdSession.defaultMetaPath) -> RsdSession? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let host = obj["host"] as? String else { return nil }
        return RsdSession(
            host: host,
            hidSocketPath: (obj["hid_socket"] as? String) ?? "/tmp/mirrorue_hid.sock",
            videoSocketPath: (obj["video_socket"] as? String) ?? "/tmp/mirrorue_video.sock"
        )
    }

    /// Poll until the engine publishes RSD metadata.
    public static func waitForSession(
        path: String = RsdSession.defaultMetaPath,
        timeout: TimeInterval = 60
    ) async -> RsdSession? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let s = loadSession(path: path) { return s }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return nil
    }
}
