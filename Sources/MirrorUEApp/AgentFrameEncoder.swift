import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO

/// Converts live phone frames into compact, model-ready JPEG data without
/// passing through AppKit or the filesystem.
///
/// The shared `CIContext` avoids rebuilding Core Image's render pipeline for
/// every agent turn. Access is serialized so callers may safely use one encoder
/// from capture, agent, and API queues.
final class AgentFrameEncoder: @unchecked Sendable {
    static let shared = AgentFrameEncoder()

    struct PixelSize: Hashable, Sendable {
        let width: Int
        let height: Int
    }

    struct Configuration: Sendable {
        /// Set either dimension to zero to leave that axis unconstrained.
        var maximumWidth: Int
        var maximumHeight: Int
        var jpegQuality: Double

        init(
            maximumWidth: Int = 720,
            maximumHeight: Int = 1_280,
            jpegQuality: Double = 0.68
        ) {
            self.maximumWidth = maximumWidth
            self.maximumHeight = maximumHeight
            self.jpegQuality = jpegQuality
        }
    }

    struct Fingerprint: Equatable, Sendable {
        let sourceSize: PixelSize

        /// Difference hash of a 9x8 luminance thumbnail. Similar frames have
        /// few differing bits, making this useful for screen-settle polling.
        let perceptualHash: UInt64

        /// FNV-1a over five-bit luminance samples. This is an inexpensive exact
        /// equality check after quantization, not a similarity metric.
        let quantizedSampleHash: UInt64
        let averageLuma: UInt8

        func hammingDistance(to other: Fingerprint) -> Int {
            guard sourceSize == other.sourceSize else { return 64 }
            return (perceptualHash ^ other.perceptualHash).nonzeroBitCount
        }

        /// A normalized visual-change estimate in `0...1`.
        ///
        /// The score is intentionally conservative: a substantial global
        /// brightness change still registers even when edge structure is stable.
        func changeScore(comparedTo other: Fingerprint) -> Double {
            guard sourceSize == other.sourceSize else { return 1 }
            let structure = Double(hammingDistance(to: other)) / 64
            let brightness = Double(abs(Int(averageLuma) - Int(other.averageLuma))) / 255
            return max(structure, brightness)
        }

        func isVisuallySimilar(
            to other: Fingerprint,
            maximumHashBitChanges: Int = 3,
            maximumAverageLumaDelta: Int = 3
        ) -> Bool {
            guard sourceSize == other.sourceSize else { return false }
            return hammingDistance(to: other) <= max(0, maximumHashBitChanges)
                && abs(Int(averageLuma) - Int(other.averageLuma))
                    <= max(0, maximumAverageLumaDelta)
        }

        func isQuantizedMatch(to other: Fingerprint) -> Bool {
            sourceSize == other.sourceSize
                && quantizedSampleHash == other.quantizedSampleHash
        }
    }

    struct EncodedFrame: Sendable {
        let jpegData: Data
        let sourceSize: PixelSize
        let encodedSize: PixelSize
        let fingerprint: Fingerprint
    }

    private static let fingerprintWidth = 9
    private static let fingerprintHeight = 8
    private static let fnvOffsetBasis: UInt64 = 14_695_981_039_346_656_037
    private static let fnvPrime: UInt64 = 1_099_511_628_211

    private let context: CIContext
    private let renderLock = NSLock()
    private let rgbColorSpace: CGColorSpace
    private let grayColorSpace: CGColorSpace

    init() {
        context = CIContext(options: [.cacheIntermediates: false])
        rgbColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        grayColorSpace = CGColorSpace(name: CGColorSpace.linearGray)!
    }

    /// Produces a downscaled JPEG and fingerprint entirely in memory.
    ///
    /// This method is synchronous; call it from a utility or agent queue rather
    /// than the main actor.
    func encode(
        _ pixelBuffer: CVPixelBuffer,
        configuration: Configuration = Configuration()
    ) throws -> EncodedFrame {
        renderLock.lock()
        defer { renderLock.unlock() }

        return try autoreleasepool {
            let source = try makeSourceImage(from: pixelBuffer)
            let sourceSize = Self.pixelSize(of: pixelBuffer)
            let encodedSize = Self.scaledSize(
                sourceSize,
                maximumWidth: configuration.maximumWidth,
                maximumHeight: configuration.maximumHeight
            )
            let output = Self.resize(source, from: sourceSize, to: encodedSize)
            let quality = min(1, max(0, configuration.jpegQuality))
            let qualityKey = CIImageRepresentationOption(
                rawValue: kCGImageDestinationLossyCompressionQuality as String
            )
            guard let jpegData = context.jpegRepresentation(
                of: output,
                colorSpace: rgbColorSpace,
                options: [qualityKey: quality]
            ), !jpegData.isEmpty else {
                throw AgentFrameEncodingError.jpegEncodingFailed
            }

            return EncodedFrame(
                jpegData: jpegData,
                sourceSize: sourceSize,
                encodedSize: encodedSize,
                fingerprint: makeFingerprint(source, sourceSize: sourceSize)
            )
        }
    }

    /// Renders only a tiny 9x8 luminance image. Use this while waiting for the
    /// phone screen to change or settle after an action.
    func fingerprint(_ pixelBuffer: CVPixelBuffer) throws -> Fingerprint {
        renderLock.lock()
        defer { renderLock.unlock() }

        return try autoreleasepool {
            let source = try makeSourceImage(from: pixelBuffer)
            return makeFingerprint(source, sourceSize: Self.pixelSize(of: pixelBuffer))
        }
    }

    private func makeSourceImage(from pixelBuffer: CVPixelBuffer) throws -> CIImage {
        let size = Self.pixelSize(of: pixelBuffer)
        guard size.width > 0, size.height > 0 else {
            throw AgentFrameEncodingError.invalidPixelBufferSize(
                width: size.width,
                height: size.height
            )
        }

        let raw = CIImage(cvPixelBuffer: pixelBuffer)
        guard raw.extent.origin.x.isFinite,
              raw.extent.origin.y.isFinite,
              raw.extent.width.isFinite,
              raw.extent.height.isFinite,
              !raw.extent.isEmpty else {
            throw AgentFrameEncodingError.invalidImageExtent
        }

        // Pixel-buffer images normally begin at (0, 0), but normalizing the
        // extent makes resize bounds deterministic for every CIImage producer.
        return raw
            .transformed(
                by: CGAffineTransform(
                    translationX: -raw.extent.minX,
                    y: -raw.extent.minY
                )
            )
            .cropped(
                to: CGRect(x: 0, y: 0, width: size.width, height: size.height)
            )
    }

    private func makeFingerprint(
        _ source: CIImage,
        sourceSize: PixelSize
    ) -> Fingerprint {
        let sampleSize = PixelSize(
            width: Self.fingerprintWidth,
            height: Self.fingerprintHeight
        )
        let thumbnail = Self.resize(source, from: sourceSize, to: sampleSize)
        var samples = [UInt8](
            repeating: 0,
            count: Self.fingerprintWidth * Self.fingerprintHeight
        )

        samples.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            context.render(
                thumbnail,
                toBitmap: baseAddress,
                rowBytes: Self.fingerprintWidth,
                bounds: CGRect(
                    x: 0,
                    y: 0,
                    width: Self.fingerprintWidth,
                    height: Self.fingerprintHeight
                ),
                format: .L8,
                colorSpace: grayColorSpace
            )
        }

        var perceptualHash: UInt64 = 0
        for row in 0..<Self.fingerprintHeight {
            let rowStart = row * Self.fingerprintWidth
            for column in 0..<(Self.fingerprintWidth - 1) {
                perceptualHash <<= 1
                if samples[rowStart + column] > samples[rowStart + column + 1] {
                    perceptualHash |= 1
                }
            }
        }

        var sampleHash = Self.fnvOffsetBasis
        var lumaTotal: UInt32 = 0
        for sample in samples {
            lumaTotal += UInt32(sample)
            sampleHash ^= UInt64(sample >> 3)
            sampleHash &*= Self.fnvPrime
        }
        let roundedMean = (
            lumaTotal + UInt32(samples.count / 2)
        ) / UInt32(samples.count)

        return Fingerprint(
            sourceSize: sourceSize,
            perceptualHash: perceptualHash,
            quantizedSampleHash: sampleHash,
            averageLuma: UInt8(roundedMean)
        )
    }

    private static func pixelSize(of pixelBuffer: CVPixelBuffer) -> PixelSize {
        PixelSize(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
    }

    private static func scaledSize(
        _ source: PixelSize,
        maximumWidth: Int,
        maximumHeight: Int
    ) -> PixelSize {
        let widthScale = maximumWidth > 0
            ? Double(maximumWidth) / Double(source.width)
            : 1
        let heightScale = maximumHeight > 0
            ? Double(maximumHeight) / Double(source.height)
            : 1
        let scale = min(1, widthScale, heightScale)
        return PixelSize(
            width: max(1, Int((Double(source.width) * scale).rounded())),
            height: max(1, Int((Double(source.height) * scale).rounded()))
        )
    }

    private static func resize(
        _ image: CIImage,
        from source: PixelSize,
        to destination: PixelSize
    ) -> CIImage {
        guard source != destination else { return image }
        let scaleX = CGFloat(destination.width) / CGFloat(source.width)
        let scaleY = CGFloat(destination.height) / CGFloat(source.height)
        return image
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .cropped(
                to: CGRect(
                    x: 0,
                    y: 0,
                    width: destination.width,
                    height: destination.height
                )
            )
    }
}

enum AgentFrameEncodingError: LocalizedError {
    case invalidPixelBufferSize(width: Int, height: Int)
    case invalidImageExtent
    case jpegEncodingFailed

    var errorDescription: String? {
        switch self {
        case let .invalidPixelBufferSize(width, height):
            return "Invalid phone frame size: \(width)x\(height)."
        case .invalidImageExtent:
            return "The phone frame has an invalid Core Image extent."
        case .jpegEncodingFailed:
            return "Core Image could not encode the phone frame as JPEG."
        }
    }
}
