public enum OutputRoute: Sendable, Equatable {
    case builtInSpeakers
    case wiredHeadphones
    case bluetoothHeadphones(name: String)
    case airPlay(name: String)
    case external(name: String)
    case unknown

    public var diagnosticsLabel: String {
        switch self {
        case .builtInSpeakers: "builtInSpeakers"
        case .wiredHeadphones: "wiredHeadphones"
        case .bluetoothHeadphones: "bluetoothHeadphones"
        case .airPlay: "airPlay"
        case .external: "external"
        case .unknown: "unknown"
        }
    }
}

public enum OutputRoutePolicy: String, Sendable, Codable, CaseIterable {
    case auto
    case headphones
    case speakers
}

public enum OutputRouteClassifier {
    public static let internalSpeakerDataSource = AudioTransport.fourCC("ispk")
    public static let headphoneDataSource = AudioTransport.fourCC("hdpn")

    public static func classify(_ device: AudioDeviceInfo?) -> OutputRoute {
        guard let device, device.hasOutput else { return .unknown }
        switch device.transport {
        case .builtIn:
            if device.outputDataSource == headphoneDataSource || device.name.localizedCaseInsensitiveContains("Headphones") {
                return .wiredHeadphones
            }
            if device.outputDataSource == internalSpeakerDataSource || device.outputDataSource == nil {
                return .builtInSpeakers
            }
            return .external(name: device.name)
        case .bluetooth, .bluetoothLE:
            return .bluetoothHeadphones(name: device.name)
        case .airPlay:
            return .airPlay(name: device.name)
        case .usb, .aggregate, .virtual, .continuityWired, .continuityWireless, .other:
            return .external(name: device.name)
        }
    }

    public static func echoRisk(_ route: OutputRoute, policy: OutputRoutePolicy) -> Bool {
        switch policy {
        case .headphones: return false
        case .speakers: return true
        case .auto:
            switch route {
            case .builtInSpeakers, .airPlay, .external: return true
            case .wiredHeadphones, .bluetoothHeadphones, .unknown: return false
            }
        }
    }
}
