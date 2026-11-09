import Foundation

public struct EchoSuppressorConfiguration: Sendable, Equatable {
    public var gateDBFS: Float
    public var gateHangover: TimeInterval
    public var dedupWindow: TimeInterval
    public var jaccardThreshold: Double

    public init(
        gateDBFS: Float = -40,
        gateHangover: TimeInterval = 0.3,
        dedupWindow: TimeInterval = 5,
        jaccardThreshold: Double = 0.6
    ) {
        self.gateDBFS = gateDBFS
        self.gateHangover = gateHangover
        self.dedupWindow = dedupWindow
        self.jaccardThreshold = jaccardThreshold
    }
}

public struct EchoSuppressor: Sendable {
    public let configuration: EchoSuppressorConfiguration

    private var lastLoudSystemAt: Date?
    private var remote: [String: (tokens: Set<String>, at: Date)] = [:]

    public init(configuration: EchoSuppressorConfiguration = EchoSuppressorConfiguration()) {
        self.configuration = configuration
    }

    public mutating func reset() {
        lastLoudSystemAt = nil
        remote.removeAll()
    }

    public mutating func noteSystemLevel(_ rmsDBFS: Float, at date: Date) {
        guard rmsDBFS >= configuration.gateDBFS else { return }
        if let last = lastLoudSystemAt, last > date { return }
        lastLoudSystemAt = date
    }

    public func allowsOpening(at date: Date) -> Bool {
        guard let lastLoudSystemAt else { return true }
        return date.timeIntervalSince(lastLoudSystemAt) > configuration.gateHangover
    }

    public mutating func noteRemoteTranscript(itemID: String, text: String, at date: Date) {
        let tokens = Self.tokens(text)
        guard !tokens.isEmpty else { return }
        remote[itemID] = (tokens, date)
        prune(now: date)
    }

    public func isEchoDuplicate(_ text: String, at date: Date) -> Bool {
        let tokens = Self.tokens(text)
        guard !tokens.isEmpty else { return false }
        return remote.values.contains {
            abs(date.timeIntervalSince($0.at)) <= configuration.dedupWindow
                && Self.jaccard(tokens, $0.tokens) >= configuration.jaccardThreshold
        }
    }

    private mutating func prune(now: Date) {
        remote = remote.filter { now.timeIntervalSince($0.value.at) <= configuration.dedupWindow }
    }

    public static func tokens(_ text: String) -> Set<String> {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "ё", with: "е")
        let words = folded.split { !$0.isLetter && !$0.isNumber }
        return Set(words.map(String.init))
    }

    public static func jaccard(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        let union = lhs.union(rhs).count
        guard union > 0 else { return 0 }
        return Double(lhs.intersection(rhs).count) / Double(union)
    }
}
