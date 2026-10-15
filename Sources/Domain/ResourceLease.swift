public actor ResourceLease {
    public let name: String
    private var isReleased = false
    private let releaseAction: @Sendable () async -> Void

    public init(name: String, releaseAction: @escaping @Sendable () async -> Void) {
        self.name = name
        self.releaseAction = releaseAction
    }

    public func release() async {
        guard !isReleased else { return }
        isReleased = true
        await releaseAction()
    }

    public var released: Bool {
        isReleased
    }
}
