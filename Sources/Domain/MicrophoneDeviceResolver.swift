public enum MicrophoneDeviceResolver {
    public static func resolve(_ selection: MicrophoneSelection, devices: [AudioDeviceInfo], defaultInputUID: String?) -> (device: AudioDeviceInfo?, notice: CaptureNotice?) {
        let inputs = devices.filter(\.hasInput)
        let eligible = inputs.filter { !$0.transport.isContinuity }
        let systemDefault = defaultInputUID.flatMap { uid in inputs.first { $0.uid == uid } }

        var rejected: (from: String?, reason: MicrophoneFallbackReason)?
        if case .device(let uid) = selection {
            if let selected = inputs.first(where: { $0.uid == uid }) {
                if !selected.transport.isContinuity {
                    return (selected, nil)
                }
                rejected = (selected.name, .continuitySelected)
            } else {
                rejected = (uid, .selectedDeviceMissing)
            }
        }

        let fallback: AudioDeviceInfo?
        if let systemDefault, !systemDefault.transport.isContinuity {
            fallback = systemDefault
        } else {
            if rejected == nil, let systemDefault {
                rejected = (systemDefault.name, .continuityDefault)
            }
            fallback = eligible.first { $0.transport == .builtIn } ?? eligible.first
        }

        guard let fallback else { return (nil, nil) }
        guard let rejected else { return (fallback, nil) }
        return (fallback, .microphoneFellBack(from: rejected.from, to: fallback.name, reason: rejected.reason))
    }

    public static func plan(_ selection: MicrophoneSelection, catalog: any AudioDeviceCataloging, sampleRate: Int = 16_000) -> MicrophoneStartPlan {
        let resolved = resolve(selection, devices: catalog.devices(), defaultInputUID: catalog.defaultInputUID())
        return MicrophoneStartPlan(
            options: MicrophoneCaptureOptions(deviceUID: resolved.device?.uid, sampleRate: sampleRate),
            notice: resolved.notice
        )
    }
}
