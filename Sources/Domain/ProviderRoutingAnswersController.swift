import Foundation

public protocol AnswerSessionControlling: Sendable {
    func streamEvents() -> AsyncStream<AnswerStreamEvent>
    func resetContext() async
}

public struct ProviderRoute: Sendable {
    public let preflight: @Sendable () throws -> Void
    public let start: @Sendable () async throws -> Void
    public let stop: @Sendable () async -> Void
    public let resetContext: @Sendable () async -> Void
    public let streamEvents: AsyncStream<AnswerStreamEvent>
    public let failures: AsyncStream<String>

    public init(
        preflight: @escaping @Sendable () throws -> Void = {},
        start: @escaping @Sendable () async throws -> Void,
        stop: @escaping @Sendable () async -> Void,
        resetContext: @escaping @Sendable () async -> Void,
        streamEvents: AsyncStream<AnswerStreamEvent>,
        failures: AsyncStream<String>
    ) {
        self.preflight = preflight
        self.start = start
        self.stop = stop
        self.resetContext = resetContext
        self.streamEvents = streamEvents
        self.failures = failures
    }

    public static func openAI(_ controller: AnswersModeController) -> ProviderRoute {
        ProviderRoute(
            start: { try await controller.start() },
            stop: { await controller.stop() },
            resetContext: {
                await controller.stop()
                try? await controller.start()
            },
            streamEvents: controller.streamEvents(),
            failures: controller.failures()
        )
    }

    public static func transcribed(_ controller: TranscribedAnswersModeController, preflight: @escaping @Sendable () throws -> Void = {}) -> ProviderRoute {
        ProviderRoute(
            preflight: preflight,
            start: { try await controller.start() },
            stop: { await controller.stop() },
            resetContext: { await controller.resetContext() },
            streamEvents: controller.streamEvents(),
            failures: controller.failures()
        )
    }
}

public actor ProviderRoutingAnswersController: ModeController, AnswerSessionControlling {
    private let routes: [AnswerProvider: ProviderRoute]
    private let configurationProvider: @Sendable () -> AnswerSessionConfiguration
    private let spendPolicyProvider: @Sendable () -> SpendPolicy
    private let prepare: @Sendable () async -> Void
    private let telemetry: SessionTelemetry

    private var activeProvider: AnswerProvider?
    private(set) public var activeConfiguration: AnswerSessionConfiguration?
    private var forwardingTasks: [Task<Void, Never>] = []
    private(set) public var startedProviders: [AnswerProvider] = []

    private let failureStream: AsyncStream<String>
    private let failureContinuation: AsyncStream<String>.Continuation
    private let streamEventBroadcaster = EventBroadcaster<AnswerStreamEvent>()

    public init(
        routes: [AnswerProvider: ProviderRoute],
        configurationProvider: @escaping @Sendable () -> AnswerSessionConfiguration,
        spendPolicyProvider: @escaping @Sendable () -> SpendPolicy = { .none },
        prepare: @escaping @Sendable () async -> Void = {},
        telemetry: SessionTelemetry
    ) {
        self.routes = routes
        self.configurationProvider = configurationProvider
        self.spendPolicyProvider = spendPolicyProvider
        self.prepare = prepare
        self.telemetry = telemetry
        (failureStream, failureContinuation) = AsyncStream<String>.makeStream()
    }

    nonisolated public func failures() -> AsyncStream<String> {
        failureStream
    }

    nonisolated public func streamEvents() -> AsyncStream<AnswerStreamEvent> {
        streamEventBroadcaster.subscribe()
    }

    public var currentProvider: AnswerProvider? {
        activeProvider
    }

    private func startForwardingIfNeeded() {
        guard forwardingTasks.isEmpty else { return }
        for (provider, route) in routes {
            forwardingTasks.append(Task { [weak self] in
                for await event in route.streamEvents {
                    await self?.forward(event, from: provider)
                }
            })
            forwardingTasks.append(Task { [weak self] in
                for await reason in route.failures {
                    await self?.forwardFailure(reason, from: provider)
                }
            })
        }
    }

    public func start() async throws {
        startForwardingIfNeeded()
        await prepare()
        let configuration = configurationProvider()
        guard let route = routes[configuration.selection.provider] else {
            throw AnswerProviderError.unknown("no_route_for_\(configuration.selection.provider.rawValue)")
        }
        await telemetry.begin(configuration: configuration, spendPolicy: spendPolicyProvider())
        activeConfiguration = configuration
        activeProvider = configuration.selection.provider
        startedProviders.append(configuration.selection.provider)
        do {
            try route.preflight()
            try await route.start()
        } catch {
            activeProvider = nil
            if let providerError = error as? AnswerProviderError {
                await telemetry.recordError(providerError)
            }
            throw error
        }
    }

    public func stop() async {
        let provider = activeProvider
        activeProvider = nil
        if let provider, let route = routes[provider] {
            await route.stop()
        } else {
            for route in routes.values { await route.stop() }
        }
        await telemetry.setStatus(.idle)
    }

    public func resetContext() async {
        guard let provider = activeProvider, let route = routes[provider] else { return }
        await route.resetContext()
    }

    private func forward(_ event: AnswerStreamEvent, from provider: AnswerProvider) {
        guard provider == activeProvider else { return }
        streamEventBroadcaster.yield(event)
    }

    private func forwardFailure(_ reason: String, from provider: AnswerProvider) {
        guard provider == activeProvider else { return }
        failureContinuation.yield(reason)
    }
}
