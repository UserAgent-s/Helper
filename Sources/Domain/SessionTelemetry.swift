import Foundation

public enum SpendLimitMode: String, Codable, Sendable, CaseIterable {
    case warnOnly
    case stopSession
}

public struct SpendPolicy: Sendable, Equatable {
    public let limitUSD: Double?
    public let mode: SpendLimitMode

    public init(limitUSD: Double?, mode: SpendLimitMode) {
        self.limitUSD = limitUSD
        self.mode = mode
    }

    public static let none = SpendPolicy(limitUSD: nil, mode: .warnOnly)
}

public enum SpendState: Sendable, Equatable {
    case noLimit
    case belowLimit
    case limitReachedWarning
    case limitReachedStopped
    case unenforceableCostUnknown
}

public enum AnswerPipelineStatus: Sendable, Equatable {
    case idle
    case loadingRecognitionModel
    case listening
    case recognizing
    case waitingForManualTrigger
    case generating
    case providerError(AnswerProviderError)
}

public struct SessionTelemetrySnapshot: Sendable, Equatable {
    public var configuration: AnswerSessionConfiguration?
    public var servedModel: String?
    public var usage: ProviderUsage = ProviderUsage()
    public var responsesWithUsage = 0
    public var responsesWithoutUsage = 0
    public var cost: CostEstimate?
    public var recognitionLatencyMs: [Int] = []
    public var questionToFirstTextMs: [Int] = []
    public var errorCounts: [String: Int] = [:]
    public var lastError: AnswerProviderError?
    public var reconnects = 0
    public var spendPolicy: SpendPolicy = .none
    public var spendState: SpendState = .noLimit
    public var status: AnswerPipelineStatus = .idle
    public var lastHeardText: String?

    public init() {}

    public var usageKnown: Bool {
        responsesWithUsage > 0
    }

    public static func median(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    public static func percentile95(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)
        return sorted[max(0, index)]
    }
}

public actor SessionTelemetry {
    private var state = SessionTelemetrySnapshot()
    private let maxSamples: Int
    private var continuations: [UUID: AsyncStream<SessionTelemetrySnapshot>.Continuation] = [:]

    public init(maxSamples: Int = 100) {
        self.maxSamples = maxSamples
    }

    public func snapshot() -> SessionTelemetrySnapshot {
        state
    }

    public func updates() -> AsyncStream<SessionTelemetrySnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<SessionTelemetrySnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuations[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return stream
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    public func begin(configuration: AnswerSessionConfiguration, spendPolicy: SpendPolicy) {
        var fresh = SessionTelemetrySnapshot()
        fresh.configuration = configuration
        fresh.spendPolicy = spendPolicy
        fresh.spendState = spendPolicy.limitUSD == nil ? .noLimit : .belowLimit
        state = fresh
        publish()
    }

    public func setStatus(_ status: AnswerPipelineStatus) {
        guard state.status != status else { return }
        state.status = status
        publish()
    }

    public func setHeardText(_ text: String?) {
        state.lastHeardText = text
        publish()
    }

    public func setServedModel(_ model: String) {
        state.servedModel = model
        publish()
    }

    @discardableResult
    public func recordUsage(_ usage: ProviderUsage) -> Bool {
        state.usage = state.usage + usage
        state.responsesWithUsage += 1
        recomputeCost()
        publish()
        return state.spendState == .limitReachedStopped
    }

    public func recordResponseWithoutUsage() {
        state.responsesWithoutUsage += 1
        recomputeCost()
        publish()
    }

    public func recordRecognitionLatency(ms: Int) {
        append(ms, to: \.recognitionLatencyMs)
    }

    public func recordQuestionToFirstText(ms: Int) {
        append(ms, to: \.questionToFirstTextMs)
    }

    public func recordReconnect() {
        state.reconnects += 1
        publish()
    }

    public func recordError(_ error: AnswerProviderError) {
        state.errorCounts[error.diagnosticCode, default: 0] += 1
        state.lastError = error
        publish()
    }

    private func append(_ value: Int, to keyPath: WritableKeyPath<SessionTelemetrySnapshot, [Int]>) {
        state[keyPath: keyPath].append(value)
        if state[keyPath: keyPath].count > maxSamples {
            state[keyPath: keyPath].removeFirst(state[keyPath: keyPath].count - maxSamples)
        }
        publish()
    }

    private func recomputeCost() {
        guard let configuration = state.configuration else { return }
        let pricing = AnswerModelCatalog.descriptor(provider: configuration.selection.provider, modelID: state.servedModel ?? configuration.selection.modelID)?.pricing
        state.cost = state.responsesWithoutUsage == 0
            ? UsageCostCalculator.estimate(state.usage, provider: configuration.selection.provider, pricing: pricing)
            : nil
        guard let limit = state.spendPolicy.limitUSD else {
            state.spendState = .noLimit
            return
        }
        guard let cost = state.cost else {
            state.spendState = .unenforceableCostUnknown
            return
        }
        if cost.approximateUSD >= limit {
            state.spendState = state.spendPolicy.mode == .stopSession ? .limitReachedStopped : .limitReachedWarning
        } else {
            state.spendState = .belowLimit
        }
    }

    private func publish() {
        for continuation in continuations.values {
            continuation.yield(state)
        }
    }
}
