import Foundation

public enum ProfileTokenEstimator {
    public static func estimate(_ text: String) -> Int {
        var ascii = 0
        var other = 0
        for scalar in text.unicodeScalars {
            if scalar.isASCII { ascii += 1 } else { other += 1 }
        }
        return Int((Double(ascii) / 4.0 + Double(other) / 2.0).rounded(.up))
    }

    public static func estimate(_ documents: [String]) -> Int {
        documents.reduce(0) { $0 + estimate($1) }
    }
}
