import CoreAudio
import Domain
import Foundation

enum TapDescriptionBuilder {
    static func processObjectIDs(forBundlePrefix prefix: String, processes: [(objectID: AudioObjectID, bundleID: String?)]) -> [AudioObjectID] {
        let helperPrefix = prefix + "."
        return processes.compactMap { process in
            guard let bundleID = process.bundleID, bundleID == prefix || bundleID.hasPrefix(helperPrefix) else { return nil }
            return process.objectID
        }
    }

    static func excludedObjectIDs(
        exclusions: [String],
        ownObjectID: AudioObjectID?,
        processes: [(objectID: AudioObjectID, bundleID: String?)]
    ) -> [AudioObjectID] {
        var ids = exclusions.flatMap { processObjectIDs(forBundlePrefix: $0, processes: processes) }
        if let ownObjectID, !ids.contains(ownObjectID) {
            ids.append(ownObjectID)
        }
        return ids
    }

    static func ownProcessObjectID() -> AudioObjectID? {
        var pid = getpid()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &objectID
        )
        guard status == noErr, objectID != kAudioObjectUnknown else { return nil }
        return objectID
    }

    static func audioProcesses() -> [(objectID: AudioObjectID, bundleID: String?)] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map { id in
            var bundleAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyBundleID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var value: Unmanaged<CFString>?
            var valueSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let status = AudioObjectGetPropertyData(id, &bundleAddress, 0, nil, &valueSize, &value)
            let bundleID = status == noErr ? value?.takeRetainedValue() as String? : nil
            return (id, bundleID)
        }
    }
}

@available(macOS 14.2, *)
public final class CoreAudioTapSystemAudioCapturing: SystemAudioCapturing, @unchecked Sendable {
    private let catalog: any AudioDeviceCataloging
    private let ioQueue = DispatchQueue(label: "com.local.UserAgent057.audiocapture.tap", qos: .userInteractive)
    private let stateLock = NSLock()

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var continuation: AsyncStream<PCMAudioFrame>.Continuation?
    private var converter = RealtimeAudioFormatConverter()

    public init(catalog: any AudioDeviceCataloging) {
        self.catalog = catalog
    }

    public func start(scope: SystemAudioScope) async throws -> SystemAudioCaptureStart {
        let processes = TapDescriptionBuilder.audioProcesses()
        let own = TapDescriptionBuilder.ownProcessObjectID()
        var effectiveScope = scope
        var notice: CaptureNotice?
        let description: CATapDescription
        switch scope {
        case .wholeSystem(let exclusions):
            let excluded = TapDescriptionBuilder.excludedObjectIDs(exclusions: exclusions, ownObjectID: own, processes: processes)
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        case .application(let bundleID, let fallbackToWholeSystem):
            let included = TapDescriptionBuilder.processObjectIDs(forBundlePrefix: bundleID, processes: processes)
            if !included.isEmpty {
                description = CATapDescription(stereoMixdownOfProcesses: included)
            } else if fallbackToWholeSystem {
                let excluded = TapDescriptionBuilder.excludedObjectIDs(exclusions: [], ownObjectID: own, processes: processes)
                description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
                effectiveScope = .defaultScope
                notice = .fellBackToWholeSystem(missingBundleID: bundleID)
            } else {
                throw AudioCaptureError.targetApplicationNotFound(bundleID)
            }
        }
        return try await startTap(description, effectiveScope: effectiveScope, notice: notice)
    }

    func startTap(_ description: CATapDescription, effectiveScope: SystemAudioScope, notice: CaptureNotice?) async throws -> SystemAudioCaptureStart {
        description.name = "UserAgent057 system audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &newTapID), "create tap")
        stateLock.withLock { tapID = newTapID }
        do {
            let frames = try startAggregate(tapID: newTapID, tapUID: description.uuid.uuidString)
            return SystemAudioCaptureStart(frames: frames, effectiveScope: effectiveScope, notice: notice)
        } catch {
            await stop()
            throw error
        }
    }

    private func startAggregate(tapID newTapID: AudioObjectID, tapUID: String) throws -> AsyncStream<PCMAudioFrame> {
        var composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "UserAgent057 Tap",
            kAudioAggregateDeviceUIDKey: "com.local.UserAgent057.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]],
        ]
        if let outputUID = catalog.defaultOutputDevice()?.uid {
            composition[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            composition[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
        }
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &newAggregateID), "create aggregate")
        stateLock.lock()
        aggregateID = newAggregateID
        stateLock.unlock()

        let format = try tapFormat(newTapID)
        let sampleRate = Int(format.mSampleRate)
        let channelCount = max(1, Int(format.mChannelsPerFrame))

        let (stream, streamContinuation) = AsyncStream<PCMAudioFrame>.makeStream()
        stateLock.lock()
        continuation = streamContinuation
        converter = RealtimeAudioFormatConverter()
        stateLock.unlock()

        var newProcID: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&newProcID, newAggregateID, ioQueue) { [weak self] _, inputData, _, _, _ in
            self?.consume(inputData, sampleRate: sampleRate, channelCount: channelCount)
        }, "create IOProc")
        stateLock.lock()
        ioProcID = newProcID
        stateLock.unlock()
        try check(AudioDeviceStart(newAggregateID, newProcID), "start device")
        return stream
    }

    private func consume(_ inputData: UnsafePointer<AudioBufferList>, sampleRate: Int, channelCount: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard let buffer = buffers.first, let data = buffer.mData else { return }
        let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size
        guard sampleCount > 0 else { return }
        let floats = data.assumingMemoryBound(to: Float32.self)
        var samples = [Int16](repeating: 0, count: sampleCount)
        for index in 0..<sampleCount {
            samples[index] = Int16(clamping: Int(max(-1, min(1, floats[index])) * Float32(Int16.max)))
        }
        let frame = PCMAudioFrame(samples: samples, sampleRate: sampleRate, channelCount: Int(buffer.mNumberChannels == 0 ? UInt32(channelCount) : buffer.mNumberChannels), capturedAt: Date(), source: .systemAudio)
        stateLock.lock()
        let chunks = converter.convert(frame)
        let target = continuation
        stateLock.unlock()
        for chunk in chunks { target?.yield(chunk) }
    }

    public func stop() async {
        let (aggregate, proc, tap, cont) = stateLock.withLock { () -> (AudioObjectID, AudioDeviceIOProcID?, AudioObjectID, AsyncStream<PCMAudioFrame>.Continuation?) in
            let snapshot = (aggregateID, ioProcID, tapID, continuation)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
            ioProcID = nil
            tapID = AudioObjectID(kAudioObjectUnknown)
            continuation = nil
            return snapshot
        }
        if aggregate != kAudioObjectUnknown {
            if let proc {
                AudioDeviceStop(aggregate, proc)
                AudioDeviceDestroyIOProcID(aggregate, proc)
            }
            AudioHardwareDestroyAggregateDevice(aggregate)
        }
        if tap != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tap)
        }
        cont?.finish()
    }

    private func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format), "read tap format")
        return format
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw AudioCaptureError.systemAudioTapFailed("\(step): \(status)") }
    }
}
