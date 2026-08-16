import VideoToolbox
import CoreMedia
import CoreVideo
import QuartzCore
import Foundation

/// Hardware H.264 encoder for real-time iPhone screen streaming.
///
/// Uses the M1 Pro Media Engine via VideoToolbox. At 120fps with Baseline profile,
/// delta frames average 3-8KB (vs 80KB for JPEG), eliminating TCP bufferbloat.
///
/// Wire format (WebSocket binary frame):
///   Byte 0: 0x01 = keyframe (IDR, includes SPS+PPS), 0x00 = delta (P-frame)
///   Bytes 1…: Annex B encoded H.264 NAL units (00 00 00 01 start codes)
final class H264StreamEncoder {
    static let shared = H264StreamEncoder()

    private var session: VTCompressionSession?
    private var lastWidth: Int32 = 0
    private var lastHeight: Int32 = 0
    private let sessionLock = NSLock()
    private(set) var latestKeyframePacket: Data?
    private var forceNextKeyframe = true
    private var frameCount: Int64 = 0

    func requestKeyframe() {
        sessionLock.lock()
        forceNextKeyframe = true
        sessionLock.unlock()
    }

    fileprivate func setLatestKeyframe(_ packet: Data) {
        sessionLock.lock()
        latestKeyframePacket = packet
        sessionLock.unlock()
    }

    /// Encode a CVPixelBuffer from `present()`. Thread-safe. Fire-and-forget.
    /// VTCompressionSession calls the output handler asynchronously on its own thread.
    func encode(_ pixelBuffer: CVPixelBuffer) {
        let w = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let h = Int32(CVPixelBufferGetHeight(pixelBuffer))

        sessionLock.lock()
        if session == nil || w != lastWidth || h != lastHeight {
            session = makeSession(width: w, height: h)
            lastWidth = w
            lastHeight = h
            frameCount = 0
            forceNextKeyframe = true
        }
        let sess = session
        let fc = frameCount
        frameCount += 1
        let forceKey = forceNextKeyframe || (fc % 120 == 0)
        if forceNextKeyframe { forceNextKeyframe = false }
        sessionLock.unlock()

        guard let sess else { return }

        let pts = CMTime(value: fc, timescale: 120)

        let props: CFDictionary? = forceKey
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil

        VTCompressionSessionEncodeFrame(
            sess,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: props,
            infoFlagsOut: nil
        ) { status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer else { return }
            Self.handleOutput(sampleBuffer)
        }
    }

    // MARK: - Private

    private func makeSession(width: Int32, height: Int32) -> VTCompressionSession? {
        let encoderSpec: CFDictionary = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true as CFBoolean,
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true as CFBoolean,
        ] as CFDictionary

        var sess: VTCompressionSession?
        let err = VTCompressionSessionCreate(
            allocator: nil,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: encoderSpec,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &sess
        )
        guard err == noErr, let sess else {
            fputs("H264StreamEncoder: VTCompressionSessionCreate failed \(err)\n", stderr)
            return nil
        }

        // Realtime low-latency settings
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: 8_000_000 as CFNumber)
        // Keyframe every 0.5s (60 frames at 120fps) for instant sync & fast packet loss recovery
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             value: 60 as CFNumber)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                             value: 0.5 as CFNumber)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: 120 as CFNumber)

        VTCompressionSessionPrepareToEncodeFrames(sess)
        fputs("H264StreamEncoder: session \(width)x\(height) ready (M1 Pro HW Baseline 8Mbps 120fps)\n", stderr)
        return sess
    }

    private static var outFrames: Int = 0
    private static var outBytes: Int = 0
    private static var lastLogTime = CACurrentMediaTime()

    // MARK: - Output handler (called on VT internal thread)

    private static func handleOutput(_ sampleBuffer: CMSampleBuffer) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
        let isKeyframe: Bool
        if let arr = attachments as? [[CFString: Any]], let first = arr.first {
            isKeyframe = first[kCMSampleAttachmentKey_NotSync] == nil
        } else {
            isKeyframe = true
        }

        var annexB = Data()
        let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]

        // Prepend SPS + PPS on keyframes so browser VideoDecoder can configure
        if isKeyframe, let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) {
            var paramCount = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fmt, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &paramCount, nalUnitHeaderLengthOut: nil
            )
            for i in 0 ..< paramCount {
                var ptr: UnsafePointer<UInt8>?
                var len = 0
                let s = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    fmt, parameterSetIndex: i,
                    parameterSetPointerOut: &ptr, parameterSetSizeOut: &len,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
                )
                if s == noErr, let ptr = ptr {
                    annexB.append(contentsOf: startCode)
                    annexB.append(Data(bytes: ptr, count: len))
                }
            }
        }

        // AVCC (length-prefix) -> Annex B (start-code prefix)
        guard let blockBuf = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var totalLen = 0
        var dataPtr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(blockBuf, atOffset: 0,
                                          lengthAtOffsetOut: nil,
                                          totalLengthOut: &totalLen,
                                          dataPointerOut: &dataPtr) == noErr,
              let dataPtr = dataPtr else { return }

        var offset = 0
        while offset + 4 <= totalLen {
            let b0 = UInt32(bitPattern: Int32(dataPtr[offset]))
            let b1 = UInt32(bitPattern: Int32(dataPtr[offset+1]))
            let b2 = UInt32(bitPattern: Int32(dataPtr[offset+2]))
            let b3 = UInt32(bitPattern: Int32(dataPtr[offset+3]))
            let nalLen = Int((b0 << 24) | (b1 << 16) | (b2 << 8) | b3)
            offset += 4
            guard nalLen > 0, offset + nalLen <= totalLen else { break }
            annexB.append(contentsOf: startCode)
            let nalPtr = dataPtr.advanced(by: offset)
            nalPtr.withMemoryRebound(to: UInt8.self, capacity: nalLen) { p in
                annexB.append(p, count: nalLen)
            }
            offset += nalLen
        }

        guard !annexB.isEmpty else { return }

        // 1-byte header: 0x01=keyframe, 0x00=delta
        var packet = Data(capacity: 1 + annexB.count)
        packet.append(isKeyframe ? 0x01 : 0x00)
        packet.append(annexB)

        if isKeyframe {
            H264StreamEncoder.shared.setLatestKeyframe(packet)
        }

        outFrames += 1
        outBytes += packet.count
        let now = CACurrentMediaTime()
        if now - lastLogTime >= 2.0 {
            let fps = Double(outFrames) / (now - lastLogTime)
            let kbps = Double(outBytes * 8) / (now - lastLogTime) / 1000.0
            fputs(String(format: "H264StreamEncoder: %.1f fps, %.0f kbps (M1 Pro HW)\n", fps, kbps), stderr)
            outFrames = 0
            outBytes = 0
            lastLogTime = now
        }

        LocalAPIServer.shared.pushH264Frame(packet)
    }
}
