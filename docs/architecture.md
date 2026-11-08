# Архитектура UserAgent057

## Слои

```
App (SwiftUI + AppKit NSPanel)
  -> ModeCoordinator (domain, actor)          -- реализует ModeControlling
       -> AnswersModeSession                  -- координирует answers
       -> RecordingModeSession                -- координирует recording
       -> PassiveModeSession                  -- no-op, гарантирует остановку всего
  -> Adapters (реализуют доменные протоколы, зависят от системных фреймворков)
       -> ScreenCaptureSystemAudioSource: SystemAudioCapturing   (ScreenCaptureKit)
       -> AVEngineMicrophoneSource: MicrophoneCapturing          (AVAudioEngine, fallback)
       -> RealtimeAnswerClient: RealtimeAnswering                (URLSessionWebSocketTask, GA Realtime API)
       -> WhisperKitTranscriber: LocalTranscribing               (WhisperKit)
       -> SQLiteMeetingRepository: MeetingRepository             (SQLite3 + WAL + FTS5)
       -> SQLiteQuestionAnswerRepository: QuestionAnswerRepository
       -> UserDefaultsSecretStore: SecretStoring                 (UserDefaults; KeychainSecretStore доступен как альтернатива при стабильной код-подписи)
       -> OSLogLatencyRecorder: LatencyRecording                 (os_signpost/os_log, без содержимого)
```

Правило зависимостей: домен (протоколы + координаторы + модели) не импортирует `ScreenCaptureKit`, `AVFoundation`, `WhisperKit`, `Network`/`URLSessionWebSocketTask`, `Security`. Эти импорты существуют только в Adapters. Домен тестируется через fake-реализации протоколов.

## Доменные протоколы (черновой контракт типов)

```swift
protocol ModeControlling: Sendable {
    var currentMode: AppMode { get async }
    func requestTransition(to mode: AppMode) async -> ModeTransitionResult
}

enum ModeTransitionResult: Sendable, Equatable {
    case succeeded(AppMode)
    case failedToPassive(reason: String)
}

struct PCMAudioFrame: Sendable {
    let samples: [Int16]
    let sampleRate: Int
    let channelCount: Int
    let capturedAt: ContinuousClockInstant
    let source: AudioSourceKind
}

enum AudioSourceKind: Sendable { case systemAudio, microphone }

protocol SystemAudioCapturing: Sendable {
    func start(targetApplicationBundleID: String?) async throws -> AsyncStream<PCMAudioFrame>
    func stop() async
}

protocol MicrophoneCapturing: Sendable {
    func start() async throws -> AsyncStream<PCMAudioFrame>
    func stop() async
}

enum RealtimeAnswerEvent: Sendable {
    case textDelta(String)
    case waitingForQuestion
    case completed(responseID: String)
    case failed(String)
}

protocol RealtimeAnswering: Sendable {
    func start(instructions: String) async throws
    func appendAudio(_ frame: PCMAudioFrame) async
    func events() -> AsyncStream<RealtimeAnswerEvent>
    func forceResponse() async throws
    func stop() async
}

protocol AnswerTriggering: Sendable {
    func events() -> AsyncStream<Void>
}

struct TranscribedSegment: Sendable {
    let text: String
    let startMs: Int
    let endMs: Int
    let source: TranscriptSource
}

enum TranscriptSource: Sendable { case remote, local }

protocol LocalTranscribing: Sendable {
    func transcribe(_ frames: [PCMAudioFrame]) async throws -> [TranscribedSegment]
}

protocol MeetingRepository: Sendable {
    func createMeeting(startedAt: Date) async throws -> MeetingID
    func appendSegment(_ segment: TranscribedSegment, meetingID: MeetingID) async throws
    func finish(meetingID: MeetingID, endedAt: Date) async throws
    func fetch(meetingID: MeetingID) async throws -> Meeting
    func search(query: String) async throws -> [Meeting]
}

protocol QuestionAnswerRepository: Sendable {
    func save(_ pair: QuestionAnswerPair) async throws
    func history(limit: Int) async throws -> [QuestionAnswerPair]
}

protocol SummaryGenerating: Sendable {
    func summarize(meetingID: MeetingID) async throws -> MeetingSummary
}

protocol SecretStoring: Sendable {
    func store(apiKey: String) throws
    func retrieveAPIKey() throws -> String?
    func deleteAPIKey() throws
}

protocol LatencyRecording: Sendable {
    func record(_ metric: LatencyMetric) async
}
```

Полные модели (`Meeting`, `MeetingID`, `QuestionAnswerPair`, `MeetingSummary`, `LatencyMetric`, `ContinuousClockInstant`) определяются в `Sources/UserAgent057Domain/Models` на этапе `02`/`03`.

## Sequence: `answers`, автоматический ответ

```
User speaks -> ScreenCaptureKit (system audio of target app)
  -> AudioFormatConverter (-> PCM16 24kHz mono)
  -> RealtimeAnswerClient.appendAudio (input_audio_buffer.append, ПОТОКОВО)
  -> [РЕЧЬ НЕ ЯВЛЯЕТСЯ ВОПРОСОМ] -> model returns "⟦WAIT_FOR_QUESTION⟧" (скрыто) -> item остаётся в conversation
  -> [ЕЩЁ РЕЧЬ, ПАУЗЫ] -> продолжает копиться как контекст задачи (без удаления)
  -> [ПРОЗВУЧАЛ ВОПРОС] -> Realtime server VAD triggers response.create (auto)
  -> response.output_text.delta (первый чанк) -> NSPanel рисует немедленно
  -> ... остальные delta ...
  -> response.done -> накопленный входной контекст очищается
  -> асинхронно, НЕ блокируя показанный ответ:
       LocalTranscribing.transcribe(ограниченное окно контекст+вопрос)
       -> QuestionAnswerRepository.save(QuestionAnswerPair)
```

Важно: на этом пути нет шага STT ПЕРЕД `response.create`. Whisper запускается только после того, как текст уже пошёл в overlay.

## Sequence: `answers`, «Ответить сейчас»

```
User presses button / global hotkey (AnswerTriggering event)
  -> ModeCoordinator.forceAnswerNow()
  -> RealtimeAnswerClient.forceResponse()
       -> ОДИН response.create (text-only, instruction: "ответь сейчас, используя контекст выше")
       -> без STT, без второго запроса к модели
  -> response.output_text.delta -> NSPanel
  -> Race with automatic response:
       if automatic response.create уже в полёте и завершился первым -> forced response игнорируется/cancel
       if forced response завершился первым -> automatic response (если ещё не создан) подавляется идемпотентным guard в ModeCoordinator
  -> ровно один видимый ответ доходит до UI
```

## Sequence: `recording`

```
System audio + Microphone -> AVAudioEngine / ScreenCaptureKit
  -> локальный VAD/chunking
  -> WhisperKitTranscriber.transcribe(chunk) -> TranscribedSegment(source: .remote|.local, startMs, endMs)
  -> MeetingRepository.appendSegment (SQLite, WAL, FTS5)
  -> НЕТ обращений к Realtime/Responses API на этом пути
```

## Sequence: переход в `passive` (в т.ч. при ошибке)

```
Error anywhere in answers/recording adapters
  -> ModeCoordinator catches -> stop(currentSession) [гарантированный await остановки: sockets closed, capture stopped, files flushed]
  -> currentMode = .passive
  -> UI показывает понятное сообщение об ошибке
  -> ModeTransitionResult.failedToPassive(reason:)
```

## Владение ресурсами

| Ресурс | Кто запускает | Кто гарантированно останавливает |
|---|---|---|
| ScreenCaptureKit stream | `AnswersModeSession` / `RecordingModeSession` | тот же session в `stop()`, вызывается `ModeCoordinator` при любом выходе из режима (включая ошибку) |
| AVAudioEngine (mic) | `RecordingModeSession` (или fallback в `answers`, если потребуется) | тот же session в `stop()` |
| Realtime WebSocket | `AnswersModeSession` | тот же session в `stop()`, а также при переходе в `passive` |
| WhisperKit runtime | `RecordingModeSession`, либо async job логирования в `answers` | владелец job, с явной отменой Task при остановке режима |
| SQLite connection | приложение (singleton adapter) | закрывается при завершении процесса; не открывается в `passive`-специфичных операциях |
| API-ключ (UserDefaults) | пользователь через Settings | не "останавливается", читается по требованию, не кешируется в памяти дольше запроса |

## Диаграмма состояний режимов

```
        requestTransition(.answers)         requestTransition(.recording)
   passive ---------------------------> answers -----------\
      ^                                     |                \
      |            error / stop()           |                 v
      |<------------------------------------+            (must go through passive)
      |                                                        |
      +--------------------------------------------------------+
                         requestTransition(.recording) / (.answers)
                         запрещён напрямую answers<->recording:
                         сначала -> passive -> целевой режим
```

Прямой переход `answers -> recording` не допускается доменной машиной состояний: `ModeCoordinator` всегда прогоняет `stop()` текущей сессии и переустанавливает `currentMode = .passive` перед стартом новой, даже если конечный запрошенный режим не `passive`. Это гарантирует отсутствие одновременно двух активных сессий.
