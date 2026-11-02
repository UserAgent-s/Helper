import CoreServices
import Foundation

final class KnowledgeFolderWatcher: @unchecked Sendable {
    private let directory: URL
    private let queue = DispatchQueue(label: "com.local.MeetingAssistant.knowledge-folder")
    private let debounce: TimeInterval
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    private var onChange: (@Sendable () -> Void)?

    init(directory: URL, debounce: TimeInterval = 1.0) {
        self.directory = directory
        self.debounce = debounce
    }

    func start(onChange: @escaping @Sendable () -> Void) {
        queue.sync {
            guard stream == nil else { return }
            self.onChange = onChange
            var context = FSEventStreamContext()
            context.info = Unmanaged.passUnretained(self).toOpaque()
            let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
                guard let info else { return }
                Unmanaged<KnowledgeFolderWatcher>.fromOpaque(info).takeUnretainedValue().scheduleChange()
            }
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
            guard let created = FSEventStreamCreate(nil, callback, &context, [directory.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { return }
            FSEventStreamSetDispatchQueue(created, queue)
            FSEventStreamStart(created)
            stream = created
        }
    }

    func stop() {
        queue.sync {
            pending?.cancel()
            pending = nil
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    private func scheduleChange() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.onChange?()
        }
        pending = item
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
