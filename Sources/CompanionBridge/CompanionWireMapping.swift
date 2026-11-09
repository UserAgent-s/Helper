import CompanionProtocol
import Domain
import Foundation

public enum CompanionWireMapping {
    public static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    public static func mode(_ mode: AppMode) -> WireMode {
        switch mode {
        case .passive: .passive
        case .answers: .answers
        case .recording: .recording
        }
    }

    public static func appMode(_ mode: WireMode) -> AppMode {
        switch mode {
        case .passive: .passive
        case .answers: .answers
        case .recording: .recording
        }
    }

    public static func phase(_ phase: ModePhase) -> WirePhase {
        switch phase {
        case .idle: .idle
        case .starting: .starting
        case .active: .active
        case .stopping: .stopping
        case .failed: .failed
        }
    }

    public static func errorCode(_ reason: ModeFailureReason?) -> String? {
        switch reason {
        case nil: nil
        case .permissionDenied: "permission_denied"
        case .targetApplicationNotRunning: "target_app_not_running"
        case .noControllerRegistered: "mode_unavailable"
        case .unknown: "mode_failed"
        }
    }

    public static func modeInfo(_ state: ModeState) -> ModeInfo {
        ModeInfo(
            mode: mode(state.mode),
            phase: phase(state.phase),
            startedAt: state.startedAt.map(milliseconds),
            errorCode: errorCode(state.userFacingError)
        )
    }

    public static func trigger(_ kind: AnswerTriggerKind?) -> WireTrigger {
        kind == .manual ? .manual : .auto
    }

    public static func transcript(_ event: TranscriptEvent) -> TranscriptLine {
        TranscriptLine(
            itemId: event.itemID,
            speaker: event.speaker == .me ? .me : .them,
            text: event.text,
            isFinal: event.isFinal,
            language: event.language
        )
    }

    public static func level(_ level: AudioLevel) -> LevelInfo {
        LevelInfo(
            source: level.kind == .microphone ? .me : .system,
            rmsDBFS: Double(level.rmsDBFS),
            peakDBFS: Double(level.peakDBFS)
        )
    }

    public static func notice(_ notice: CaptureNotice) -> NoticeInfo {
        switch notice {
        case .fellBackToWholeSystem(let missingBundleID):
            NoticeInfo(code: "capture_fell_back_whole_system", severity: .warning, args: ["bundleId": missingBundleID])
        case .systemCaptureRestarted(let reason):
            NoticeInfo(code: "capture_restarted", severity: .warning, args: ["reason": reason])
        case .microphoneFellBack(_, let to, let reason):
            NoticeInfo(code: "microphone_fell_back", severity: .warning, args: ["to": to, "reason": microphoneReason(reason)])
        case .outputRouteChanged(let route):
            NoticeInfo(code: "output_route_changed", severity: route == .builtInSpeakers ? .warning : .info, args: ["route": routeKind(route)])
        }
    }

    static func microphoneReason(_ reason: MicrophoneFallbackReason) -> String {
        switch reason {
        case .continuityDefault: "continuity_default"
        case .continuitySelected: "continuity_selected"
        case .selectedDeviceMissing: "selected_device_missing"
        }
    }

    static func routeKind(_ route: OutputRoute) -> String {
        switch route {
        case .builtInSpeakers: "built_in_speakers"
        case .wiredHeadphones: "wired_headphones"
        case .bluetoothHeadphones: "bluetooth_headphones"
        case .airPlay: "airplay"
        case .external: "external"
        case .unknown: "unknown"
        }
    }
}
