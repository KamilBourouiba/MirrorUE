import CoreVideo
import Foundation
import ImageIO
import Vision

struct AgentRecognizedText: Sendable {
    let text: String
    let confidence: Float
    /// Normalized top-left-origin rectangle, matching MirrorUE tap coordinates.
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var centerX: Double { min(1, max(0, x + width / 2)) }
    var centerY: Double { min(1, max(0, y + height / 2)) }
}

/// Lightweight local perception for text-only providers and for giving a VLM
/// precise coordinates. Vision runs on the Mac and no screen content leaves
/// the process unless the selected provider profile explicitly enables images.
final class AgentScreenOCR: @unchecked Sendable {
    static let shared = AgentScreenOCR()

    private let lock = NSLock()

    private init() {}

    func recognize(
        _ pixelBuffer: CVPixelBuffer,
        maximumResults: Int = 48
    ) throws -> [AgentRecognizedText] {
        lock.lock()
        defer { lock.unlock() }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.012

        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .up,
            options: [:]
        )
        try handler.perform([request])
        let rows: [AgentRecognizedText] = (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, candidate.confidence >= 0.25 else { return nil }
            let box = observation.boundingBox
            return AgentRecognizedText(
                text: String(text.prefix(160)),
                confidence: candidate.confidence,
                x: min(1, max(0, box.minX)),
                y: min(1, max(0, 1 - box.maxY)),
                width: min(1, max(0, box.width)),
                height: min(1, max(0, box.height))
            )
        }

        return Array(rows.sorted {
            if abs($0.y - $1.y) > 0.02 { return $0.y < $1.y }
            return $0.x < $1.x
        }.prefix(max(1, maximumResults)))
    }

    static func promptText(_ rows: [AgentRecognizedText]) -> String {
        guard !rows.isEmpty else { return "No readable text detected." }
        return rows.enumerated().map { index, row in
            let safe = row.text.replacingOccurrences(of: "\"", with: "'")
            return String(
                format: "%d. \"%@\" center=(%.3f,%.3f) box=(%.3f,%.3f,%.3f,%.3f)",
                index + 1,
                safe,
                row.centerX,
                row.centerY,
                row.x,
                row.y,
                row.width,
                row.height
            )
        }.joined(separator: "\n")
    }
}
