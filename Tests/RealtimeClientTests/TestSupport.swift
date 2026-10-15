import Domain
@testable import RealtimeClient

struct FakeCredentialProvidingError: Error, Sendable, Equatable {}

final class FakeCredentialProviding: RealtimeCredentialProviding, @unchecked Sendable {
    var apiKey: String?

    init(apiKey: String? = "test-api-key") {
        self.apiKey = apiKey
    }

    func currentCredential() async throws -> RealtimeCredential {
        guard let apiKey, !apiKey.isEmpty else { throw FakeCredentialProvidingError() }
        return RealtimeCredential(apiKey: apiKey)
    }
}

actor RecordingLatencyRecorder: LatencyRecording {
    private(set) var metrics: [LatencyMetric] = []

    func record(_ metric: LatencyMetric) async {
        metrics.append(metric)
    }
}

actor LogCollector {
    private(set) var lines: [String] = []

    func append(_ line: String) {
        lines.append(line)
    }
}
