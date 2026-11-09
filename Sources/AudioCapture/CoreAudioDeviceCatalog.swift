import CoreAudio
import Domain
import Foundation

public final class CoreAudioDeviceCatalog: AudioDeviceCataloging, @unchecked Sendable {
    private let changeBroadcaster = AsyncBroadcaster<AudioDeviceChange>()
    private let listenerQueue = DispatchQueue(label: "com.local.UserAgent057.audiocapture.devices")
    private let listenerLock = NSLock()
    private var listenersInstalled = false
    private var dataSourceListenerDeviceIDs: Set<AudioDeviceID> = []

    public init() {}

    public func devices() -> [AudioDeviceInfo] {
        Self.deviceIDs().compactMap(Self.info(for:))
    }

    public func defaultInputUID() -> String? {
        guard let id = Self.systemDevice(kAudioHardwarePropertyDefaultInputDevice) else { return nil }
        return Self.string(id, kAudioDevicePropertyDeviceUID)
    }

    public func defaultOutputDevice() -> AudioDeviceInfo? {
        Self.systemDevice(kAudioHardwarePropertyDefaultOutputDevice).flatMap(Self.info(for:))
    }

    public func changes() -> AsyncStream<AudioDeviceChange> {
        installListenersIfNeeded()
        return changeBroadcaster.subscribe("deviceCatalog")
    }

    public static func deviceID(forUID uid: String) -> AudioDeviceID? {
        deviceIDs().first { string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    private func installListenersIfNeeded() {
        listenerLock.lock()
        defer { listenerLock.unlock() }
        guard !listenersInstalled else { return }
        listenersInstalled = true
        let pairs: [(AudioObjectPropertySelector, AudioDeviceChange)] = [
            (kAudioHardwarePropertyDevices, .deviceListChanged),
            (kAudioHardwarePropertyDefaultInputDevice, .defaultInputChanged),
            (kAudioHardwarePropertyDefaultOutputDevice, .defaultOutputChanged),
        ]
        let broadcaster = changeBroadcaster
        for (selector, change) in pairs {
            var address = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue) { [weak self] _, _ in
                if change == .defaultOutputChanged {
                    self?.installDataSourceListenerOnDefaultOutput()
                }
                broadcaster.yield(change)
            }
        }
        installDataSourceListenerOnDefaultOutputLocked()
    }

    private func installDataSourceListenerOnDefaultOutput() {
        listenerLock.lock()
        defer { listenerLock.unlock() }
        installDataSourceListenerOnDefaultOutputLocked()
    }

    private func installDataSourceListenerOnDefaultOutputLocked() {
        guard let deviceID = Self.systemDevice(kAudioHardwarePropertyDefaultOutputDevice),
              !dataSourceListenerDeviceIDs.contains(deviceID)
        else { return }
        var address = Self.address(kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput)
        guard AudioObjectHasProperty(deviceID, &address) else { return }
        let broadcaster = changeBroadcaster
        let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, listenerQueue) { _, _ in
            broadcaster.yield(.outputDataSourceChanged)
        }
        if status == noErr {
            dataSourceListenerDeviceIDs.insert(deviceID)
        }
    }

    static func info(for id: AudioDeviceID) -> AudioDeviceInfo? {
        guard let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        let hasOutput = channelCount(id, scope: kAudioObjectPropertyScopeOutput) > 0
        return AudioDeviceInfo(
            id: id,
            uid: uid,
            name: string(id, kAudioObjectPropertyName) ?? uid,
            transport: AudioTransport(fourCC: uint32(id, kAudioDevicePropertyTransportType) ?? 0),
            hasInput: channelCount(id, scope: kAudioObjectPropertyScopeInput) > 0,
            hasOutput: hasOutput,
            outputDataSource: hasOutput ? uint32(id, kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput) : nil
        )
    }

    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func systemDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        guard let id = uint32(AudioObjectID(kAudioObjectSystemObject), selector), id != kAudioObjectUnknown else { return nil }
        return id
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var address = address(selector, scope: scope)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func channelCount(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
