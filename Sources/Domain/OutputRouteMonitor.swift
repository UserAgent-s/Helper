public actor OutputRouteMonitor {
    private let catalog: any AudioDeviceCataloging
    private let routes: AsyncBroadcaster<OutputRoute>
    private let notices: AsyncBroadcaster<CaptureNotice>?
    private let debounce: Duration

    private var listenTask: Task<Void, Never>?
    private var pendingTask: Task<Void, Never>?
    public private(set) var current: OutputRoute = .unknown

    public init(
        catalog: any AudioDeviceCataloging,
        routes: AsyncBroadcaster<OutputRoute>,
        notices: AsyncBroadcaster<CaptureNotice>? = nil,
        debounce: Duration = .milliseconds(300)
    ) {
        self.catalog = catalog
        self.routes = routes
        self.notices = notices
        self.debounce = debounce
    }

    public var isRunning: Bool {
        listenTask != nil
    }

    public func start() {
        guard listenTask == nil else { return }
        current = OutputRouteClassifier.classify(catalog.defaultOutputDevice())
        routes.yield(current)
        let changes = catalog.changes()
        listenTask = Task { [weak self] in
            for await change in changes {
                if Task.isCancelled { break }
                await self?.handle(change)
            }
        }
    }

    public func stop() {
        listenTask?.cancel()
        listenTask = nil
        pendingTask?.cancel()
        pendingTask = nil
    }

    private func handle(_ change: AudioDeviceChange) {
        switch change {
        case .defaultOutputChanged, .outputDataSourceChanged, .deviceListChanged:
            break
        case .defaultInputChanged, .microphoneEngineReconfigured:
            return
        }
        pendingTask?.cancel()
        let debounce = self.debounce
        pendingTask = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self?.reclassify()
        }
    }

    private func reclassify() {
        guard listenTask != nil else { return }
        let route = OutputRouteClassifier.classify(catalog.defaultOutputDevice())
        guard route != current else { return }
        current = route
        routes.yield(route)
        notices?.yield(.outputRouteChanged(route))
    }
}
