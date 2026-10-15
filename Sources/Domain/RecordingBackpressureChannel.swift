public actor RecordingBackpressureChannel {
    public let capacity: Int
    private var buffer: [PCMAudioFrame] = []
    private var waitingConsumer: CheckedContinuation<PCMAudioFrame?, Never>?
    private var finished = false
    private(set) public var droppedFrameCount = 0

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public func send(_ frame: PCMAudioFrame) {
        guard !finished else { return }
        if let waitingConsumer {
            self.waitingConsumer = nil
            waitingConsumer.resume(returning: frame)
            return
        }
        buffer.append(frame)
        if buffer.count > capacity {
            buffer.removeFirst()
            droppedFrameCount += 1
        }
    }

    public func next() async -> PCMAudioFrame? {
        if !buffer.isEmpty {
            return buffer.removeFirst()
        }
        if finished {
            return nil
        }
        return await withCheckedContinuation { continuation in
            waitingConsumer = continuation
        }
    }

    public func finish() {
        finished = true
        waitingConsumer?.resume(returning: nil)
        waitingConsumer = nil
    }

    public var bufferedCount: Int {
        buffer.count
    }
}
