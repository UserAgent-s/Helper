public enum AudioTransport: Sendable, Equatable {
    case builtIn
    case usb
    case bluetooth
    case bluetoothLE
    case airPlay
    case aggregate
    case virtual
    case continuityWired
    case continuityWireless
    case other(UInt32)

    public init(fourCC: UInt32) {
        switch Self.code(fourCC) {
        case "bltn": self = .builtIn
        case "usb ": self = .usb
        case "blue": self = .bluetooth
        case "blea": self = .bluetoothLE
        case "airp": self = .airPlay
        case "grup": self = .aggregate
        case "virt": self = .virtual
        case "ccwd": self = .continuityWired
        case "ccwl": self = .continuityWireless
        default: self = .other(fourCC)
        }
    }

    public var isContinuity: Bool {
        self == .continuityWired || self == .continuityWireless
    }

    public static func fourCC(_ code: String) -> UInt32 {
        code.utf8.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    static func code(_ value: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

public struct AudioDeviceInfo: Sendable, Equatable, Identifiable {
    public let id: UInt32
    public let uid: String
    public let name: String
    public let transport: AudioTransport
    public let hasInput: Bool
    public let hasOutput: Bool
    public let outputDataSource: UInt32?

    public init(id: UInt32, uid: String, name: String, transport: AudioTransport, hasInput: Bool, hasOutput: Bool, outputDataSource: UInt32? = nil) {
        self.id = id
        self.uid = uid
        self.name = name
        self.transport = transport
        self.hasInput = hasInput
        self.hasOutput = hasOutput
        self.outputDataSource = outputDataSource
    }
}

public enum MicrophoneSelection: Sendable, Equatable, Codable {
    case systemDefaultExcludingContinuity
    case device(uid: String)
}

public struct MicrophoneCaptureOptions: Sendable, Equatable {
    public var deviceUID: String?
    public var sampleRate: Int
    public var voiceProcessing: Bool

    public init(deviceUID: String? = nil, sampleRate: Int = 16_000, voiceProcessing: Bool = false) {
        self.deviceUID = deviceUID
        self.sampleRate = sampleRate
        self.voiceProcessing = voiceProcessing
    }
}

public struct MicrophoneStartPlan: Sendable, Equatable {
    public var options: MicrophoneCaptureOptions
    public var notice: CaptureNotice?

    public init(options: MicrophoneCaptureOptions = MicrophoneCaptureOptions(), notice: CaptureNotice? = nil) {
        self.options = options
        self.notice = notice
    }
}

public enum MicrophoneFallbackReason: Sendable, Equatable {
    case continuityDefault
    case continuitySelected
    case selectedDeviceMissing
}

public enum AudioDeviceChange: Sendable, Equatable {
    case deviceListChanged
    case defaultInputChanged
    case defaultOutputChanged
    case outputDataSourceChanged
    case microphoneEngineReconfigured
}

public protocol AudioDeviceCataloging: Sendable {
    func devices() -> [AudioDeviceInfo]
    func defaultInputUID() -> String?
    func defaultOutputDevice() -> AudioDeviceInfo?
    func changes() -> AsyncStream<AudioDeviceChange>
}
