import AVFoundation
import AppKit
import CoreVideo
import Foundation

/// Screenshot + screen recording from live CVPixelBuffers.
final class CaptureStudio {
    static let shared = CaptureStudio()

    private let queue = DispatchQueue(label: "mirrorue.capture-studio", qos: .userInitiated)
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var frameIndex: Int64 = 0
    private var recordingURL: URL?
    private(set) var isRecording = false

    private init() {}

    /// Save a PNG of the current frame to ~/Desktop (or Pictures).
    @discardableResult
    func saveScreenshot(_ pixelBuffer: CVPixelBuffer?) -> URL? {
        let dir = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("MirrorUE-\(Self.stamp()).png")
        return writePNG(pixelBuffer, to: url) ? url : nil
    }

    /// Write a PNG for the FastVLM agent (no Screen Recording needed).
    @discardableResult
    func writePNG(_ pixelBuffer: CVPixelBuffer?, to url: URL) -> Bool {
        writeFrame(pixelBuffer, to: url, maxWidth: 0, format: "png")
    }

    /// Export a phone frame for the agent. JPEG + maxWidth keeps VLM fast.
    @discardableResult
    func writeFrame(
        _ pixelBuffer: CVPixelBuffer?,
        to url: URL,
        maxWidth: Int = 720,
        format: String = "jpg",
        jpegQuality: CGFloat = 0.7
    ) -> Bool {
        guard let pixelBuffer else { return false }
        var ci = CIImage(cvPixelBuffer: pixelBuffer)
        let w = ci.extent.width
        if maxWidth > 0, w > CGFloat(maxWidth) {
            let scale = CGFloat(maxWidth) / w
            ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let rep = NSCIImageRep(ciImage: ci)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return false }

        let fmt = format.lowercased()
        let data: Data?
        if fmt == "jpg" || fmt == "jpeg" {
            data = bitmap.representation(
                using: .jpeg,
                properties: [.compressionFactor: jpegQuality]
            )
        } else {
            data = bitmap.representation(using: .png, properties: [:])
        }
        guard let data, !data.isEmpty else { return false }
        do {
            try data.write(to: url)
            return true
        } catch {
            fputs("CaptureStudio writeFrame failed: \(error)\n", stderr)
            return false
        }
    }

    func startRecording(size: CGSize) throws {
        guard !isRecording else { return }
        let dir = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("MirrorUE-\(Self.stamp()).mov")
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            ]
        )
        guard writer.canAdd(input) else { throw CaptureStudioError.cannotAddInput }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? CaptureStudioError.cannotStart
        }
        writer.startSession(atSourceTime: .zero)

        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        self.recordingURL = url
        self.frameIndex = 0
        self.isRecording = true
        fputs("CaptureStudio: recording → \(url.path)\n", stderr)
    }

    func appendFrame(_ pixelBuffer: CVPixelBuffer) {
        guard isRecording, let input, let adaptor, input.isReadyForMoreMediaData else { return }
        let fps: Int32 = 60
        let time = CMTime(value: frameIndex, timescale: fps)
        frameIndex += 1
        queue.async {
            _ = adaptor.append(pixelBuffer, withPresentationTime: time)
        }
    }

    func stopRecording(completion: @escaping (URL?) -> Void) {
        guard isRecording, let writer, let input else {
            completion(nil)
            return
        }
        isRecording = false
        queue.async {
            input.markAsFinished()
            writer.finishWriting {
                let url = writer.status == .completed ? self.recordingURL : nil
                if writer.status != .completed {
                    fputs("CaptureStudio: finish failed \(String(describing: writer.error))\n", stderr)
                }
                DispatchQueue.main.async {
                    self.writer = nil
                    self.input = nil
                    self.adaptor = nil
                    completion(url)
                }
            }
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}

enum CaptureStudioError: Error {
    case cannotAddInput
    case cannotStart
}
