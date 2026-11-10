import CoreGraphics
import Foundation
import Vision

public struct RecognizedLine: Sendable, Equatable {
    public let text: String
    public let minX: Double
    public let minY: Double
    public let height: Double

    public init(text: String, minX: Double, minY: Double, height: Double) {
        self.text = text
        self.minX = minX
        self.minY = minY
        self.height = height
    }
}

public enum RecognitionMode: Sendable, Equatable {
    case prose
    case code
}

public protocol TextRecognizing: Sendable {
    func recognize(_ image: CGImage, mode: RecognitionMode) async throws -> [RecognizedLine]
}

public struct VisionTextRecognizer: TextRecognizing {
    public static let languages = ["ru-RU", "en-US"]

    public init() {}

    public func recognize(_ image: CGImage, mode: RecognitionMode) async throws -> [RecognizedLine] {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = Self.languages
            request.usesLanguageCorrection = mode == .prose
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try handler.perform([request])
            let observations = request.results ?? []
            let lines = observations.compactMap { observation -> RecognizedLine? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let box = observation.boundingBox
                return RecognizedLine(text: candidate.string, minX: box.minX, minY: box.minY, height: box.height)
            }
            return Self.ordered(lines)
        }.value
    }

    public static func ordered(_ lines: [RecognizedLine]) -> [RecognizedLine] {
        let sorted = lines.sorted { $0.minY + $0.height > $1.minY + $1.height }
        var rows: [[RecognizedLine]] = []
        for line in sorted {
            if let last = rows.last?.first {
                let tolerance = max(last.height, line.height) * 0.5
                if abs((last.minY + last.height / 2) - (line.minY + line.height / 2)) <= tolerance {
                    rows[rows.count - 1].append(line)
                    continue
                }
            }
            rows.append([line])
        }
        return rows.flatMap { $0.sorted { $0.minX < $1.minX } }
    }

    public static func joined(_ lines: [RecognizedLine]) -> String {
        var output: [String] = []
        var previous: RecognizedLine?
        for line in lines {
            if let previous, abs((previous.minY + previous.height / 2) - (line.minY + line.height / 2)) <= max(previous.height, line.height) * 0.5 {
                output[output.count - 1] += " " + line.text
            } else {
                output.append(line.text)
            }
            previous = line
        }
        return output.joined(separator: "\n")
    }
}
