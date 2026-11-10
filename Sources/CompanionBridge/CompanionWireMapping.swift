import CompanionProtocol
import Domain
import Foundation

public enum CompanionWireMapping {
    public static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    public static func sessionId(_ id: SessionID) -> String {
        id.rawValue.uuidString
    }

    public static func stopReason(_ reason: SessionStopReason) -> WireSessionStopReason {
        switch reason {
        case .user: .user
        case .idleTimeout: .idle
        }
    }

    public static func bookmark(_ bookmark: SessionBookmark) -> BookmarkInfo {
        BookmarkInfo(
            bookmarkId: bookmark.id,
            sessionId: sessionId(bookmark.sessionID),
            kind: bookmark.kind == .star ? .star : .moment,
            markedAt: milliseconds(bookmark.markedAt),
            answerId: bookmark.questionAnswerID?.uuidString,
            note: bookmark.note
        )
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
        case .meTranscriptionUnavailable(let reason):
            NoticeInfo(code: "me_channel_unavailable", severity: .warning, args: ["reason": reason])
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

    public static func expansionFormat(_ format: WireDeepFormat?) -> ExpansionFormat {
        guard let format else { return .structured }
        return ExpansionFormat(rawValue: format.rawValue) ?? .structured
    }

    public static func expansionLanguage(_ language: WireLanguage?) -> ExpansionLanguage {
        guard let language else { return .auto }
        return ExpansionLanguage(rawValue: language.rawValue) ?? .auto
    }

    public static func expansionModel(_ model: WireDeepModel) -> ExpansionModelChoice {
        model == .opus ? .opus : .sonnet
    }

    public static func wireDeepModel(_ modelID: String) -> WireDeepModel {
        modelID.contains("opus") ? .opus : .sonnet
    }

    public static func wireDeepFormat(_ format: ExpansionFormat) -> WireDeepFormat {
        WireDeepFormat(rawValue: format.rawValue) ?? .structured
    }

    public static func wireLanguage(_ language: ExpansionLanguage) -> WireLanguage {
        WireLanguage(rawValue: language.rawValue) ?? .auto
    }

    public static func wireStatus(_ outcome: ExpansionOutcome) -> WireAnswerStatus {
        switch outcome {
        case .completed, .truncated: .completed
        case .cancelled: .cancelled
        case .refused, .failed: .failed
        }
    }

    public static func transcriptPromptLine(_ line: TranscriptLine) -> String {
        (line.speaker == .me ? "Я: " : "Собеседник: ") + line.text
    }
}
