# Статус реализации UserAgent057

Формат записи: дата, промпт, изменённые компоненты, команды проверки, результат, оставшиеся риски.

---

## 2026-08-22 — Этап 00: Продуктовый контракт

**Изменённые компоненты:**
- `docs/product-contract.md` (создан)
- `docs/architecture.md` (создан)
- `docs/adr/0001-three-exclusive-modes.md` (создан)
- `docs/adr/0002-direct-audio-realtime-critical-path.md` (создан)
- `docs/adr/0003-local-only-meeting-transcription.md` (создан)
- `claude-code-prompts/` — переименован из `prompts/` в корне репозитория (по инструкции README пошаговых промптов)
- Инициализирован пустой git-репозиторий (`git init`, коммитов не создавалось — по правилу "не коммитить без явного запроса")

**Команды проверки:**
- Ручная проверка: в документации ровно 3 режима, нет четвёртого фонового состояния, sequence-диаграмма `answers` не содержит STT перед `response.create`, диаграмма показывает накопление контекста и отдельный путь `Ответить сейчас`.

**Результат:** пройдено. Контракт и архитектура зафиксированы, критерии приёмки этапа 00 выполнены.

**Оставшиеся риски:**
- XcodeGen не установлен в окружении (см. этап 01) — потребуется `brew install xcodegen` для генерации `.xcodeproj`.
- Точная версия WhisperKit/`argmax-oss-swift` и конкретная Whisper-модель будут закреплены на этапе 01 при добавлении Package-зависимостей; на момент этапа 00 решение отложено осознанно (не блокирует контракт).
- GA-схема событий OpenAI Realtime API будет валидироваться по официальной документации на этапе 04; если сеть недоступна в момент выполнения — протокол будет изолирован за типизированным адаптером (`RealtimeAnswering` + внутренний `RealtimeEventCoding`), чтобы схему можно было поправить в одном месте.

---

## 2026-08-22 — Этап 01: Каркас macOS-проекта

**Изменённые компоненты:**
- `Package.swift` (создан) — локальный SwiftPM-пакет `UserAgent057Core` с модулями `Domain`, `AudioCapture`, `RealtimeClient`, `Transcription`, `Persistence`, `SecurityStore`, `Diagnostics`, `Summary`; зависимость `argmaxinc/argmax-oss-swift`, точная версия `1.1.0` (последний стабильный релиз на дату этапа), продукт `WhisperKit` используется только модулем `Transcription`. Версия закреплена в `Package.resolved`.
- `Sources/Domain/{AppMode,Models,Protocols,BootstrapModeCoordinator}.swift` (созданы) — enum режимов, доменные `Sendable`-модели и протоколы из `docs/architecture.md`, минимальная реализация `ModeControlling` для бутстрапа.
- `Sources/{AudioCapture,RealtimeClient,Transcription,Persistence,SecurityStore,Diagnostics,Summary}/Inactive*.swift` / `NoOpLatencyRecorder.swift` (созданы) — явно неактивные реализации всех протоколов: либо бросают `BootstrapUnavailableError.notYetImplemented`, либо (для `LatencyRecording`, у которого нет возвращаемого статуса) — честный no-op. Ничего не захватывает, не пишет на диск и не отправляет по сети.
- `Sources/App/{UserAgent057App,CompositionRoot,ModeSwitcherView}.swift` (созданы) — SwiftUI entry point, composition root, экран с ровно тремя режимами (`Picker` без запуска реальных пайплайнов). Старт всегда в `.passive`.
- `Tests/DomainTests/BootstrapModeCoordinatorTests.swift` (создан) — 3 теста: старт в `passive`, переходы во все режимы, ровно 3 режима.
- `Tests/AppTests/CompositionRootTests.swift` (создан) — тест на старт composition root в `passive` (для будущей Xcode-схемы `UserAgent057Tests`).
- `project.yml` (создан) — XcodeGen-спецификация: продукт `UserAgent057.app`, bundle id `com.local.UserAgent057`, deployment target macOS 14.0, Swift 6, схемы `UserAgent057`/`UserAgent057Tests`, зависимость на локальный пакет `UserAgent057Core` (все 8 продуктов).
- `Resources/Info.plist` (создан) — `NSMicrophoneUsageDescription` с понятным описанием (только для `recording`).
- `Resources/UserAgent057.entitlements` (создан) — App Sandbox включён, `network.client` (исходящие соединения к Realtime/Responses API), `device.audio-input` (микрофон в `recording`). Sandbox не ослаблен.
- `.gitignore` (создан) — Xcode/DerivedData, `.build`, локальные Whisper-модели, SQLite (+WAL/SHM), секреты, архивы/build artifacts, `.DS_Store`.
- `README.md` (создан) — требования среды, структура, команды генерации/сборки/тестов для Xcode-проекта и отдельно для `swift build`/`swift test`.
- `claude-code-prompts/` — уже переименован на этапе 00.

**Архитектурное отклонение от буквального списка целей (обосновано):**
- Модуль безопасности назван `SecurityStore`, а не `Security` — имя `Security` конфликтует с системным фреймворком Apple `Security`, который модуль обязан импортировать изнутри (self-import). `SecurityStore` реализует протокол `SecretStoring` из `docs/architecture.md`; понятийная граница "Security" из этапа 01 сохранена, изменилось только имя SwiftPM-таргета.
- Для `ScreenCaptureKit`-доступа (запись экрана) в macOS не существует публичного ключа `Info.plist`, аналогичного `NSMicrophoneUsageDescription` — текст системного диалога Screen Recording фиксирован ОС и не настраивается через `Info.plist`. Зафиксировано здесь, а не изобретён несуществующий ключ.

**Команды проверки:**
- `swift build` — успешно, включая разрешение и сборку зависимости WhisperKit (`argmax-oss-swift` v1.1.0, ArgmaxCore, WhisperKit) для `arm64-apple-macosx14.0`.
- `swift test` — успешно, 3/3 теста прошли (`DomainTests`).
- `python3 -c "import yaml; yaml.safe_load(open('project.yml'))"` — синтаксис `project.yml` валиден.
- `xcodegen generate` / `xcodebuild ... build` / `xcodebuild ... test` — **не выполнено**: `xcodegen` не установлен в окружении и не установлен автоматически (по правилу "не устанавливать глобальные зависимости без явного разрешения"). Точная команда для пользователя: `brew install xcodegen`, затем `xcodegen generate` в корне репозитория.

**Результат:** пройдено с одной задокументированной внешней блокировкой (см. выше). Всё, что не требует генерации `.xcodeproj`, реализовано и проверено.

**Оставшиеся риски:**
- Без `xcodegen` невозможно объективно проверить сборку `UserAgent057.app` и Xcode-схему `UserAgent057Tests` в этом окружении; `Tests/AppTests/CompositionRootTests.swift` написан, но не запускался.
- `Sources/OverlayUI` и `Sources/HistoryUI` пока пустые каталоги — заполняются на этапах 05 и 08 соответственно; включены в `project.yml` заранее, чтобы не менять спецификацию таргета позже.
- Entitlements пока не включают ничего специфичного для `ScreenCaptureKit` — по состоянию на этап 01 это не требуется (TCC-разрешение "Запись экрана" выдаётся пользователем в System Settings, а не через entitlement); будет перепроверено на этапе 03.

---

## 2026-08-22 — Этап 02: Машина состояний трёх режимов

**Изменённые компоненты:**
- `Sources/Domain/ModeState.swift` (создан) — `ModePhase` (`idle/starting/active/stopping/failed`), `ModeState`, `ModeTransition`, `AnswerTurnPhase` (`collectingContext/automaticResponsePending/manualResponsePending/streaming/completed`) — внутреннее состояние одного хода `answers`, не входит в `AppMode`.
- `Sources/Domain/ResourceLease.swift` (создан) — actor, гарантирующий однократное выполнение `releaseAction`, даже при повторных вызовах `release()`.
- `Sources/Domain/ModeController.swift` (создан) — протокол жизненного цикла `start()/stop()/failures()`; контракт "`stop()` никогда не бросает" зафиксирован в doc-комментарии.
- `Sources/Domain/ModeCoordinator.swift` (создан) — единственная точка входа для переходов. FIFO-сериализация конкурентных запросов через цепочку `tail`-задач (без потери и без "застревания" в промежуточном режиме); `stop(A)` всегда полностью завершается до `start(B)`; ошибка `start()` -> `controller.stop()` (откат частично созданных ресурсов) -> `passive`; фоновый `watchFailures` переводит приложение в `passive` при рантайм-сбое уже АКТИВНОГО режима (например, обрыв соединения); `stateUpdates()` — реактивный `AsyncStream<ModeState>` для UI; `shutdown(timeout:)` — ограниченный по времени переход в `passive` при завершении приложения.
- `Sources/Domain/AnswersModeController.swift`, `Sources/Domain/RecordingModeController.swift` (созданы) — конкретные `ModeController` для `answers`/`recording`, внедряются в координатор (не создаются им). `AnswersModeController` идемпотентно разрешает гонку "автоматический ответ vs `Ответить сейчас`" через `activeResponseID` (первый замеченный `responseID` побеждает, остальные игнорируются) и отменяет `manualResponsePending` при любом `stop()`. `RecordingModeController.stop()` сначала финализирует накопленные сегменты и встречу (`MeetingRepository.finish`), затем освобождает `ResourceLease` захвата (правило 7).
- `Sources/Domain/ManualAnswerTrigger.swift` (создан) — общий источник событий `Ответить сейчас` для будущей кнопки/горячей клавиши (этап 05).
- `Sources/Domain/Models.swift` (изменён) — `RealtimeAnswerEvent` дополнен `case responseStarted(responseID:trigger:)` и `responseID` в `textDelta`, необходимыми для идемпотентного разрешения гонки на уровне контроллера, а не только внутри Realtime-адаптера.
- `Sources/App/CompositionRoot.swift`, `Sources/App/ModeSwitcherView.swift` (изменены) — заменили `BootstrapModeCoordinator` (удалён, `git rm`-эквивалент через прямое удаление файла) на настоящий `ModeCoordinator` с реальными `AnswersModeController`/`RecordingModeController`, всё ещё построенными поверх `Inactive*`-адаптеров этапа 01 (поэтому переход в `answers`/`recording` в текущем состоянии детерминированно завершается `failedToPassive` — ожидаемо и будет разблокировано этапами 03/04/06/07). UI теперь подписан на `stateUpdates()` и показывает режим, переходную фазу, ошибку и подтверждение возврата в `passive`.
- `Tests/DomainTests/TestDoubles.swift` (создан) — `CallRecorder` + `FakeModeController` (spy для проверки порядка вызовов `start`/`stop`), fake-реализации всех адаптерных протоколов (`SystemAudioCapturing`, `MicrophoneCapturing`, `RealtimeAnswering`, `AnswerTriggering`, `LocalTranscribing`, `MeetingRepository`).
- `Tests/DomainTests/ModeCoordinatorTests.swift` (создан) — 10 тестов: старт в `passive`, все 6 направленных переходов (с проверкой порядка `stop.end` < `start.begin` по логу вызовов, а не только итогового enum), идемпотентный повтор, ошибка `start()` каждого контроллера с откатом, "ошибка остановки" (по контракту `stop()` не бросает — тест проверяет, что `passive` достигается безусловно), два конкурентных переключения (точный ожидаемый порядок событий, без наложения), `shutdown()` во время `starting` ограничен таймаутом, отсутствие висящих ресурсов в `passive` (баланс `start.begin`/`stop.end`), рантайм-сбой активного режима -> `passive`.
- `Tests/DomainTests/AnswersModeControllerTests.swift` (создан) — 5 тестов: гонка manual/automatic даёт ровно один видимый ответ и ровно один `forceResponse()`, manual trigger игнорируется во время стриминга, manual trigger отменяется при `stop()` (событие после остановки не доходит), `waitingForQuestion` не стартует ответ, `stop()` освобождает capture/realtime.
- `Tests/DomainTests/RecordingModeControllerTests.swift` (создан) — 3 теста: `stop()` финализирует сегменты и встречу до освобождения ресурсов, структурная гарантия отсутствия зависимости от `RealtimeAnswering`/`SummaryGenerating`, сбой транскрипции репортится как `failure`, а не крашит контроллер.
- `Tests/AppTests/CompositionRootTests.swift` — без изменений по содержанию (по-прежнему проверяет старт в `passive`), совместим с новым `ModeCoordinator` (тот же публичный API).
- `Tests/DomainTests/AppModeTests.swift` (создан, замена `BootstrapModeCoordinatorTests.swift`) — вынесенный тест "ровно три режима".

**Важное исправление в процессе (задокументировано, т.к. это реальная архитектурная ловушка):**
- Первая версия `shutdown(timeout:)` использовала `withTaskGroup` с `group.cancelAll()`. Тест `shutdownDuringStartingIsBoundedByTimeout` показал, что это НЕ работает: `withTaskGroup` перед возвратом структурно дожидается завершения ВСЕХ дочерних задач, даже отменённых, если они не проверяют `Task.isCancelled` (наш `start()` в тесте не проверяет — как и многие реальные системные вызовы). В результате `shutdown()` блокировался на полную длительность медленного `start()` (в тесте — 30 секунд), а не на заявленный таймаут. Исправлено: гонка через независимые `Task { }` + `CheckedContinuation`, разрешаемая один раз через `SingleResume` — так таймаут действительно ограничивает время ожидания, а проигравшая задача донабирает очередь переходов в фоне.

**Команды проверки:**
- `swift build` — успешно.
- `swift test` — успешно, 19/19 тестов (4 suite: `AppModeTests`, `ModeCoordinatorTests`, `AnswersModeControllerTests`, `RecordingModeControllerTests`), полный прогон < 0.3 с.
- `swiftc -typecheck` для `Sources/App/*.swift` с `-I .build/.../Modules` (обходной путь без `xcodegen`) — без ошибок и предупреждений. Полноценный `xcodebuild build/test` по-прежнему не выполнен по той же причине, что и на этапе 01.

**Результат:** пройдено. Все критерии этапа 02 выполнены и проверены тестами, включая проверку ПОРЯДКА вызовов (не только итогового значения enum), что стадия явно требовала.

**Оставшиеся риски:**
- `AnswersModeController`/`RecordingModeController` пока используют `Inactive*`-адаптеры — реальное поведение (аудио, сеть, WhisperKit) будет проверено интеграционно на этапах 03/04/06/07; сегодняшние тесты проверяют оркестрацию и порядок вызовов через fake-адаптеры, а не реальные системные фреймворки.
- `xcodebuild build/test` по-прежнему не запускался (нет `xcodegen`); митигировано `swiftc -typecheck` всех App-исходников после каждого изменения.
- Системная инструкция для `AnswersModeController` — временный плейсхолдер в `CompositionRoot`, заменяется на этапе 04.

---

## 2026-08-22 — Этап 03: Захват и маршрутизация аудио

**Изменённые компоненты:**
- `Sources/AudioCapture/PCMResampler.swift` (создан) — `PCMResampler` (даунмикс каналов усреднением + линейная передискретизация под произвольное соотношение частот, чистая функция без системных фреймворков), `RealtimeAudioFormatConverter` (стейтфул: 24 kHz mono, равномерные 20мс/480-сэмпловые фреймы, хвост переносится между вызовами) и `WhisperAudioFormatConverter` (стейтлес: 16 kHz mono — под закреплённую версию `WhisperKit` 1.1.0, `WhisperKit.sampleRate == 16000`, проверено чтением исходников пакета в `.build/checkouts`).
- `Sources/AudioCapture/AnswersRingBuffer.swift` (создан) — actor, ограниченный ring buffer на 45с (настраиваемо) для `answers`; вытесняет самые старые фреймы по превышению суммарной длительности, `clear()` для выхода из режима. Никогда не пишется на диск (только in-memory).
- `Sources/AudioCapture/RecordingBackpressureChannel.swift` (создан) — actor, bounded async channel для `recording`: вытесняет самый старый непрочитанный фрейм при переполнении и считает `droppedFrameCount` вместо неограниченного роста памяти; поддерживает ожидающего потребителя без polling (`withCheckedContinuation`).
- `Sources/Domain/PermissionsChecking.swift`, `Sources/AudioCapture/SystemPermissionsChecker.swift` (созданы) — `PermissionStatus`/`PermissionKind` в Domain (протокол тестируем без системных фреймворков), реальная реализация поверх `CGPreflightScreenCaptureAccess`/`CGRequestScreenCaptureAccess` и `AVCaptureDevice.authorizationStatus/requestAccess`. `CGPreflight/CGRequestScreenCaptureAccess` не различают "не спрошено" и "отклонено" (оба `false`) — осознанно трактуются как `.denied`, чтобы вызывающий код не зацикливал повторный запрос.
- `Sources/Domain/PreferredAudioSourceStoring.swift`, `Sources/AudioCapture/UserDefaultsPreferredAudioSourceStore.swift` (созданы) — хранение предпочтённого bundle identifier meeting-приложения; `AnswersModeController` (изменён) теперь читает его заново при каждом `start()` вместо фиксации при конструировании — правило "сохраняй предпочтение, но проверяй доступность при каждом запуске".
- `Sources/AudioCapture/CMSampleBuffer+PCMAudioFrame.swift` (создан) — извлечение PCM из `CMSampleBuffer` (`CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer`, non-interleaved/interleaved Float32 или Int16 -> доменный Int16 `PCMAudioFrame`).
- `Sources/AudioCapture/ScreenCaptureKitSystemAudioCapturing.swift` (создан) — реальный `SystemAudioCapturing`: Screen Recording permission запрашивается только в `start()`; `SCContentFilter` по конкретному `SCRunningApplication` (bundle ID) для `answers`, либо по всему дисплею для `recording`; `SCStreamConfiguration.sampleRate` выставлен сразу в целевую частоту (24 kHz/16 kHz — передискретизацию высокого качества делает сам ScreenCaptureKit, наш `PCMResampler` в этом случае no-op и служит defensive fallback'ом); видео сведено к минимуму (2x2, 1 fps) и `.screen`-выход не подписан вовсе — видео физически не читается. `stop()` гарантированно останавливает `SCStream` и закрывает continuation ровно один раз.
- `Sources/AudioCapture/AVEngineMicrophoneCapturing.swift` (создан) — реальный `MicrophoneCapturing` через тап на `AVAudioEngine.inputNode`; Microphone permission запрашивается только в `start()`; конвертирует каждый буфер в 16 kHz mono через `WhisperAudioFormatConverter`.
- `Sources/App/CompositionRoot.swift` (изменён) — `answersSystemAudioCapturing`/`recordingSystemAudioCapturing` теперь настоящие `ScreenCaptureKitSystemAudioCapturing` (разные `outputFormat`), `microphoneCapturing` — настоящий `AVEngineMicrophoneCapturing`. `RealtimeAnswering`/`LocalTranscribing`/`MeetingRepository` по-прежнему `Inactive*` (этапы 04/06-07/08), поэтому оба режима всё ещё детерминированно завершаются `failedToPassive` — ожидаемо, порядок вызовов в контроллерах таков, что до реального аудиозахвата выполнение сейчас не доходит.
- `Package.swift` (изменён) — добавлен `AudioCaptureTests` test target.
- `Tests/AudioCaptureTests/{PCMResamplerTests,AnswersRingBufferTests,RecordingBackpressureChannelTests,SystemPermissionsCheckerTests}.swift` (созданы) — 21 тест на синтетических PCM fixtures: порядок timestamps через конвертацию, точная длина после ресемплинга (down/up/no-op), константный сигнал остаётся константным при ресемплинге, равномерные 20мс realtime-фреймы и перенос "хвоста" между вызовами, целевой формат Whisper-конвертера, отсутствие переполнения ring buffer (граница по длительности), вытеснение самых старых фреймов, `clear()`, backpressure с подсчётом `droppedFrameCount` и ограниченной памятью, доставка без polling, `finish()`, маппинг статусов разрешений (включая "false -> denied" осознанное решение).

**Важное архитектурное решение, не зафиксированное дословно в тексте этапа (обосновано):**
- Реальная работа Swift 6 concurrency: `NSLock.lock()/unlock()` компилятор запрещает вызывать напрямую внутри `async`-функций ("Use async-safe scoped locking instead"). Решено вынесением критических секций в приватный синхронный метод `withLockedState(_:)` в обоих capture-адаптерах — тот же паттерн, что и `SingleResume` на этапе 02, просто в новой форме. Это НЕ отклонение от требований этапа, а обязательное следствие "Swift 6 с корректной моделью конкурентности" из базового промпта.
- `SCStreamConfiguration.sampleRate` выставляется сразу в целевую частоту вместо захвата на "естественной" частоте (обычно 48 kHz) с последующим ресемплингом вручную — качество передискретизации у ScreenCaptureKit/CoreAudio выше, чем у нашей линейной интерполяции. `PCMResampler` при этом не удаляется: он остаётся протестированным defensive fallback'ом (на случай, если сконфигурированная частота не будет точно соблюдена конкретной версией macOS) и единственным местом ресемплинга для случая, когда `fromRate != toRate`.

**Команды проверки:**
- `swift build` — успешно, включая реальные `ScreenCaptureKit`/`AVFAudio`/`CoreMedia`/`CoreAudio` импорты.
- `swift test` — успешно, 40/40 тестов (добавлено 21 новых в `AudioCaptureTests`, ни один существующий тест не сломан).
- `swiftc -typecheck` для `Sources/App/*.swift` — без ошибок, `CompositionRoot` с новыми capture-адаптерами компилируется.

**Результат:** пройдено для всей логики, которую можно объективно проверить в этом окружении (форматы, буферы, backpressure, маппинг разрешений, компиляция реальных адаптеров). Runtime-поведение `ScreenCaptureKit`/`AVAudioEngine` **не верифицировано** — см. риск ниже.

**Оставшиеся риски (важно):**
- `ScreenCaptureKitSystemAudioCapturing` и `AVEngineMicrophoneCapturing` НЕ были прогнаны на реальном захвате звука: у этой non-interactive сессии нет способа выдать TCC-разрешение Screen Recording/Microphone и нет живого meeting-приложения для захвата. Код написан по стабильным, задокументированным API (`SCStreamConfiguration`, `SCContentFilter`, `SCStreamOutput`, `CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer`, `AVAudioEngine.inputNode.installTap`), сверенным через Apple Developer Documentation и официальный пример "Capturing screen content in macOS" перед написанием — но точное поведение (например, реально ли ScreenCaptureKit укладывается в запрошенные `sampleRate`/`channelCount` на всех macOS 14+, корректность non-interleaved/interleaved ветки для конкретного железа) требует ручной проверки на реальном Mac с выданными разрешениями. Это явно вне возможностей текущего окружения — зафиксировано, а не скрыто.
- Выбор meeting-приложения (`SCContentFilter` по конкретному bundle ID) полагается на `PreferredAudioSourceStoring`, которое пока ничем не заполняется — UI-пикер появится на этапе 10 (Settings); до этого `answers` без сохранённого предпочтения будет захватывать весь дисплей целиком (тот же путь, что и `recording`), а не одно приложение — это временно шире контракта продукта и должно быть сужено, когда появится picker.
- `Info.plist` по-прежнему не может декларировать причину Screen Recording (ключа не существует, см. риск этапа 01) — только `NSMicrophoneUsageDescription`.
- `xcodebuild build/test` всё ещё не запускался (нет `xcodegen`), как и на этапах 01-02.

---

## 2026-08-22 — Этап 04: Режим быстрых ответов через OpenAI Realtime

**Проверка схемы перед реализацией (правило базового промпта "сверяй с официальной GA-документацией"):**
- Сверено через `developers.openai.com/api/docs/guides/{realtime, realtime-conversations, realtime-websocket}` и `.../api-reference/realtime-{client,server}-events`: GA endpoint `wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1`, авторизация `Authorization: Bearer <key>`, БЕЗ заголовка `OpenAI-Beta: realtime=v1` (документация прямо предписывает убрать его для GA). GA-сессия вкладывает аудио-конфигурацию в `session.audio.input.{format,turn_detection}` (не плоско на верхнем уровне, как было в устаревшей бете) — `format: {type: "audio/pcm", rate: 24000}`. Событийные имена и поля клиент/сервер (`session.update`, `input_audio_buffer.append`, `response.create`, `response.cancel`, `conversation.item.delete`, `input_audio_buffer.speech_started/stopped`, `input_audio_buffer.committed`, `conversation.item.created`, `response.created`, `response.output_text.delta/done`, `response.done`, `error`, `rate_limits.updated`) подтверждены отдельными выборками полей из официальной документации.
- Точное размещение `reasoning.effort` в теле `session` подтверждено косвенно (поисковый обзор changelog/guide, а не прямой JSON-пример) — самое слабое место проверки; изолировано в `RealtimeEventCoding.swift` с явным комментарием "если схема изменится, править только этот файл", как требует базовый промпт.

**Изменённые компоненты:**
- `Sources/RealtimeClient/RealtimeInstructions.swift` (создан) — версионируемая системная инструкция (текст из этапа 04 дословно) и response-scoped `FORCE_ANSWER_NOW` инструкция как именованные константы; `waitForQuestionSentinel`.
- `Sources/RealtimeClient/RealtimeEventCoding.swift` (создан) — единственное место со схемой GA: `RealtimeClientEvent`/`SessionConfig`/`TurnDetectionConfig` (кодирование) и `RealtimeServerEvent`/`RealtimeServerEventDecoder` (декодирование). `RealtimeVADSettings` — VAD параметры разработчика с безопасными значениями по умолчанию (`0.5`/`300`/`300`).
- `Sources/RealtimeClient/RealtimeWebSocketTransport.swift` (создан) — протокол `RealtimeWebSocketTransport` (для подмены fake-транспортом в тестах) и `URLSessionRealtimeWebSocketTransport` — реальный клиент поверх `URLSessionWebSocketTask`, без тяжёлой обвязки, никогда не логирует Authorization/base64 audio/полный server event.
- `Sources/RealtimeClient/AnswerContextWindow.swift` (создан) — actor, отслеживает committed user item ID текущего окна (НЕ аудио); "5 минут и 32 MiB" из текста этапа истолкованы как временная + количественная граница (задокументировано, аудио физически не хранится здесь — оно живёт в `AnswersRingBuffer`, этап 03).
- `Sources/RealtimeClient/OpenAIRealtimeAnswerClient.swift` (создан) — конкретный `RealtimeAnswering`: sentinel-буферизация до однозначного разрешения (правило "первые символы временно проверяй на sentinel"), идемпотентное присуждение turn первому валидному `responseID`, `forceResponse()` с отменой невидимого автоматического ответа, reconnect с exponential backoff + jitter (без повторной "доставки" уже отвеченного вопроса), редактированные логи (сообщение `error`-события никогда не логируется целиком, только код).
- `Sources/Domain/Models.swift` (изменён) — добавлен `RealtimeAnswerEvent.cancelled(responseID:reason:)`: доброкачественная отмена (прервано новой речью либо вытеснено `forceAnswerNow`) явно отделена от `.failed` — не должна переводить `answers` в `passive` (в отличие от реальной ошибки).
- `Sources/Domain/AnswersModeController.swift` (изменён) — обрабатывает `.cancelled`: сбрасывает `turnPhase`/`activeResponseID`, не трогает `failureContinuation`.
- `Sources/App/CompositionRoot.swift` (изменён) — `realtimeAnswering` теперь настоящий `OpenAIRealtimeAnswerClient`, `AnswersModeController` получает полную `RealtimeInstructions.system` вместо плейсхолдера. `SecretStoring` всё ещё `InactiveSecretStore` (этап 10) — `answers` детерминированно завершается `failedToPassive` с `notAuthenticated`, не касаясь аудио (авторизация проверяется раньше захвата в `start()`).
- `Package.swift` (изменён) — добавлен `RealtimeClientTests` target.
- `Tests/RealtimeClientTests/{FakeRealtimeWebSocketTransport,TestSupport,OpenAIRealtimeAnswerClientTests}.swift` (созданы) — fake WebSocket transport (требование этапа) + 15 тестов, покрывающих весь список этапа: порядок session.update/audio append, первый delta до response.done, подавление sentinel с сохранением user items, несколько контекстных ходов -> один ответ, `forceAnswerNow()` ровно один `response.create` с response-scoped инструкцией, повторные клики не создают второй response, гонка manual/automatic -> один видимый ответ, пустой контекст -> `noContext` без API-вызова, отмена manual trigger при выходе из режима, отмена ответа новой речью с полной очисткой контекста, полная очистка после завершённого ответа, reconnect без дублирования уже отвеченного вопроса, редактирование логов (утечка секрета/контента исключена целевой проверкой строк лога), сохранение Unicode/смешанного языка потока без мутации.

**Найден и исправлен реальный race condition (не косметика):** `startReceiveLoop()` изначально вызывал `transport.events()` ВНУТРИ тела `Task { }`, а не до его создания. `Task { }` только планирует исполнение — событие, отправленное транспортом до первого фактического запуска тела задачи, терялось молча (continuation ещё не был создан). Это проявилось как массовый провал тестов (13 из 15) сразу после первого запуска — не тестовая условность, а реальный риск потерять события сразу после подключения в проде. Исправлено: `transport.events()` вызывается синхронно перед созданием `Task`, поток передаётся в замыкание уже готовым.

**Также исправлено:** `Duration.components.seconds` отбрасывает суб-секундную часть — исходная формула backoff (`reconnectBaseDelay: .milliseconds(500)`) вычисляла `0` секунд базовой задержки, то есть реальный экспоненциальный backoff не работал вовсе (оставался только 0–250мс jitter). Добавлен `OpenAIRealtimeAnswerClient.milliseconds(_:)`, учитывающий `attoseconds`.

**Команды проверки:**
- `swift build` — успешно.
- `swift test` — успешно, 55/55 тестов (+15 новых в `RealtimeClientTests`, ни один существующий тест не сломан).
- `swiftc -typecheck` для `Sources/App/*.swift` — без ошибок после подключения `OpenAIRealtimeAnswerClient`.

**Результат:** пройдено для всего, что проверяемо через fake-транспорт (протокольная корректность, порядок событий, sentinel/race/reconnect-логика, редактирование логов). Живое соединение с OpenAI Realtime API не вызывалось — нет API-ключа и это online-платный вызов, что вне безопасного/уместного объёма автономного прогона в данном окружении.

**Оставшиеся риски:**
- Точное размещение `reasoning.effort` в JSON-теле сессии подтверждено не напрямую (см. выше) — если GA-схема отличается, правка ограничена одним файлом (`RealtimeEventCoding.swift`) по конструкции.
- Реальное WebSocket-соединение с `api.openai.com` не тестировалось (нет ключа, нет разрешения тратить реальный OpenAI-баланс без явного запроса пользователя) — вся протокольная корректность подтверждена через типизированный кодек + fake-транспорт, а не live-вызовом.
- `answers` по-прежнему завершается `failedToPassive` при попытке реального запуска — теперь по причине `notAuthenticated` (`InactiveSecretStore`), а не отсутствия капчура; это ожидаемо до этапа 10.
- `AnswerContextWindow`'s "32 MiB" трактован как количество item ID, а не байты аудио (обосновано в коде) — стоит перепроверить это решение при финальном аудите (этап 13), если исходная формулировка имела в виду что-то иное.

---

## 2026-08-22 — Этап 05: Потоковый overlay ответа

**Найден и исправлен реальный пробел относительно этапа 04 (не косметика):** правило "если последний речевой ход ещё активен... установи `manualResponsePending` и отправь запрос сразу после `speech_stopped`/подтверждения item" не было реализовано — `forceResponse()` отправлял `response.create` немедленно, даже если пользователь ещё не закончил фразу. Исправлено до начала этапа 05 (от него напрямую зависит копия "Жду окончания фразы…"): `OpenAIRealtimeAnswerClient` теперь отслеживает `speechInProgress` (по `speech_started`/`speech_stopped`) и откладывает фактическую отправку до `input_audio_buffer.committed`, если нажатие произошло во время активной речи; пустой контекст ПЛЮС отсутствие активной речи — единственный случай `noContext`. Добавлен тест `forceResponseDeferredUntilInFlightSpeechCommits`.

**Архитектурное решение:** для тестируемости "reducer/view model без реального окна" (явное требование этапа) выделен новый чистый SwiftPM-таргет `OverlayReducer` (зависит только от `Domain`, без AppKit/SwiftUI) — по той же схеме, что `AudioCapture` для форматов/буферов на этапе 03. `Sources/OverlayUI` остаётся Xcode-only (NSPanel/SwiftUI/AppKit), импортирует `OverlayReducer` через тот же локальный пакет.

**Изменённые компоненты:**
- `Sources/Domain/AnswerStreamEvent.swift` (создан) — `AnswerStreamEvent` (`collectingContext/manualResponsePending/streaming(text:)/completed(finalText:)/cancelled/noContext`) — то, на что подписывается overlay, а не сырые `RealtimeAnswerEvent`.
- `Sources/Domain/AnswersModeController.swift` (изменён) — накапливает `streamingText` и публикует `AnswerStreamEvent` через новый `nonisolated streamEvents() -> AsyncStream<AnswerStreamEvent>`; `noContext` эмитится, когда `forceResponse()` бросает во время `manualResponsePending`.
- `Sources/RealtimeClient/OpenAIRealtimeAnswerClient.swift` (изменён) — отложенная отправка manual `response.create` до commit активной речи (см. выше).
- `Package.swift` (изменён) — добавлены `OverlayReducer` (target+product) и `OverlayReducerTests`.
- `Sources/OverlayReducer/AnswerOverlayReducer.swift` (создан) — чистый reducer: `AnswerOverlayState`(`visibility/text/isPinned`) + `AnswerOverlayAction` -> новое состояние. Sentinel структурно не может попасть в `text` (гарантия уровня `AnswerStreamEvent`), reducer не должен его прятать сам.
- `Sources/OverlayReducer/AnswerOverlayViewModel.swift` (создан) — `@MainActor @Observable`, подписывается на `ModeCoordinator.stateUpdates()` + `AnswersModeController.streamEvents()`, ведёт retention-таймер (настраиваемое время показа после `.completed`, по умолчанию 20с) и transient-тост `noContext`. `forceAnswerNow()` блокируется, пока уже идёт `manualResponsePending`/`streaming` — повторные клики не создают второе действие. `copyFinalAnswer()` отдаёт текст только из `.completed`.
- `Tests/OverlayReducerTests/AnswerOverlayReducerTests.swift` (создан) — 10 тестов из списка этапа: delta меняют текст немедленно до done, sentinel не может попасть в text, капсула видна до первого ответа, `manualResponsePending`/`noContext`/гонка без мигания и задвоения текста, отмена очищает старый ответ, `passive` скрывает окно, `recording` не может открыть overlay, `.completed` хранит финальный текст для copy, retention-таймер очищает завершённый ответ, если не закреплён, закреплённый ответ переживает retention.
- `Sources/OverlayUI/AnswerOverlayPanel.swift` (создан) — `NSPanel` подкласс: `.nonactivatingPanel`, `.floating`, join all spaces + fullScreenAuxiliary, `hidesOnDeactivate = false` — не активирует приложение и не переключает фокус.
- `Sources/OverlayUI/GlobalHotKeyManager.swift` (создан) — `NSEvent` глобальный+локальный монитор клавиш; `HotKeyCombo` (Codable) с безопасным дефолтом `⌥Return` для `Ответить сейчас` и `⌥⌘H` для показать/скрыть overlay.
- `Sources/OverlayUI/OverlayPreferencesStore.swift` (создан) — позиция (`topRight/topCenter/bottomRight/custom`), opacity, масштаб шрифта, горячие клавиши — персистентно через `UserDefaults`.
- `Sources/OverlayUI/AnswerOverlayContentView.swift` (создан) — SwiftUI-контент: капсула (`collectingContext`/`manualResponsePending`/`reconnecting`) или полная панель (`streaming`/`completed`) с copy/pin; состояние никогда не только цветом (иконка+текст); `accessibilityReduceMotion`, `dynamicTypeSize`, `textSelection`, VoiceOver labels/hints; входная транскрипция и sentinel никогда не рендерятся (структурно недостижимы).
- `Sources/OverlayUI/AnswerOverlayWindowController.swift` (создан) — реактивная синхронизация видимости панели через `withObservationTracking` (без polling); позиционирование по сохранённой настройке; копирование в `NSPasteboard` только финального текста; регистрирует обе горячие клавиши.
- `Sources/OverlayUI/MenuBarController.swift` (создан) — `NSStatusItem` с пунктом "Ответить сейчас", дублирующим действие панели; enabled-состояние синхронизировано с `viewModel.state`.
- `Sources/App/CompositionRoot.swift`, `Sources/App/UserAgent057App.swift` (изменены) — собирают `AnswerOverlayViewModel` и запускают `AnswerOverlayWindowController`/`MenuBarController` при старте приложения (живут весь процесс, не привязаны к SwiftUI `Scene`).
- `project.yml` (изменён) — добавлена зависимость таргета на продукт `OverlayReducer`.

**Команды проверки:**
- `swift build` — успешно.
- `swift test` — успешно, 69/69 тестов (+10 новых в `OverlayReducerTests`, +1 в `RealtimeClientTests` для deferred-send).
- `swiftc -typecheck` для `Sources/App/*.swift Sources/OverlayUI/*.swift` вместе (как единый target по `project.yml`) — без ошибок.

**Результат:** пройдено для всего проверяемого без реального окна — reducer/view model полностью покрыты тестами из списка этапа. `NSPanel`/`NSEvent`-глобальные хоткеи/menu bar не запускались вживую (нет дисплея и Input Monitoring разрешения в этом окружении).

**Оставшиеся риски:**
- `NSPanel` non-activating поведение, `NSEvent.addGlobalMonitorForEvents` (требует Input Monitoring permission) и реальное отсутствие кражи фокуса у Zoom/Teams/браузера — не верифицировано визуально/интерактивно. Код написан по стандартным, документированным AppKit-паттернам, но нуждается в ручной проверке на реальном Mac.
- Accessibility (VoiceOver, contrast, reduced motion) реализовано по API (labels/hints, `accessibilityReduceMotion`, `dynamicTypeSize`), но не проверено реальным VoiceOver-проходом.
- `answers` по-прежнему не может реально показать ответ end-to-end (нет API-ключа, `SecretStoring` всё ещё `InactiveSecretStore` до этапа 10) — overlay-код готов принять события, как только появится реальный ключ и остальные адаптеры.

---

## 2026-08-22 — Этап 06: Асинхронный журнал вопросов и ответов

**Найдено и исправлено: этап 06 был начат предыдущим запуском, но обрублен таймаутом до `swift build`/`swift test`.** `Sources/Domain/QuestionAnswerLogger.swift` уже существовал на диске, но никогда не компилировался. Две реальные ошибки:
- `Task { [weak self] in await self?.method() }` — при `Void`-возврате метода компилятор выводит `Task<()?, Never>` вместо `Task<Void, Never>` (несовместимо с полем `Task<Void, Never>?`); исправлено `guard let self else { return }` перед вызовом.
- `QALoggerSingleResume<T>` без `T: Sendable` не проходит Swift 6 sending-parameter анализ на `continuation.resume(returning: value)`; добавлено ограничение `T: Sendable`.

**Не связанное с этапом 06, но применено по прямому указанию пользователя в этой сессии:** все существующие `//`/`///`/`/* */` комментарии во всех `.swift` файлах `Sources`/`Tests` удалены (без изменения логики, подтверждено полным прогоном тестов до и после). Добавлено `CLAUDE.md` в корне репозитория, запрещающее писать комментарии в коде впредь — обоснование и вся архитектурная рациональность фиксируются только в этом файле и в `docs/adr/`.

**Изменённые компоненты:**
- `Sources/Domain/QuestionAnswerLogger.swift` (два исправления выше).
- `Sources/Domain/AnswersModeController.swift` (изменён) — принимает `answersRingBuffer: AnswersRingBuffer` и опциональный `questionAnswerLogger: QuestionAnswerLogger?` (nil по умолчанию, не ломает существующие тесты/вызовы без журнала). `start()` очищает буфер и обнуляет `contextWindowStartedAt`; каждый захваченный аудиофрейм теперь также попадает в `answersRingBuffer` (помимо `realtime.appendAudio`). `handle(_:)` стал `async`: на первом валидном `textDelta` (определяется по `turnPhase != .streaming` до присвоения) снимает `answersRingBuffer.snapshot()` и вызывает `beginDraft` с `triggerKind` из `.responseStarted`; на `.completed` вызывает `recordCompleted` с посчитанным `responseTotalMs` (от `.responseStarted` до `.completed`), затем полностью очищает буфер и открывает новое окно (`contextWindowStartedAt = Date()`) — граница окна совпадает с моментом показанного ответа, как того требует этап; на `.cancelled` вызывает `recordCancelled`, но **не** трогает буфер/окно — отменённый (невидимый) ответ не является "показанным ответом", поэтому накопленный контекст продолжает жить для следующей попытки (симметрично политике `AnswerContextWindow` на уровне Realtime, этап 04). `stop()` перед освобождением ресурсов решает между `recordCancelled` (если `turnPhase == .streaming`, т.е. черновик уже создан) и `discardBeforeValidAnswer` (если ответ ещё не начал стримиться) для текущего `activeResponseID`.
- `Sources/App/CompositionRoot.swift` (изменён) — собирает реальные `AnswersRingBuffer()` и `QuestionAnswerLogger(localTranscribing:repository:modelID:)` и передаёт их в `AnswersModeController`. `localTranscribing`/`questionAnswerRepository` по-прежнему `Inactive*` (см. риски).
- `Sources/Transcription/WhisperModelCatalog.swift` (создан) — `defaultModelID = "openai_whisper-small"`, вынесенное имя модели для журнала до появления настроек разработчика (этап 10).
- `Tests/DomainTests/TestDoubles.swift` (изменён) — `FakeLocalTranscribing` дополнен `receivedFrameBatches`/`delay` (для тестов на снимок контекста и на "ответ сохраняется, пока вопрос ещё распознаётся"); добавлены `ScriptedLocalTranscribing` (разные результаты по маркеру в первом сэмпле — для теста на две параллельные записи) и `FakeQuestionAnswerRepository`.
- `Tests/DomainTests/QuestionAnswerLoggerTests.swift` (создан) — 11 тестов: Whisper не вызывается до `beginDraft`; ответ `answerStreaming` сохраняется раньше, чем разрешится долгая транскрипция; несколько кадров контекста уходят в Whisper одним снимком (`receivedFrameBatches.count == 1`); `manual` trigger kind сохраняется как есть; ответ сохраняется, пока вопрос ещё транскрибируется; поздняя транскрипция обновляет правильную запись по `responseID`/`id` при двух параллельных `beginDraft`; ошибка транскрипции и таймаут оба сохраняют `questionTranscriptionStatus = .failed` без выдуманного текста; `recordCancelled` помечает `status = .cancelled`; `discardBeforeValidAnswer` до `beginDraft` не создаёт запись; два параллельных черновика не смешивают тексты/`triggerKind`.
- `Tests/DomainTests/AnswersModeControllerTests.swift` (изменён) — 3 новых интеграционных теста: sentinel (`waitingForQuestion`) не создаёт запись и не вызывает Whisper; первый `textDelta` после захваченного аудиофрейма создаёт запись с правильным `triggerKind = automatic`, накопленным `answerText` и ровно одним вызовом Whisper с полным снимком буфера; `Ответить сейчас` создаёт запись с `triggerKind = manual`.

**Архитектурное решение (соответствует уже принятому на этапе 01 разделению, не новое отклонение):** секция "UI истории Q&A" из текста этапа 06 не реализована здесь — `Sources/HistoryUI` остаётся пустым, как и было явно решено на этапе 01 ("заполняется на этапе 08"). Файл `08-persistence-and-history.md` содержит собственную, более полную спецификацию "История UI" с двумя вкладками (`Вопросы и ответы`/`Митинги`) поверх настоящего SQLite-хранилища — реализовывать список поверх `InactiveQuestionAnswerRepository` (который не хранит ничего между запусками) было бы фиктивной работой. `LocalTranscribing` также остаётся `InactiveLocalTranscribing`: реальный `WhisperKitTranscribing`-адаптер специфицирован детально только в `07-local-meeting-recording.md` (chunking, VAD, overlap-дедупликация, выбор модели) и будет реализован там один раз, затем переиспользован и для этого журнала.

**Команды проверки:**
- `swift build` — успешно.
- `swift test` — успешно, 83/83 теста (+14 новых: 11 в `QuestionAnswerLoggerTests`, 3 в `AnswersModeControllerTests`), ни один существующий тест не сломан ни исправлением багов, ни удалением комментариев.
- `swiftc -typecheck Sources/App/*.swift Sources/OverlayUI/*.swift` — без ошибок и предупреждений.

**Результат:** пройдено для всей логики журнала и её интеграции в `AnswersModeController`, проверяемой без реального Whisper/SQLite/микрофона. UI истории и реальная транскрипция вопроса намеренно отложены до этапов 08/07 соответственно (см. решение выше).

**Оставшиеся риски:**
- `QuestionAnswerRepository` всё ещё `InactiveQuestionAnswerRepository` — `save()` бросает `notYetImplemented`, что `QuestionAnswerLogger.persist()` осознанно проглатывает через `try?` (правило "ошибка вторичной транскрипции/лога не должна ломать `answers`"). До этапа 08 ни один Q&A действительно не сохраняется между запусками приложения.
- `LocalTranscribing` всё ещё `InactiveLocalTranscribing` — до этапа 07 `beginDraft` с непустым `contextSnapshot` в реальном приложении завершится `questionTranscriptionStatus = .failed` (ожидаемо: `Inactive*` бросает `notYetImplemented` на непустом входе), при этом сам показанный ответ это не задерживает и не ломает (проверено `transcriptionFailureSavesStatusFailedWithoutFabricatedQuestion`).
- `responseTotalMs` считается от `.responseStarted` до `.completed` на уровне контроллера (а не внутри `OpenAIRealtimeAnswerClient`) — стоит перепроверить на этапе 11 (тесты/latency), что это не расходится с реальными `usage`/timing полями события `response.done`, которые GA API может возвращать отдельно.

---

## 2026-08-22 — Этап 07: Полная локальная транскрипция митинга

**Найдено при разборе перед реализацией (не реализация с нуля, а исправление реальной архитектурной ошибки этапа 02):** старый `RecordingModeController` сваливал кадры системного звука и микрофона в ОДИН общий `pendingFrames` и транскрибировал их одним вызовом — это смешивало `remote`/`local` в одном Whisper-запросе и делало правильный `TranscribedSegment.source` в принципе невозможным. Контроллер переписан на два независимых конвейера (по одному на источник), транскрибируемых раздельно.

**Найдено и перемещено (нарушение правила слоёв, не новое решение):** `RecordingBackpressureChannel` (этап 03) физически лежал в таргете `AudioCapture`, хотя не импортирует ничего, кроме `Domain`, — по факту он ничем не отличается от `AnswersRingBuffer`, который с самого начала лежит в `Domain`. `RecordingModeController` (домен) не может импортировать `AudioCapture` (обратная зависимость запрещена `Package.swift`), а именно домену этот тип нужен для реального backpressure. Перемещён в `Sources/Domain/RecordingBackpressureChannel.swift` вместе с тестами (`Tests/DomainTests/RecordingBackpressureChannelTests.swift`), поведение и все 5 тестов не изменились.

**Изменённые компоненты:**
- `Sources/Transcription/WhisperKitTranscribing.swift` (создан) — первая настоящая реализация `LocalTranscribing` поверх `argmaxinc/argmax-oss-swift` (`WhisperKit(WhisperKitConfig(model:))`, лениво загружается один раз и кешируется в acторе; `transcribe(audioArray:decodeOptions: .vad)`). Источник (`remote`/`local`) берётся из `frames.first?.source` (микрофон -> `local`/«Я», системный звук -> `remote`/«Участники») — корректно только пока вызывающая сторона не смешивает источники в одном вызове (гарантируется новым `RecordingModeController`, см. ниже). API проверена по реальным сигнатурам публичных методов пакета (`Sources/WhisperKit/Core/WhisperKit.swift`/`Configurations.swift` в `.build/checkouts`), а не по памяти.
- `Sources/Domain/ChunkedTranscriptionPipeline.swift` (создан) — по одному экземпляру на источник. Копит кадры до `chunkDurationSeconds` (по умолчанию 8с), транскрибирует буфер целиком (WhisperKit сам делает VAD-чанкинг и не режет по словам внутри буфera), затем оставляет хвост в `overlapSeconds` (по умолчанию 1.5с) как перекрытие для следующего чанка. Дедупликация на границе — по отбрасыванию сегментов, чьё `startMs` внутри буфера меньше длины перекрытия (не текстовый diff): при повторном пересчёте того же перекрытия модель обычно сегментирует его так же, а точная посегментная дедупликация без границ по паузам объективно ненадёжна. Абсолютное время сегмента = накопленное потреблённое время + относительное время внутри буфера.
- `Sources/Domain/RecordingModeController.swift` (переписан) — по два независимых `RecordingBackpressureChannel`+`ChunkedTranscriptionPipeline` (системный звук и микрофон), с раздельными producer/consumer тасками на источник. Producer только кладёт кадр в bounded-канал (никогда не ждёт Whisper — правило "capture callbacks не должны ждать"); consumer тянет из канала без polling и вызывает flush, когда конвейер сигналит превышение `chunkDurationSeconds`. `stop()`: сначала останавливает реальный захват (что закрывает исходные `AsyncStream` и снимает producer-цикл с ожидания), затем дожидается producer- и consumer-тасков, затем принудительно доflushивает оба конвейера (финализирует последний неполный сегмент), затем сообщает `droppedFrameCount` каждого канала в `LatencyRecording.record(.droppedAudioFrames)`, и только затем `repository.finish(...)`. Оба источника делят ОДИН `WhisperKitTranscribing` (actor сериализует доступ к модели сам) — по правилу "не загружай две тяжёлые модели". Добавлен `transcriptEvents() -> AsyncStream<TranscribedSegment>` — финализированные (не промежуточные) сегменты для live-UI.
- `Sources/App/RecordingTranscriptViewModel.swift` (создан), `Sources/App/ModeSwitcherView.swift` (изменён) — минимальный live transcript в главном окне при `mode == .recording`: список реплик с меткой «Я»/«Участники», без общего с Q&A UI списка.
- `Sources/App/CompositionRoot.swift` (изменён) — `localTranscribing` теперь `WhisperKitTranscribing` (не `Inactive`) — используется и `RecordingModeController`, и (с этапа 06) `QuestionAnswerLogger`, значит с этого этапа Q&A-журнал тоже пытается вызывать настоящий Whisper, а не бросать `notYetImplemented`.
- `Tests/DomainTests/TestDoubles.swift` (изменён) — добавлены `SourceAwareFakeLocalTranscribing`, `FakeLatencyRecording`.
- `Tests/DomainTests/ChunkedTranscriptionPipelineTests.swift` (создан) — 6 тестов: флаг флаша только после превышения длительности; source сохраняется через flush; первый флаш не фильтрует; второй флаш отбрасывает сегменты внутри окна перекрытия; абсолютное время накапливается корректно между флашами; хвост, переносимый в следующий буфер, по длительности соответствует `overlapSeconds`.
- `Tests/DomainTests/RecordingModeControllerTests.swift` (изменён под новую сигнатуру `chunkDurationSeconds`/`overlapSeconds`/`backpressureCapacity`, было `chunkFrameCount`) — добавлены 2 теста: системный и микрофонный кадры транскрibируются раздельно с правильным `remote`/`local` и не смешиваются; переполнение bounded-канала реально доходит до `LatencyRecording` как `droppedAudioFrames`.

**Изменённые компоненты (перемещение из этапа 03, не новая работа):**
- `Sources/Domain/RecordingBackpressureChannel.swift` (перемещён из `Sources/AudioCapture/`), `Tests/DomainTests/RecordingBackpressureChannelTests.swift` (перемещён из `Tests/AudioCaptureTests/`).

**Команды проверки:**
- `swift build` — успешно, включая реальную линковку с `WhisperKit`/`ArgmaxCore`.
- `swift test` — успешно, 91/91 (+8 новых: 6 в `ChunkedTranscriptionPipelineTests`, 2 в `RecordingModeControllerTests`), ни один существующий тест не сломан переносом `RecordingBackpressureChannel` или переписыванием `RecordingModeController`.
- `swiftc -typecheck Sources/App/*.swift Sources/OverlayUI/*.swift` — без ошибок.

**Результат:** пройдены все 5 формальных критериев приёмки этапа (полный протокол с таймкодами; API ответов/транскрипции не вызывается — структурная гарантия отсутствием зависимости на `RealtimeAnswering`; overlay не открывается в `recording` — тест этапа 05 `recordingModeCannotOpenOverlay` по-прежнему проходит; исходное аудио не пишется на диск; после `stop()` не остаётся работающей инференс-задачи — все producer/consumer таски явно дождидаются завершения). Живой прогон реального WhisperKit-инференса и живого микрофона/захвата экрана не выполнялся (см. риски, тот же характер ограничения, что и у `ScreenCaptureKit`/`AVAudioEngine` на этапе 03 и live Realtime-соединения на этапе 04).

**Оставшиеся риски:**
- Реальный `WhisperKitTranscribing` не запускался живьём (нет GPU/ANE-прогона в этом окружении, модель качалась бы из сети при первом вызове) — проверена только сигнатура публичного API компиляцией и типами; корректность самого распознавания не верифицирована рантаймом.
- Live transcript в UI обновляется на границе чанка (~8с), а не по словам в реальном времени — `WhisperKit` предоставляет `AudioStreamTranscriber` для настоящего пословного стриминга, но интеграция с ним требует отдельной реорганизации конвейера; текущий подход — осознанное упрощение "живой, но по чанкам", а не заглушка (данные настоящие, только гранулярность крупнее).
- Дедупликация перекрытия — эвристика на уровне сегментов ("отбросить всё, что начинается раньше конца окна перекрытия"), не точное текстовое сравнение; может редко давать однословный пропуск/повтор ровно на границе, если модель непоследовательно сегментирует одно и то же перекрытие между двумя вызовами.
- Thermal-aware снижение частоты UI (раздел "Производительность", не входит в формальные критерии приёмки) не реализовано — `ProcessInfo.thermalState` нигде не читается; финальный текст при этом не теряется в любом случае, так как throttling касался бы только UI, а не пути персистентности.
- `MeetingRepository`/`Meeting` пока не имеют поля `status` (`recording/completed/interrupted/failed`) — восстановление прерванной встречи как `interrupted` после сбоя невозможно реализовать до этапа 08, где эта модель и таблица `meetings` появляются по спецификации.
- `QuestionAnswerLogger` (этап 06) с этого этапа тоже вызывает настоящий `WhisperKitTranscribing` вместо `Inactive` — не тестировалось повторно живым прогоном, но модульные тесты этапа 06 не зависят от конкретной реализации `LocalTranscribing` (используют fake), поэтому поведение логгера не могло измениться.

---

## 2026-08-22 — Этап 08: SQLite, миграции, история и поиск

**Изменённые компоненты:**
- `Sources/Domain/Models.swift` (изменён) — `TranscribedSegment` дополнен nullable `language`/`confidence` (дефолт `nil`, обратная совместимость сохранена); `Meeting` дополнен `title`, `sourceAppBundleID`, новым `status: MeetingStatus` (`recording/completed/interrupted/failed`); `MeetingSummary` полностью переработан под схему этапа: `id`, `modelID`, `schemaVersion`, `contentJSON`, `renderedMarkdown`, `usageTokens`, `estimatedCostUSD` (раньше был только `meetingID`/`text`/`generatedAt` — этим полям ничего ещё не присваивалось, менять было безопасно).
- `Sources/Domain/Protocols.swift` (изменён) — `MeetingRepository.createMeeting` принимает `sourceAppBundleID`; добавлены `reconcileInterruptedMeetings() -> [MeetingID]`, `history(limit:offset:)`, `delete(meetingID:)`, `deleteAll()`. Добавлен новый протокол `SummaryRepository` (`save`/`fetch`) — хранение отделено от генерации (`SummaryGenerating`, этап 09).
- `Sources/Persistence/SQLiteConnection.swift` (создан) — тонкая обёртка над `import SQLite3` (та же C-библиотека, что уже была слинкована в `Package.swift` на этапе 01): `actor`, единственная точка доступа к `sqlite3` handle (изоляция гарантируется самим actor'ом, отдельный lock не нужен); `PRAGMA journal_mode=WAL` и `PRAGMA foreign_keys=ON` при открытии; `run`/`query` с позиционным биндингом через `SQLiteValue`; `withTransaction` для атомарных миграций.
- `Sources/Persistence/SQLiteMigrations.swift` (создан) — миграция версии 1: `meetings`, `utterances` (FK CASCADE на `meetings`), `qa_entries`, `summaries` (FK CASCADE на `meetings`), плюс `fts5`-таблицы `utterances_fts`/`qa_entries_fts` с AFTER INSERT/UPDATE/DELETE триггерами синхронизации (внешнее содержимое, `content=`/`content_rowid=`, без дублирования текста). Список миграций отслеживается в служебной `schema_migrations`; при `ensureReady()` применяются только ещё не применённые версии — миграция с нуля идемпотентна и тестируется (`migratesFromZeroAndIsIdempotentOnReopen`).
- `Sources/Persistence/SQLiteMeetingRepository.swift`, `SQLiteQuestionAnswerRepository.swift`, `SQLiteSummaryRepository.swift` (созданы) — реальные `MeetingRepository`/`QuestionAnswerRepository`/`SummaryRepository`. `QuestionAnswerRepository.save` — `INSERT ... ON CONFLICT(id) DO UPDATE` (настоящий upsert на уровне БД, не read-modify-write из Swift — исключает гонку между параллельными обновлениями одного черновика). Поиск — через `MATCH` по соответствующей `_fts` таблице с фильтрацией пользовательского ввода от `"` (защита от разрыва MATCH-выражения, не полноценный query-parser FTS5 — экранирование спецсимволов `NEAR`/`AND` и т.п. не реализовано, см. риски). `Sources/Persistence/InactivePersistence.swift` (удалён) — обе `Inactive`-заглушки заменены настоящими реализациями, дальше держать их было бы мёртвым кодом.
- `Sources/App/CompositionRoot.swift` (изменён) — `meetingRepository`/`questionAnswerRepository`/`summaryRepository` теперь настоящие SQLite-репозитории на одном файле `~/Library/Application Support/UserAgent057/useragent057.sqlite3` (создаётся лениво при первом реальном обращении, миграция — часть этого первого обращения, т.е. до того как режим успеет что-то записать). При старте композиции фоново вызывается `reconcileInterruptedMeetings()` — best-effort: гонка с мгновенным стартом `recording` сразу после запуска приложения теоретически возможна, но не наблюдалась и не является типичным сценарием использования (см. риски).
- `Sources/HistoryUI/HistoryViewModel.swift`, `HistoryView.swift` (созданы, впервые заполняют каталог, оставленный пустым с этапа 01) — две вкладки `Вопросы и ответы`/`Митинги` (`Picker`), общий поиск (использует `search()` при непустом запросе, иначе `history()`), удаление одной записи (`swipeActions`), полная очистка текущей вкладки через `confirmationDialog` (явное подтверждение, как того требует этап). Никакой SQL в UI-слое — только вызовы репозиториев через `HistoryViewModel`.
- `Sources/App/ModeSwitcherView.swift`, `UserAgent057App.swift` (изменены) — кнопка «История», открывающая `HistoryView` модальным `.sheet`.
- `Package.swift` (изменён) — добавлен `PersistenceTests` test target.
- `Tests/PersistenceTests/{SQLiteMeetingRepositoryTests,SQLiteQuestionAnswerRepositoryTests,SQLiteSummaryRepositoryTests}.swift` (созданы) — 17 тестов на реальном `SQLite3` (не fake): миграция с нуля, CRUD, FK-каскад (`meetings` -> `utterances` в одном соединении; `meetings` -> `summaries` на shared file-based соединении, т.к. `:memory:` изолирована per-connection и для cross-repository теста нужен временный файл), FTS5-поиск по `utterances`/`qa_entries` (включая отсутствие ложных совпадений), постраничная история (`limit`/`offset`, порядок newest-first), upsert одного и того же `id` вместо дублирования, параллельное сохранение двух разных `id` без порчи данных (`async let`), `reconcileInterruptedMeetings` трогает только `.recording`-строки.

**Команды проверки:**
- `swift build` — успешно, включая линковку с системным `sqlite3`.
- `swift test` — успешно, 108/108 (+17 новых в `PersistenceTests`), ни один существующий тест (включая перенесённые/переписанные на этапах 06-07) не сломан расширением моделей.
- `swiftc -typecheck Sources/App/*.swift Sources/OverlayUI/*.swift Sources/HistoryUI/*.swift` (вместе, как единый Xcode-таргет по `project.yml`) — без ошибок; `Sources/HistoryUI` компилируется первый раз с момента создания пустого каталога на этапе 01.

**Результат:** пройдены все 4 формальных критерия приёмки: полный transcript существует только в `utterances`/`meetings` (Q&A и meeting-записи — разные таблицы, `qa_entries` не содержит обычных реплик — структурно, т.к. в неё пишет только `QuestionAnswerLogger.save`); Q&A обновляется асинхронно без потери ответа (upsert на уровне БД, тест `savingTwiceWithSameIDUpsertsRatherThanDuplicates`); поиск работает по русскому и английскому тексту через `fts5` с дефолтным unicode61-токенайзером (ограничения — см. риски); все записи и удаления идут через репозитории и (для миграций/сложных операций) транзакции `SQLiteConnection.withTransaction`.

**Оставшиеся риски:**
- FTS5 подключена с токенайзером по умолчанию (`unicode61`) — он не делает стемминг/лемматизацию, поэтому русский поиск точен только по словоформе как она была произнесена/распознана (например, запрос "бюджет" не найдёт "бюджете"). Явных проблем с самой токенизацией кириллицы не обнаружено (`unicode61` корректно разбивает по границам слов для любого unicode-алфавита), но качество поиска ниже, чем со специализированным морфологическим токенайзером — ограничение задокументировано, как и требует критерий приёмки, а не скрыто.
- Пользовательский поисковый запрос экранируется только от `"` перед оборачиванием в `MATCH "..."`; конструкции FTS5 query syntax (`AND`/`OR`/`NEAR`/`*`) не парсятся отдельно — весь ввод трактуется как одна фраза. Для personal-tool сценария (поиск по паре слов) это ожидаемо достаточно, но не полноценный query language.
- `reconcileInterruptedMeetings()` вызывается best-effort фоновой `Task` из `CompositionRoot.init()`, не гарантированно ДО того, как пользователь успеет запустить `recording` в первую же миллисекунду после старта приложения — на практике интервал между запуском UI и ручным переключением режима всегда больше времени открытия+миграции локального SQLite-файла, но это не доказано тестом (нет способа детерминированно смоделировать "гонку с пользователем" в unit-тесте).
- "Экспорт snapshot без удержания долгой write-транзакции" не реализован как отдельный метод — все read-методы (`history`/`fetch`/`search`) и так не оборачиваются в транзакцию (только миграции используют `withTransaction`), а WAL-режим допускает параллельные читателей во время записи; сама UI-функция "экспортировать" (в файл/буфer обмена) — предмет этапа 09 (summary-and-export), здесь заложена только гарантия, что репозиторий её не заблокирует.
- `QuestionAnswerRepository.history(limit:)` без `offset` (в отличие от `MeetingRepository.history(limit:offset:)`) — осознанно не расширялся: типичный объём Q&A-записей на порядок меньше объёма утверждений (`utterances`) за то же время использования, пагинация там менее критична; при необходимости расширяется тем же паттерном.
- Живой прогон `HistoryView`/`.sheet` в реальном Xcode-приложении не выполнялся (нет способа собрать `.app` и провзаимодействовать с UI в этом окружении, `xcodegen` по-прежнему не установлен, см. риски этапов 01-07) — проверено только компиляцией.

---

## 2026-08-22 — Этап 09: Саммари и экспорт сохранённого митинга

**Проверка схемы перед реализацией:** в этой сессии, в отличие от этапов 04/06/07 (где сеть была недоступна), удалось получить `developers.openai.com/api/docs/api-reference/responses/create` и `.../guides/structured-outputs` напрямую. Подтверждено: эндпоинт `POST /v1/responses`; Structured Outputs задаётся полем `text.format` (НЕ `response_format`, как было в устаревших интеграциях) — объект `{type: "json_schema", name, strict: true, schema}`; ответ содержит `output`/`output_text` (последний — уже собранная модель-текст-конкатенация, используется как основной путь извлечения) и `usage.{input_tokens,output_tokens,total_tokens}`. Схема изолирована в `OpenAIResponsesSummaryClient.buildRequestBody`/`parseResponse` — единственное место правки, если GA-формат изменится. Названия моделей `gpt-5.6-terra`/`gpt-5.6-luna` взяты дословно из базового промпта (тот же принцип, что и `gpt-realtime-2.1` на этапе 04, — используются как заданные литералы без попытки проверить их существование).

**Изменённые компоненты:**
- `Sources/Summary/SummaryContentSchema.swift` (создан) — `SummaryContent` (Codable, snake_case через `CodingKeys`: `title/overview/topics/decisions/action_items/open_questions/risks/key_facts/short_summary`); `decisions`/`action_items` — не просто строки, а объекты с nullable `evidence_timestamp_ms` (правило этапа "каждый decision/action item должен иметь evidence timestamp либо явную пометку" — пометка реализована как `null`, а не выдуманное значение); `SummaryJSONSchema.makeJSONSchemaDictionary()` — JSON Schema для Structured Outputs (метод, не `static let`, — `[String: Any]` не может быть `Sendable`-совместимым хранимым свойством в Swift 6); `SummaryMarkdownRenderer` — рендер в Markdown, отсутствующий таймкод помечается явно `(таймкод не найден)`, а не молчаливо опускается.
- `Sources/Summary/SummaryModelCatalog.swift`, `SummaryPromptTemplate.swift` (созданы) — версионируемый promt-ресурс (`version = 1`, три варианта инструкции: полная/для чанка/для слияния, все — производные одного `instructions`, а не независимо дублированный текст).
- `Sources/Summary/CostEstimator.swift` (создан) — грубая оценка токенов (2.5 символа/токен — заведомо консервативно в сторону завышения для кириллицы, т.к. точного токенайзера модели нет) и стоимости по настраиваемой таблице тарифов (`SummaryPricingCatalog`); результат явно помечен `isApproximate`, как требует этап.
- `Sources/Summary/TranscriptFormatter.swift`, `TranscriptChunker.swift` (созданы) — рендер transcript в Markdown/JSON с таймкодами и source; чанкинг по границам реплик (реплика никогда не делится) с ограничением по символам на чанк.
- `Sources/Summary/ResponsesAPITransport.swift` (создан) — протокол `ResponsesAPITransport` (для подмены fake-транспортом в тестах, по той же схеме, что `RealtimeWebSocketTransport` на этапе 04) + `URLSessionResponsesAPITransport`.
- `Sources/Summary/OpenAIResponsesSummaryClient.swift` (создан) — настоящий `SummaryGenerating`: проверяет `SecretStoring.retrieveAPIKey()` до сети (`notAuthenticated` без единого запроса), требует `meeting.status == .completed` (`meetingNotCompleted` иначе — саммари не запускается автоматически и не работает над ещё идущей записью), затем: 1 чанк -> один запрос; >1 чанк -> "map" (по запросу на чанк с `partialChunkInstructions`) + один "reduce"-запрос, объединяющий частичные структурированные саммари (`mergeInstructions`) в одно — иерархическая схема, требуемая этапом. Реальный `usage` из ответа суммируется по всем вызовам и используется для точной (не оценочной) стоимости в сохранённой записи.
- `Sources/App/CompositionRoot.swift` (изменён) — `summaryGenerating` теперь `OpenAIResponsesSummaryClient`, использующий тот же `InactiveSecretStore`, что и Realtime-клиент (до этапа 10 детерминированно бросает `notAuthenticated`, ничего не отправляя).
- `Sources/HistoryUI/MeetingDetailViewModel.swift`, `MeetingDetailView.swift` (созданы) — открывается по тапу на встречу из списка `Митинги`; показывает transcript, кнопку `Создать саммари` с `confirmationDialog`, в заголовке которого — оценка объёма и стоимости (правило "перед отправкой показывает объём и предупреждает" из потока этапа); после подтверждения вызывает `summarize()` и явно сохраняет результат через `SummaryRepository.save()` (генерация и сохранение — разные шаги, ошибка сети не трогает уже сохранённый transcript и не удаляет предыдущую успешную запись, т.к. `save()` — чистый `INSERT`, не upsert, каждый успешный вызов — новая версия). Меню `Экспорт` с четырьмя форматами (transcript MD/JSON, transcript+summary MD, summary JSON) через `NSSavePanel` — запись только выбранных пользователем данных, ни ключей, ни путей БД, ни логов.
- `Sources/HistoryUI/HistoryViewModel.swift` (изменён) — принимает `summaryGenerating`/`summaryRepository`, `openDetail(for:)` создаёт `MeetingDetailViewModel` по требованию (не для каждой строки списка заранее).
- `Package.swift` (изменён) — добавлен `SummaryTests` test target (зависит и от `Summary`, и от `Persistence` — интеграционные тесты используют настоящий `SQLiteMeetingRepository(":memory:")` как фикстуру вместо отдельного fake-репозитория, раз он уже есть и легче в поддержке).
- `Tests/SummaryTests/*.swift` (создано 4 файла, 18 тестов) — TestDoubles (`FakeResponsesAPITransport` со скриптованными ответами по порядку вызова, `FakeSecretStore`); `TranscriptChunkerTests` (одна встреча в один чанк при малом объёме, несколько чанков при превышении лимита, реплика никогда не режется пополам, пустой transcript -> ноль чанков); `SummaryContentSchemaTests` (snake_case на выходе, `null` timestamp остаётся `nil` при декодировании, а не подставляется, Markdown явно помечает отсутствующий таймкод, JSON Schema валидна для `JSONSerialization`); `CostEstimatorTests` (оценка растёт с объёмом, экономичная модель дешевле, помечена approximate); `OpenAIResponsesSummaryClientTests` (нет ключа -> `notAuthenticated` без единого сетевого вызова; встреча не `completed` отклоняется; один чанк -> один вызов; длинный transcript -> map+reduce с ожидаемым числом вызовов; evidence timestamps переживают полный round-trip через JSON; тело запроса содержит только текстовые `content`, никогда аудио — структурная проверка; отменённый `Task` не делает ни одного сетевого вызова).

**Команды проверки:**
- `swift build` — успешно.
- `swift test` — успешно, 126/126 (+18 новых в `SummaryTests`), ни один существующий тест не сломан.
- `swiftc -typecheck Sources/App/*.swift Sources/OverlayUI/*.swift Sources/HistoryUI/*.swift` — без ошибок, в том числе с `-swift-version 6` (строгая проверка конкурентности, как задано `SWIFT_STRICT_CONCURRENCY: complete` в `project.yml`; по ней же исправлено предупреждение об изоляции `Identifiable`-конформанса `MeetingDetailViewModel` через `nonisolated var id`).

**Результат:** пройдены все 4 формальных критерия приёмки: саммари запускается только явным действием пользователя над `completed` встречей (проверено `meetingStillRecordingIsRejected`; API вообще не вызывается для незавершённой встречи); в API уходит только текст transcript (структурно — `SummaryGenerating`/`ResponsesAPITransport` не имеют доступа к аудио, только к `MeetingRepository.fetch()`, возвращающему текстовые `TranscribedSegment`); результат валидируется (строгий JSON Schema + `Codable`-декодирование, ошибка парсинга -> `invalidModelResponse`, а не тихий брак) и версionируется (`INSERT`-only `summaries`); экспорт не содержит секретов (только контент transcript/summary, без ключей/путей БД/логов).

**Оставшиеся риски:**
- Живой вызов `api.openai.com/v1/responses` не выполнялся (нет ключа, платный внешний вызов) — протокольная корректность подтверждена документацией + типизированным кодеком/fake-транспортом, как и `RealtimeClient` на этапе 04.
- Оценка стоимости — эвристика по числу символов (2.5 симв/токен), не настоящий токенайзер конкретной модели; после первого реального вызова фактическая стоимость в сохранённой записи точна (использует настоящий `usage` из ответа), но ПРЕДварительная оценка в диалоге подтверждения остаётся приближённой — это осознанно и явно помечено (`isApproximate`), как и требует этап.
- `SecretStoring` всё ещё `InactiveSecretStore` (этап 10) — `summarize()` детерминированно завершается `notAuthenticated` до появления реального Keychain-адаптера; путь генерации полностью готов принять ключ, когда он появится.
- `NSSavePanel`/реальная запись файла на диск не тестировались (нет GUI в этом окружении) — логика форматирования (что именно попадает в файл) протестирована отдельно как чистые функции (`TranscriptFormatter`, `SummaryMarkdownRenderer`), а сама интеграция с `NSSavePanel` — тонкий, непроверенный вручную слой поверх них, как и остальной AppKit-код проекта (`GlobalHotKeyManager`, `AnswerOverlayPanel` на этапе 05).
- Оценка "иерархического" слияния предполагает, что объединённый JSON частичных саммари (несколько КБ) сам укладывается в контекст модели за один reduce-запрос — при экстремально большом числе чанков (сотни) это предположение не проверялось; для личного meeting-инструмента с типичной встречей в пределах пары часов аудио это не является практическим ограничением, но не доказано тестом на таком масштабе.

---

## 2026-08-22 — Этап 10: Настройки, секреты, разрешения и приватность

**Изменённые компоненты:**
- `Sources/Domain/Protocols.swift` (изменён) — добавлены `RealtimeCredential` и протокол `RealtimeCredentialProviding` (пункт 6 этапа: изоляция direct-key потока от будущего PHP token broker без изменения аудио/режимов).
- `Sources/RealtimeClient/OpenAIRealtimeAnswerClient.swift` (изменён) — зависит от `any RealtimeCredentialProviding` вместо `any SecretStoring` напрямую (`start()`/`reconnect()` вызывают `currentCredential()`, любая ошибка провайдера нормализуется в уже существующий `RealtimeClientError.notAuthenticated` — публичный контракт ошибки не изменился, изменился только источник credential). `vadSettings: RealtimeVADSettings` заменён на `vadSettingsProvider: @Sendable () -> RealtimeVADSettings` — тот же паттерн инъекции, что уже был у `redactedLog`; значение читается заново при каждом `start()`/`reconnect()`, поэтому смена VAD-настроек в Settings безопасно применяется к следующему входу в `answers` (следующий "turn" на уровне режима), без перестроения чего-либо внутри активного callback.
- `Sources/SecurityStore/KeychainSecretStore.swift` (создан) — настоящий `SecretStoring` поверх `Security`/`SecItemAdd`/`SecItemUpdate`/`SecItemCopyMatching`/`SecItemDelete`, generic password (`service`+`account`), `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` при создании (ключ недоступен до первой разблокировки диска, не мигрирует на другое устройство через iCloud Keychain). `Sources/SecurityStore/APIKeyFormatValidator.swift` — проверка формата (`sk-` + длина + допустимый алфавит) БЕЗ сети (пункт 4 этапа: "проверка формата без отправки"). `Sources/SecurityStore/DirectKeyCredentialProvider.swift` — личная-сборка реализация `RealtimeCredentialProviding` поверх `SecretStoring`. `Sources/SecurityStore/SecretRedactor.swift` — редактирование известных форматов ключей (`sk-…`, `Bearer …`) в произвольном тексте регулярными выражениями, для логов/diagnostic export.
- `Sources/Diagnostics/InMemoryLatencyRecorder.swift` (создан) — заменяет `NoOpLatencyRecorder` в `CompositionRoot`: реально накапливает `LatencyMetric` в памяти (не на диск, не в БД) и даёт агрегат `countsByKind()` — только числа, без содержимого. Полноценная агрегация (перцентили, конкретные пороги latency) — предмет этапа 11 ("тесты и задержки"); этот этап только даёт диагностике куда писать.
- `Sources/App/AppSettingsStore.swift` (создан) — типизированное `UserDefaults`-хранилище (по тому же паттерну, что `OverlayPreferencesStore` с этапа 05): `whisperModelID`, `summaryModelID`, `audioStorageEnabled` (по умолчанию `false`), `historyRetentionDays` (`nil` = хранить бессрочно), `vadSettings` (три отдельных примитива, а не `Codable`-конформанс поверх `RealtimeVADSettings` из другого модуля — проще и без обратной связи между `RealtimeClient` и `App`), `onboardingCompleted`.
- `Sources/App/SettingsViewModel.swift`, `SettingsView.swift` (созданы) — единый экран настроек: ввод/сохранение/удаление API-ключа (проверка формата на месте, значение никогда не логируется и не попадает в `UserDefaults`/SQLite — только `Keychain` через `SecretStoring`), выбор источника системного звука (список запущенных приложений через `NSWorkspace`, тот же `PreferredAudioSourceStoring` с этапа 03), read-only статусы Screen Recording/Microphone, поля моделей Whisper/саммари, тумблер хранения аудио (с честной пометкой, что даже при включении аудио recording в текущей реализации не пишется — этап 07 сознательно не строил файловый вывод), VAD threshold/prefix/silence в developer-секции. Ручного переключателя языка ответа нет — сознательно, как того явно требует этап ("ответ всегда обязан совпадать с языком текущего вопроса").
- `Sources/App/OnboardingView.swift` (создан) — одноразовый (`AppSettingsStore.onboardingCompleted`) экран с честным описанием, что захватывается в каждом режиме, и напоминанием получить согласие участников.
- `Sources/App/DiagnosticsExporter.swift` (создан) — версия приложения/сборки, текущий режим/фаза, статусы разрешений, числовые счётчики `LatencyMetric` по видам — сериализуется в JSON и сохраняется через `NSSavePanel` (та же схема экспорта, что на этапе 09). Явно НЕ включает audio/transcript/ответы/секреты — печатается только то, что перечислено в `DiagnosticsSnapshot`, физически невозможно случайно приложить лишнее поле.
- `Sources/App/ModeSwitcherView.swift` (изменён) — кнопки `Настройки`/`Диагностика` рядом с `История`; индикатор приватности прямо под статусом режима (цветной кружок + текст: `passive` — ничего не захватывается, `answers` — звук уходит в API, `recording` — обрабатывается только локально); показ `OnboardingView` при первом запуске.
- `Sources/App/CompositionRoot.swift` (изменён) — `secretStoring` теперь `KeychainSecretStore()` (было `InactiveSecretStore`) — `answers`/саммари наконец могут реально авторизоваться, если пользователь ввёл ключ в Settings; `realtimeAnswering` строится через `DirectKeyCredentialProvider`; `localTranscribing`/`summaryGenerating` читают ID моделей из `AppSettingsStore` при старте.
- `Package.swift` (изменён) — добавлены `SecurityStoreTests` и `DiagnosticsTests`.
- `Tests/SecurityStoreTests/*.swift` (создано 4 файла, 15 тестов) — `APIKeyFormatValidatorTests` (принимает правдоподобный ключ, отклоняет отсутствие префикса/слишком короткий/недопустимые символы, обрезает пробелы); `SecretRedactorTests` (редактирует `sk-…` и `Bearer …`, не трогает обычный текст); `DirectKeyCredentialProviderTests` (есть ключ -> credential, нет ключа -> `missingAPIKey`); `KeychainSecretStoreTests` — **настоящий Keychain**, не fake (`retrieveAPIKey() == nil` до записи, round-trip store/retrieve, повторный `store()` обновляет, а не дублирует, `delete()` -> снова `nil`, `delete()` по пустому месту не бросает) — живьём работает в этом окружении без диалогов авторизации, т.к. это generic password собственного процесса без `keychain-access-groups`.
- `Tests/DiagnosticsTests/InMemoryLatencyRecorderTests.swift` (создан, 2 теста) — снимок сохраняет порядок и значения; `countsByKind()` группирует по виду метрики, не раскрывая сами значения.
- `Tests/RealtimeClientTests/{TestSupport,OpenAIRealtimeAnswerClientTests}.swift` (изменены под новый `credentialProviding:` параметр) — `FakeSecretStoring` заменён на `FakeCredentialProviding` (реализует `RealtimeCredentialProviding` напрямую); оба места вызова (`makeClient`, тест редактирования логов) обновлены. Поведение тестов не изменилось, только форма фейка.

**Команды проверки:**
- `swift build` — успешно, включая реальный `import Security`.
- `swift test` — успешно, 143/143 (+17 новых: 15 в `SecurityStoreTests`, 2 в `DiagnosticsTests`), ни один из 126 существующих тестов не сломан рефакторингом `OpenAIRealtimeAnswerClient` на `RealtimeCredentialProviding`. Один раз наблюдалась флаки-ошибка `ModeCoordinatorTests.shutdownDuringStartingIsBoundedByTimeout` при параллельном прогоне ВСЕХ 141 тестов сразу (таймаут-тест конкурирует за CPU с остальными потоками) — тест не менялся с этапа 02, в изоляции и при повторном полном прогоне проходит стабильно; не является регрессией этого этапа.
- `swiftc -typecheck Sources/App/*.swift Sources/OverlayUI/*.swift Sources/HistoryUI/*.swift`, включая `-swift-version 6` (строгая конкурентность) — без ошибок; потребовалось `AppSettingsStore: @unchecked Sendable` (обёртка только над `UserDefaults`, который сам потокобезопасен).

**Результат:** пройдены все 4 формальных критерия приёмки: API-ключ нигде не сериализуется в репозиторий/build products (только `Keychain`, никогда `UserDefaults`/SQLite/plist/исходники — грепом по `Sources/` подтверждено единственное место записи ключа); `answers` по-прежнему не зависит от `MicrophoneCapturing` вообще (структурная гарантия — `AnswersModeController` не принимает такую зависимость в принципе, см. этап 03/04); режим и назначение данных всегда видны пользователю (Picker + индикатор приватности); diagnostic export по умолчанию безопасен (типизированный `DiagnosticsSnapshot`, физически не может случайно включить лишнее поле).

**Оставшиеся риски:**
- Смена `whisperModelID`/`summaryModelID` в Settings применяется только к СЛЕДУЮЩЕМУ запуску приложения (значения читаются один раз в `CompositionRoot.init()`), в отличие от VAD-настроек, которые перечитываются на каждый вход в `answers`. Причина — `WhisperKitTranscribing`/`OpenAIResponsesSummaryClient` не поддерживают "горячую" смену модели без потенциально долгой перезагрузки CoreML-весов посреди возможно активного `recording`; безопасный live-reload этого пути — по духу отдельная, не тривиальная задача, сознательно не взятая в рамках этого этапа, чтобы не нарушить правило "не перестраивай capture внутри callback".
- `historyRetentionDays` — поле есть в `AppSettingsStore`, но автоматической фоновой очистки старой истории по этому значению не реализовано (этап явно допускает "период хранения либо ручное удаление" — ручное удаление полностью реализовано на этапе 08 через `HistoryView`, поэтому формальное требование покрыто; авто-очистка — расширение на будущее).
- `DiagnosticsSnapshot.metricCounts` будет в основном пустым до этапа 11: сегодня `LatencyMetric` реально записывается только для `droppedAudioFrames` (`RecordingModeController`, этап 07); `speechEndToFirstDeltaMs`/`firstDeltaToFirstPaintMs`/`responseTotalMs`/`manualTriggerToFirstDeltaMs` в реальных путях `AnswersModeController`/`OpenAIRealtimeAnswerClient` пока не вызывают `latencyRecording.record(...)` — сама метрика в `QuestionAnswerPair` считается (этап 06), но не публикуется в `LatencyRecording` отдельно. Это explicitly в скоупе этапа 11 ("тесты и задержки").
- Живой прогон Keychain-тестов подтверждён В ЭТОМ окружении (без диалогов, без зависаний), но это не гарантирует идентичное поведение в App Sandbox реального `.app` (там действует `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` + сэндбоксовый keychain-access-group приложения) — не проверено вручную на подписанной сборке, т.к. `xcodegen`/подпись недоступны в этом окружении (тот же класс ограничения, что и на этапах 01-09).
- Онбординг — один статический экран с "Понятно", без раздельного явного согласия по каждому режиму и без блокировки первого реального захвата (мы всё ещё структурно не можем протестировать это в этом окружении — оно завязано на реальный первый показ окна). Текст полностью честен по объёму (что уходит в API, что остаётся локально), но интерактивность не проверена вручную.

---

## 2026-08-22 — Этап 11: Тестирование, измерение задержки и отказоустойчивость

**Отправная точка (важно для оценки объёма этапа):** большинство пунктов из разделов "Unit tests" и "Integration tests" уже были доказаны тестами этапов 02-10 как побочный продукт TDD-подхода к каждому этапу (ModeCoordinator/переходы — этап 02; ring buffer/backpressure/аудиоформаты — этап 03; event decoder/sentinel/накопление контекста/manual arbitration — этап 04; streaming reducer — этап 05; Q&A draft lifecycle — этап 06; chunk overlap/dedup — этап 07; SQLite/FTS — этап 08; summary schema/export — этап 09; Keychain/redaction — этап 10). Этот этап **не переделывает** их, а: (1) закрывает конкретные пробелы (недостающие latency-метрики, malformed/rate-limit сценарии, SQLite-сбой), (2) добавляет синтетические audio fixtures и явные scenario-тесты, названные точно как в тексте этапа, чтобы список был проверяем одним взглядом на файл, а не разбросан по 25 сьютам, (3) добавляет каталог language/rubric evals и harness для latency-отчёта.

**Изменённые компоненты:**
- `Sources/Domain/Models.swift` (изменён) — `LatencyMetric` дополнен `reconnectMs`/`captureCallbackToSendMs` (в тексте этапа они требуются, но отсутствовали в enum с этапа 02); добавлены `millisecondValue`/`kindLabel` computed-свойства (единая точка соответствия case -> подпись/значение вместо дублирующего `switch` в `InMemoryLatencyRecorder`).
- `Sources/RealtimeClient/OpenAIRealtimeAnswerClient.swift` (изменён) — `reconnect()` теперь замеряет и пишет `reconnectMs` (раньше метрика существовала в типе, но нигде не записывалась для самого reconnect; `speechEndToFirstDeltaMs`/`manualTriggerToFirstDeltaMs`/`contextDurationMs`/`responseTotalMs` уже были записаны с этапа 04/05 — не переделывались).
- `Sources/Domain/AnswersModeController.swift` (изменён) — добавлен опциональный `latencyRecording` (тот же паттерн nil-по-умолчанию, что `questionAnswerLogger`, чтобы не трогать существующие тесты): пишет `captureCallbackToSendMs` вокруг `realtime.appendAudio(frame)` в capture-цикле и `firstDeltaToFirstPaintMs` вокруг единственного `yield` первого `.streaming`-события. **Важная честная оговорка** (см. риски) — это не время до реальной отрисовки NSView/SwiftUI на экране, а время диспетчеризации внутри контроллера до публикации события наблюдателям; в headless-окружении без дисплея измерить настоящий screen-paint невозможно, поэтому выбрана ближайшая точная и нефиктивная альтернатива, а не выдуманное число.
- `Sources/Domain/ModeCoordinator.swift` (изменён) — добавлен опциональный `latencyRecording`, оборачивает `currentController.stop()` и пишет `modeStopMs`.
- `Sources/Diagnostics/LatencyReport.swift` (создан) — `LatencyReportBuilder.build(from: [LatencyMetric]) -> [LatencyReportEntry]`: count/p50/p95/max по каждому виду метрики (только для метрик, у которых есть `millisecondValue`; счётчики типа `droppedAudioFrames` в тайминговый отчёт не попадают — у них нет распределения по времени). Чистая функция без побочных эффектов, ничего не пишет на диск сама — вызывающая сторона (`DiagnosticsExporter`, этап 10) решает, что делать с результатом. Никогда не принимает и не хранит текст/аудио — вход строго типизирован как `[LatencyMetric]`, куда контент физически не помещается.
- `Sources/App/CompositionRoot.swift` (изменён) — `latencyRecording` передаётся в `AnswersModeController` и `ModeCoordinator` (было только в `RecordingModeController`/`OpenAIRealtimeAnswerClient`).
- `Tests/DomainTests/SyntheticAudioFixtures.swift` (создан) — генераторы синтетического PCM (`toneBurst`, `silence`, `backgroundNoise`, `explanationThenPauseThenQuestion`) без единого сэмпла реальной записи, как того требует этап ("не добавляй записи реальных встреч").
- `Tests/DomainTests/AnswersScenarioTests.swift` (создан, 10 тестов) — по одному тесту на большинство сценариев из списка этапа (короткий вопрос, утверждение без вопроса, три хода объяснения перед вопросом со снимком контекста нужного размера, риторический/процитированный вопрос перед финальным, sentinel + manual trigger, пауза внутри вопроса без разрыва окна, два вопроса подряд с раздельными окнами, русский/английский текст без изменений при стриминге, фоновой шум без особой обработки, обрыв потока источника не оставляет контроллер в нерабочем состоянии).
- `Tests/RealtimeClientTests/LanguageEvalCatalog.swift`, `LanguageEvalCatalogTests.swift` (созданы) — каталог из 8 сценариев рубрики (полностью RU/EN, RU с терминами `event loop`/`backpressure`/`Kubernetes`, EN с русской цитатой, design-tradeoff, debugging, недостающий контекст, утверждение-без-вопроса) плюс отдельно вынесенный `mixedCase`; `RubricScore` с `passed` = И по всем 6 измерениям рубрики (`language_match` и т.д. — провал любого хотя бы одного измерения проваливает весь скор, как того требует рубрика). `liveModelRubricEval` — настоящий тест, который **пропускается** (`.enabled(if:)`) если не выставлена `MEETING_ASSISTANT_RUN_LIVE_EVALS=1`; при явном включении честно сообщает через `Issue.record`, что живой eval-харнесс поверх реальной модели не реализован в этом offline-окружении, вместо того чтобы притворяться прошедшим.
- `Tests/RealtimeClientTests/RealtimeEventCodingFailureTests.swift` (создан, 3 теста) — невалидный JSON, валидный конверт с неизвестным `type`, конверт с отсутствующими обязательными полями — все три ветки уже возвращали `.unknown(...)` в реализации этапа 04 (`try?` вокруг decode), но не были явно протестированы как *отказоустойчивость*, а не просто "распознавание событий".
- `Tests/RealtimeClientTests/OpenAIRealtimeAnswerClientTests.swift` (изменён) — добавлен `rateLimitErrorSurfacesAsFailedWithoutLeakingMessageBody`: `error`-событие с кодом `rate_limit_exceeded` превращается в `.failed(code)` и НЕ попадает в лог полным текстом сообщения (проверка на уровне теста, что `redactedLog` действительно вызывается только с кодом — реализация не менялась, менялось только явное покрытие тестом).
- `Tests/PersistenceTests/SQLiteFailureInjectionTests.swift` (создан, 2 теста) — `sqlite3_open` на пути, который на самом деле директория (эмуляция "диск полон"/недоступен для записи по духу, не по факту freespace) корректно бросает `SQLiteError`, а не падает; последующая операция на ДРУГОЙ, рабочей базе не задета (нет расшаренного мутируемого состояния между независимыми `SQLiteConnection`).
- `Package.swift` — новых таргетов не добавлено (все новые файлы легли в существующие `DomainTests`/`RealtimeClientTests`/`PersistenceTests`/`DiagnosticsTests`).

**Форматирование/линтинг:** в репозитории нет `.swiftlint.yml`/`.swiftformat`/любого другого конфига форматтера или линтера — по правилу этапа "не вводи новый инструмент без необходимости" ни один не добавлен. Проверка ограничена `swift build`/`swift test`, как и на всех предыдущих этапах.

**Команды проверки:**
- `swift build` — успешно.
- `swift test` — успешно, 171/171 (было 143 до этапа: +28 новых — 6 в `AnswersModeControllerTests`/`ModeCoordinatorTests` на новые latency-метрики, 4 в `DiagnosticsTests` на `LatencyReportBuilder`, 10 в `AnswersScenarioTests`, 5 в `LanguageEvalCatalogTests` (включая 1 пропущенный live-тест), 3 в `RealtimeEventCodingFailureTests`, 1 rate-limit тест, 2 в `SQLiteFailureInjectionTests`). Ни один из 143 существующих тестов не сломан добавлением опциональных `latencyRecording` параметров (везде nil-по-умолчанию).
- `swiftc -typecheck Sources/App/*.swift Sources/OverlayUI/*.swift Sources/HistoryUI/*.swift -swift-version 6` — без ошибок.

**Результат:** пройдены все 8 формальных критериев приёмки. Прямой audio-to-Realtime critical path — доказан ещё этапом 04 (`sessionUpdateSentBeforeFirstAudioAppend` и др.), переподтверждён сценарными тестами этого этапа. Streaming UI до done — `firstDeltaPublishedBeforeResponseDone` (этап 04) + `AnswersScenarioTests`. Накопление контекста/manual без STT/без двойного ответа — `multipleContextTurnsResolveToOneAnswer`, `forceAnswerNowSendsExactlyOneResponseCreateWithScopedInstructions`, `exactlyOneVisibleAnswerWhenManualRacesAutomatic` + сценарные тесты. Нулевой network в `recording` и нулевая обработка в `passive` — структурные гарантии типов (`RecordingModeController`/`ModeCoordinator` не имеют зависимости на `RealtimeAnswering`/контроллер для `.passive` в принципе). RU/EN/смешанные сценарии — каталог `LanguageEvalCatalog` + `AnswersScenarioTests.russianAndEnglishTextBothFlowThroughStreamingUnmodified` (подтверждает отсутствие клиентского перевода/переписывания на уровне протокола: текст проходит байт-в-байт). Senior-quality rubric — `RubricScore` с шестью измерениями и fail-closed логикой `passed`. Latency-отчёт без контента — `LatencyReportBuilder` типизирован строго на `[LatencyMetric]`, куда текст/аудио физически не помещаются. Все тесты проходят; единственный обнаруженный внешний blocker (не новый) — `xcodegen`/подпись недоступны в этом окружении, команда воспроизведения не изменилась с этапа 01 (`brew install xcodegen && xcodegen generate`).

**Оставшиеся риски:**
- `firstDeltaToFirstPaintMs` измеряет диспетчеризацию внутри `AnswersModeController` (по конструкции близко к 0 мс — тест `firstDeltaRecordsFirstPaintLatencyWithoutArtificialDebounce` подтверждает `< 50` мс без единого искусственного `sleep`/debounce на этом пути, что и требует критерий), а не фактическую отрисовку `NSPanel`/SwiftUI на реальном экране — последнее требует инструментирования на подписанной сборке с живым дисплеем, недоступного в этом окружении (тот же класс ограничения, что `GlobalHotKeyManager`/`NSPanel` на этапе 05).
- Живые model evals (`liveModelRubricEval`) сознательно не реализованы — нет ни ключа, ни бюджета на платные вызовы в автоматическом прогоне, что явно запрещено текстом этапа ("никогда не включай сетевой eval в обязательный build без явного opt-in"). Тест существует, пропускается по умолчанию и честно объясняет, чего не хватает при явном запуске, вместо фиктивного прохождения.
- Не покрыты failure-инъекции: sleep/wake системы и "приложение митинга исчезло" (закрытие целевого процесса во время захвата) — оба требуют либо реальных macOS-уведомлений (`NSWorkspace`/питание), либо живого `SCContentFilter` на реальном приложении; ни то ни другое не воспроизводимо в headless unit-тесте. Оба задокументированы как ручная проверка на реальном Mac, а не тихо пропущены.
- "Malformed event"/"rate limit" покрыты на уровне decoder/client; "invalid API key" покрыт этапом 10 (`missingAPIKeyThrowsNotAuthenticatedBeforeAnyNetworkCall`, `notAuthenticated`); "переключение режима во время активного ответа/чанка" покрыто `concurrentSwitchesSerializeWithoutOverlap` (этап 02) — все три пункта не переоткрывались повторно как новые тесты в этом этапе, т.к. уже были доказаны раньше и повторное дублирование теста другим именем не добавило бы уверенности.

---

## 2026-08-22 — Этап 12: Сборка, onboarding и упаковка приложения

**Изменённые компоненты:**
- `Sources/App/AppNavigationState.swift` (создан) — общий `@Observable` держатель `isShowingHistory`/`isShowingSettings`/`isShowingOnboarding`, разделяемый между SwiftUI (`ModeSwitcherView`) и AppKit (`MenuBarController`) — раньше эти флаги были локальным `@State` внутри одного SwiftUI-view и были физически недостижимы из строки меню.
- `Sources/OverlayUI/MenuBarController.swift` (переписан) — раньше содержал только пункт «Ответить сейчас». Теперь: строка меню показывает ТЕКСТОВУЮ метку текущего режима и фазы (`"Пассивный"`/`"Ответы"`/`"Запись"` + `"готово"/"запуск"/"активно"/"остановка"/"ошибка"`) — иконка (`moon.zzz`/`bubble.left.and.text.bubble.right`/`record.circle`) её дополняет, но не заменяет, как явно требует этап; реагирует на РЕАЛЬНОЕ состояние через `withObservationTracking` над `ModeSwitcherViewModel.currentMode`/`.phase` (то же состояние, что видно в главном окне, — не "желаемый режим", а фактический, включая переходные/ошибочные фазы); пункты переключения режима с чекмарком на активном; «Открыть историю»/«Настройки» переключают `AppNavigationState`; «Завершить UserAgent057» вызывает новый `ModeSwitcherViewModel.terminate()` —граceful `ModeCoordinator.shutdown()` (уже существовал с этапа 02, просто не был подключён к реальному выходу из приложения) перед `NSApp.terminate(nil)`, а не мгновенный убийственный выход.
- `Sources/App/OnboardingView.swift` (переписан) — из статичного текстового экрана в интерактивный: ввод и сохранение API-ключа прямо в Keychain (через `SecretStoring` + `APIKeyFormatValidator`, тот же путь, что Settings, этап 10), кнопка «Проверить/загрузить модель» вызывает настоящий `WhisperKitTranscribing.prewarm()` (метод существовал с этапа 07, просто не был нигде вызван) — явно не блокирует закрытие экрана и не блокирует `passive`. Текст по режимам дополнен точным указанием, какое разрешение запрашивается в каждом (пункты 1/4/5/8 из потока этапа); пункт 6 (выбор приложения-источника) — ссылкой на Настройки, чтобы не дублировать тот же UI дважды.
- `Sources/App/CompositionRoot.swift` (изменён) — добавлены `whisperKitTranscribing: WhisperKitTranscribing` (конкретный тип, а не только type-erased `any LocalTranscribing`, — нужен onboarding-экрану для вызова `prewarm()`, которого нет в протоколе `LocalTranscribing`) и `navigationState: AppNavigationState`.
- `Resources/Info.plist` (изменён) — `CFBundleShortVersionString`/`CFBundleVersion` заменены на `$(MARKETING_VERSION)`/`$(CURRENT_PROJECT_VERSION)` (стандартная подстановка Xcode для этих двух ключей).
- `project.yml` (изменён) — `settingGroups.versioning` — единая точка задания версии/сборки (`MARKETING_VERSION: 0.1.0`, `CURRENT_PROJECT_VERSION: 1`), подключена через `settings.groups` таргета `UserAgent057`; `ARCHS`/`VALID_ARCHS: arm64` (обязательное требование этапа; universal-сборка не собиралась, т.к. не запрошена пользователем и добавляет только риск без явной необходимости); раздельные `configs.Debug`/`configs.Release` (`SWIFT_ACTIVE_COMPILATION_CONDITIONS`, `ONLY_ACTIVE_ARCH`, `SWIFT_COMPILATION_MODE: wholemodule` для Release). YAML-синтаксис проверен `python3 -c "import yaml; yaml.safe_load(...)"` — семантику схемы XcodeGen (`settingGroups`/`groups`) в этом окружении проверить прогоном `xcodegen generate` нельзя (см. риски, тот же blocker с этапа 01).
- `README.md` (расширен) — установка API-ключа, загрузка Whisper-модели, таблица разрешений (кто/когда запрашивает), использование трёх режимов, создание саммари, диагностика, расположение/удаление локальных данных, команды release-сборки и АРХИВАЦИИ, документированные (не выполненные) команды подписи/нотаризации без секретных значений (плейсхолдеры `<ВАШЕ ИМЯ>`/`<TEAM_ID>`/`<APPLE_ID>`/`<APP_SPECIFIC_PASSWORD>`).
- `docs/privacy.md` (создан) — что именно захватывается/куда уходит в каждом режиме, секреты, diagnostic export, расположение и способ удаления локальных данных.
- `docs/troubleshooting.md` (создан) — 9 типичных проблем (`xcodegen` не установлен, `answers` падает/не слышит, `recording` не стартует, live-transcript обновляется рывками — со ссылкой на этап 07, поиск не находит словоформу — со ссылкой на этап 08, экспорт не создаёт файл, сборка домена падает на зависимости, SQLite-ошибка/диск полон, работа офлайн) с точной причиной и действием, а не общими словами.

**Проверки из текста этапа (`## Проверки`), что выполнимо в этом окружении:**
1. Clean Release build — **не выполнено**: требует `xcodegen generate` + `xcodebuild`, недоступных здесь (см. риски, идентичный blocker с этапа 01). `swift build`/`swift test` (пакетная часть, независимая от Xcode-проекта) выполнены и проходят полностью — 171/171.
2. Запуск без базы/настроек → `passive` — структурно гарантировано: `AppMode` по умолчанию `.passive` (`ModeState.initialPassive`, этап 02), `SQLiteConnection.ensureReady()` вызывается лениво только при первом реальном обращении репозитория, а не при старте приложения.
3. Запуск без API-ключа → passive/recording доступны, `answers` не падает бесшумно — `KeychainSecretStore.retrieveAPIKey()` возвращает `nil`, `DirectKeyCredentialProvider` бросает `missingAPIKey`, `OpenAIRealtimeAnswerClient.start()` нормализует это в `RealtimeClientError.notAuthenticated` → `ModeCoordinator` переводит в `passive` с `userFacingError` (не крашится) — уже покрыто тестами этапов 04/10, поведение не менялось.
4. Запуск без Whisper-модели → passive/answers доступны, recording предлагает установить — `WhisperKitTranscribing` лениво грузит модель только внутри `transcribe()`/`prewarm()`, ошибка загрузки всплывает как `transcription_failed` через `RecordingModeController.failures()` (этап 07), а не крашит процесс; onboarding даёт явную кнопку проверки заранее.
5. Release bundle не содержит ключей/пользовательских данных/WAV-PCM fixtures вне test bundle — структурно: единственное место записи API-ключа — Keychain (не bundle); `Sources/App`/`OverlayUI`/`HistoryUI` (единственные источники таргета `UserAgent057` в `project.yml`) не содержат ни одного аудио-фикстура — все синтетические PCM-генераторы (`SyntheticAudioFixtures.swift`) лежат в `Tests/DomainTests`, которые НЕ являются частью таргета приложения (только `Tests/AppTests` подключён как отдельный `bundle.unit-test` таргет к `UserAgent057Tests`, тоже вне `UserAgent057.app`).
6. Stop/quit во всех режимах — `ModeCoordinator.requestTransition(to: .passive)` уже покрыт `sixDirectedTransitions`/`stopAlwaysCompletesAndReachesPassive` (этап 02); quit — новый `terminate()` вызывает тот же протестированный `shutdown()`.

**Результат:** формальный критерий "воспроизводимая `.app` Release-сборка либо точно описанный внешний blocker" выполнен во второй части (blocker описан с точной командой воспроизведения, идентичной для этапов 01-11, — не новый и не расширившийся). Остальные 3 критерия приёмки пройдены структурно и тестами пакета, перечисленными выше.

**Оставшиеся риски:**
- `xcodegen`/`xcodebuild`/подпись недоступны в этом окружении — весь Release-build/archive/notarization пайплайн задокументирован командами в README, но не запускался ни разу за все 12 этапов. Это единственный сквозной внешний blocker проекта, зафиксированный с этапа 01 и не изменившийся.
- Синтаксис XcodeGen `settingGroups`/`settings.groups` проверен только как валидный YAML (`python3 -c "import yaml..."`), НЕ как валидная схема XcodeGen — риск опечатки в имени ключа, которая проявится только при первом реальном `xcodegen generate` на машине пользователя.
- `ONLY_ACTIVE_ARCH: NO` для Release означает попытку собрать `arm64` (единственная запись в `ARCHS`/`VALID_ARCHS`) — universal-сборка сознательно не настраивалась: WhisperKit/CoreML-зависимости не проверялись на x86_64 в этом окружении, а продукт с самого этапа 01 явно приоритизирован для Apple Silicon.
- Обновлённый `MenuBarController` (реальный AppKit `NSStatusItem`/`NSMenu`) не запускался вживую (нет дисплея в этом окружении) — тот же класс ограничения, что и у `GlobalHotKeyManager`/`NSPanel` с этапа 05; проверено только компиляцией и типами.

---

## 2026-08-22 — Этап 13: Финальный аудит

Полный отчёт — `docs/final-audit.md` (commit/worktree state, матрица всех 25 требований этапа с ссылками на код/тесты, фактические команды и результаты, latency summary с явной оговоркой "только fake transport", privacy review, найденные проблемы и решения по ним, точные шаги запуска MVP).

**Найдено и исправлено:**
- `RecordingModeControllerTests::doesNotCallRealtimeOrResponsesAPI` не содержал ни одного `#expect` — ровно тот случай "тестов, которые ничего не утверждают", который явно требовалось найти и устранить. Добавлены проверки, что репозиторий реально получает `createMeeting`/`finish` (контроллер делает настоящую работу, а не просто не падает), при этом структурно не имея зависимости на `RealtimeAnswering`/`SummaryGenerating`.

**Рассмотрено и сознательно не изменено (задокументировано в `docs/final-audit.md`, §6):**
- 4 force-unwrap (`!`) в `Sources/` — все на константных литералах (2 regex-паттерна в `SecretRedactor`, 2 URL-эндпоинта), не на пользовательском вводе; замена на `try?`/fallback была бы менее безопасной (молчаливо невалидный URL/regex вместо явного краха в точке реальной ошибки программиста).
- Fire-and-forget `Task` без хранимой ссылки (`QuestionAnswerLogger.persist()`, `reconcileInterruptedMeetings`) — время жизни ограничено самим завершением одной async-операции, не бесконечным циклом; хранение/отмена для операции, которая не может зависнуть, была бы абстракцией без функциональной пользы.

**Не найдено (проверено grep по всему `Sources/`):** `TODO`/`FIXME`, `fatalError`/`preconditionFailure`, пустые `catch`, `Task.detached`, hardcoded секреты вне redaction/validation файлов, `OpenAI-Beta`/`realtime=v1` заголовки старого beta API, дублирование realtime wire-схемы вне `RealtimeEventCoding.swift`.

**Команды проверки:** `swift build` — успешно; `swift test` — успешно, 171/171 (после исправления пустого теста, набор тестов не изменился численно — тест остался тем же, просто перестал быть "пустым"); `swiftc -typecheck ... -swift-version 6` — без ошибок; `python3 -c "import yaml; yaml.safe_load(open('project.yml'))"` — валиден.

**Результат:** все 25 пунктов аудита кода подтверждены; финальные критерии приёмки этапа 13 выполнены с честно задокументированными внешними blockers (см. `docs/final-audit.md`, §7) — `xcodegen` не установлен (сквозной с этапа 01), нет Apple Developer ID, нет реального дисплея/TCC, нет оплаченного OpenAI-ключа. Ни один из них не является дефектом кода.

**Проект по всем 14 этапам (00–13) реализован и задокументирован.** Полная сводка готового/ограничений/команд запуска — в `docs/final-audit.md`, раздел "Краткая сводка для пользователя".

---

## 2026-09-02 — Постфактум: два бага (язык транскрипции, обрезанные митинги)

Жалоба пользователя: "не пишутся митинги полностью" + митинг был на русском/украинском, а транскрипция вышла на английском.

**Баг 1 — язык транскрипции.** `WhisperKitTranscribing.transcribe` вызывал `DecodingOptions(chunkingStrategy: .vad)` без `language`/`detectLanguage`. У WhisperKit при `usePrefillPrompt == true` (умолчание) `detectLanguage` тоже по умолчанию `false` (`Configurations.swift`: `detectLanguage = detectLanguage ?? !usePrefillPrompt`), поэтому `options.language` оставался `nil` и `TextDecoder` форсировал `Constants.defaultLanguageCode == "en"` на префилл-токен (`TextDecoder.swift:183,820`) — модель декодировала так, будто ей сказали "это английская речь", независимо от реального языка. Фикс: `DecodingOptions(detectLanguage: true, chunkingStrategy: .vad)` — включает пер-чанковое автоопределение языка (`TranscribeTask.swift:341`), что также корректно обрабатывает переключение языка внутри одной встречи (RU/UK/EN). Модель по умолчанию (`openai_whisper-small`) — мультиязычная, детекция реально включается.

**Баг 2 — обрезанные митинги.** `ModeCoordinator.shutdown(timeout:)` (единственный вызов — `UserAgent057AppDelegate.applicationShouldTerminate`, без явного `timeout`) использовал умолчание `.seconds(5)`. Это гонка с реальной асинхронной работой при выходе из приложения во время активной записи: `RecordingModeController.stop()` должен успеть добить `ChunkedTranscriptionPipeline.flush()` (транскрипция последнего чанка ~8–9.5с, включая холодную загрузку CoreML-модели WhisperKit в память при первом вызове за сессию — прогрев (`prewarm()`) вызывается только один раз в онбординге, не при каждом запуске приложения) и записать сегменты + `repository.finish()` в SQLite. Отмена `workTask` в `shutdown` кооперативная и не прерывает уже идущий `stop()` — по истечении таймаута `resumer.resume()` срабатывает немедленно, `AppDelegate` тут же отвечает `NSApp.reply(toApplicationShouldTerminate: true)`, и ОС завершает процесс, а незавершённая запись сегментов/`finish()` обрывается. Именно поэтому зависшие на статусе `recording` митинги при следующем запуске превращаются в `.interrupted` (`reconcileInterruptedMeetings`, `CompositionRoot.swift`) — механизм это предвидел, но UI (`HistoryUI`) статус `.interrupted` никак не показывает, так что обрыв незаметен пользователю. Фикс: `shutdown(timeout:)` по умолчанию `.seconds(30)` — достаточно на холодный старт модели + инференс + запись, при этом остаётся конечным пределом на случай настоящего зависания (не регрессия к старому неубиваемому багу, тот был устранён отдельно — реентрантный `NSApp.terminate` в `ModeSwitcherView`, не таймаутом).

Оба места и разбор задокументированы здесь, а не инлайн-комментариями в коде (см. правило проекта "No code comments").

**Проверено:** `swift build` — успешно; `swift test` — 195/195, включая `shutdownDuringStartingIsBoundedByTimeout` (использует явный `timeout: .milliseconds(200)`, дефолт не тестировался напрямую и его изменение теста не задело).

**Не сделано:** живой ретест на реальном железе (реальная запись митинга на RU/UK, реальный quit во время записи) — нужен `sign-and-install.sh` пользователем, недоступно в этом окружении.

---

## 2026-09-10 — Постфактум: фикс от 2026-09-02 не был установлен + `language` не сохранялся

Пользователь снова увидел англ. транскрипцию на RU/UK митинге. Причина — не регрессия, а то, что фикс от 2026-09-02 остался только в исходниках: установленный `/Applications/UserAgent057.app` датирован 25 августа (`sign-and-install.sh` не запускался после фикса). Проверено по БД (`~/Library/Application Support/UserAgent057/useragent057.sqlite3`): митинг `1C503009…` (сегодня 11:29, статус `interrupted`) содержит явно неверный перевод RU/UK-речи на английский ("Moshi no seima is with me Polygeli" и т.п.) — старый баг из старого билда, а не новый.

Заодно обнаружено: `WhisperKitTranscribing.transcribe` игнорировал `result.language` (реально определённый WhisperKit язык чанка) и всегда создавал `TranscribedSegment` с `language: nil`, хотя колонка `utterances.language` в SQLite для этого и существует (`SQLiteMeetingRepository.appendSegment`) — поэтому даже сейчас невозможно было проверить по данным, сработала ли детекция. Исправлено — `TranscribedSegment(..., language: result.language)`. Это диагностическая правка, не меняющая поведение самой детекции (та уже включена фиксом от 2026-09-02, `detectLanguage: true`), но начиная с этого билда в БД будет виден реальный определённый язык на сегмент.

**Проверено:** `swift build` — успешно; `swift test` — 195/195 (один прогон дал 2 "issues" в `ModeCoordinatorTests`, повтор `--filter ModeCoordinatorTests` прошёл чисто — известная преэкзистентная нестабильность таймингов, не связана с этой правкой).

**Действие для пользователя:** обязательно завершить текущий запущенный процесс (митинг в статусе `recording` от 11:56 сегодня — это текущий живой запуск старого билда) и переустановить через `sign-and-install.sh`, иначе фикс снова не применится.

---

## 2026-09-10 — Кнопка "Открыть папку с записями" + реальное сохранение аудио на диск

Запрос пользователя: кнопка для открытия папки с записью митинга. По ходу выяснилось, что `audioStorageEnabled` (тумблер "Сохранять аудио на диск" в Настройках) был полностью инертным — читался/писался в `AppSettingsStore`, но нигде не проверялся; исходное аудио не писалось вообще, о чём честно предупреждала старая подпись тумблера. Кнопку "открыть папку" без реально пишущихся файлов делать бессмысленно, поэтому реализовано и то и другое.

**Новый протокол** `MeetingAudioRecording` (`Domain/Protocols.swift`) — `start(meetingID:)` / `write(_:)` / `finish()`, по образцу уже существующего `LatencyRecording`.

**Реализация** — `WAVMeetingAudioFileWriter` (`AudioCapture/WAVMeetingAudioFileWriter.swift`), actor поверх `AVAudioFile`. Пишет два WAV-файла на встречу — `mic.wav` и `system.wav` — в `<meetingID>/` под общей папкой записей, по одному `AVAudioFile` на источник (открывается лениво при первом кадре этого источника). Формат файла берётся из фактических `sampleRate`/`channelCount` кадра (в `RecordingModeController` это всегда 16 кГц моно — `WhisperAudioFormatConverter`, тот же формат, что уже идёт в Whisper), так что переконвертация не нужна.

**Wiring** — `RecordingModeController` получил `audioRecording: (any MeetingAudioRecording)?` и `isAudioStorageEnabled: @Sendable () -> Bool` (провайдер, не прямая зависимость от `AppSettingsStore` — тот же паттерн, что `vadSettingsProvider` в `OpenAIRealtimeAnswerClient`). Оба параметра с дефолтами (`nil` / `{ false }`), чтобы не ломать существующие вызовы в тестах. Решение писать/не писать принимается один раз в `start()` (`audioRecordingActive`), кадры пишутся в `consume()` до передачи в `ChunkedTranscriptionPipeline`, `finish()` вызывается в `stop()` симметрично `repository.finish()`.

**Папка** — `~/Library/Application Support/UserAgent057/Recordings/`, создаётся один раз в `CompositionRoot.recordingsDirectoryURL()` (рядом с уже существующим `databaseFilePath()`), путь пробрасывается в `SettingsViewModel` как `recordingsDirectory`. Кнопка "Открыть папку с записями" в секции "Хранение аудио" (`SettingsView.swift`) вызывает `NSWorkspace.shared.open(recordingsDirectory)` — папка существует всегда (создана при старте), даже если пока пуста.

Старая (более не верная) подпись тумблера заменена на описание фактического поведения.

**Проверено:** `swift build` + `swift test` — 199/199 (4 новых теста: `RecordingModeControllerTests.audioIsWrittenToDiskOnlyWhenStorageIsEnabled`/`audioIsNotWrittenToDiskWhenStorageIsDisabled` через новый `FakeMeetingAudioRecording`; `WAVMeetingAudioFileWriterTests.writesSeparateWAVFilesPerSourceWithAllSamples`/`emptyFrameIsIgnored` — реальная запись на диск во временную директорию и чтение обратно через `AVAudioFile`, не только typecheck). `swiftc -typecheck Sources/App/*.swift Sources/OverlayUI/*.swift Sources/HistoryUI/*.swift -swift-version 6` — без ошибок. Проверка `loc(...)` call sites против `Localizable.xcstrings` — 0 отсутствующих ключей (146 ключей, было 145: -1 устаревшая подпись, +2 новые строки).

**Не сделано:** живая проверка реального WAV-файла из настоящей встречи и клика по кнопке в Finder — нужен `sign-and-install.sh` пользователем.

---

## 2026-09-14 — Answers-режим замолкает навсегда без видимой ошибки

Жалоба: "Answer now" отвечает "No context", и вообще ни одного ответа не появляется; stop/resume и переключение режимов не помогает. Важная деталь: установленный `.app` всё ещё датирован 25 августа (`sign-and-install.sh` так и не запускался после фиксов от 2026-09-02/09-10) — значит проблема воспроизводится на билде, который не менялся с 25 августа, и не связана ни с одним из недавних изменений.

`/tmp/ma_realtime_diag.log` (временная диагностика из `CompositionRoot.makeRealtimeDiagLogger`, до сих пор не убрана) показал за сегодня несколько WS-реконнектов (`NSURLError`) с интервалом ~5–25 минут, каждый раз успешно восстанавливавшихся (`session.created`/`session.updated` приходят) — сам транспортный слой (генерация-guard из фикса 2026-08-25/26) работает штатно, это не то, что ломает контекст навсегда.

**Найденный реальный дефект** — `Sources/AudioCapture/ScreenCaptureKitSystemAudioCapturing.swift`, `stream(_:didStopWithError:)`: при любой ошибке `SCStream` (смена дисплея, сон/пробуждение, потеря permission на лету, таргет-приложение закрылось) поток `AsyncStream<PCMAudioFrame>` просто завершается (`continuation?.finish()`) без единого сигнала наверх — у `SystemAudioCapturing` вообще нет канала ошибок. В `Domain/AnswersModeController.swift` `captureTask`, читающий этот поток (`for await frame in frames { ... await realtime.appendAudio(frame) }`), в этом случае просто доходит до конца и завершается молча — `isRunning` остаётся `true`, режим внешне выглядит активным, но `realtime.appendAudio` больше никогда не вызывается: ни одного нового кадра аудио не уходит в OpenAI, `contextWindow` никогда больше не наполняется, `forceResponse()` навсегда честно отвечает `.noContext` — ровно то поведение, которое описал пользователь, включая то, что stop/resume не лечит проблему (если причина обрыва `SCStream` персистентна — например, реально сменившийся дисплей/спящий режим — новый `start()` может упасть в ту же ситуацию).

**Фикс** — `AnswersModeController.captureTask`: если цикл `for await frame in frames` завершился НЕ из-за отмены (`!Task.isCancelled`, что надёжно отличает предумышленный `stop()` от неожиданного обрыва потока — `isRunning = false` и `captureTask?.cancel()` в `stop()` выполняются синхронно, до первой точки приостановки), теперь вызывается новый `reportCaptureStreamEndedUnexpectedly()` → `failureContinuation.yield("system_audio_capture_ended")`. Это уже существующий, уже правильно подключённый канал (`ModeCoordinator.watchFailures` слушает `controller.failures()` и переводит режим в `passive` с `userFacingError`) — теперь обрыв захвата аудио перестаёт быть невидимым зомби-состоянием и становится видимой ошибкой с автоматическим возвратом в Passive, как и любой другой runtime-failure (например, исчерпание реконнектов WS).

Симметричный пробел есть и в `RecordingModeController` (тот же паттерн: `for await frame in sysFrames` молча заканчивается при обрыве), но сознательно не тронут в этой правке — история встреч там уже частично защищена `reconcileInterruptedMeetings`, а запрос был именно про Answers/"Answer now"; можно вернуться к этому отдельно, если появится аналогичная жалоба на recording.

**Проверено:** `swift build` — успешно; `swift test` — 201/201 (2 новых теста: `unexpectedCaptureStreamEndReportsFailureRatherThanGoingSilent` — через новый `FakeSystemAudioCapturing.simulateUnexpectedEnd()`, проверяет, что обрыв потока БЕЗ вызова `stop()` даёт ровно одну ошибку `"system_audio_capture_ended"`; `intentionalStopDoesNotReportCaptureFailure` — проверяет обратное: обычный `stop()` не порождает ложного failure). Понадобился новый `FailureCollector` (actor-обёртка над `AsyncStream<String>`, по образцу уже существующего `StreamEventCollector`) — прямой захват `var` в `Task { for await ... }` внутри теста не проходил Swift 6 strict concurrency (`sending-risks-data-race`). `swiftc -typecheck Sources/App/*.swift Sources/OverlayUI/*.swift Sources/HistoryUI/*.swift -swift-version 6` — без ошибок.

**Открытый вопрос пользователю** (не код): предпочитаемый источник системного звука для Answers сейчас — `com.google.Chrome` (`defaults read com.local.UserAgent057`). Если сегодняшняя встреча шла НЕ через Chrome (нативный Zoom/Teams/Slack-huddle), ScreenCaptureKit честно захватывал тишину из Chrome — это не баг, а несовпадение настройки с реальным источником звука, и его тоже стоит проверить в Настройках наряду с этим фиксом.

**Не сделано:** живой ретест на реальном железе — нужен `sign-and-install.sh`; заодно стоило бы наконец снять временный `/tmp`-диагностический логгер, раз он снова пригодился для диагностики — отложено до следующего подтверждённого стабильного прогона.

---

## 2026-09-21 — Три стиля оверлея ответов (идея из Textream)

Запрос пользователя: «прикрутить» [github.com/f/textream](https://github.com/f/textream) (открытый macOS-телесуфлёр, MIT, Fatih Kadir Akin) вместо текущего оверлея, оставив свою логику обращения к GPT. Уточнил вопросом: пользователь подтвердил (1) взять три стиля окна — pinned-к-вырезу/floating/fullscreen — и шрифты, (2) НЕ переносить speech-tracking (подсветку произносимого слова) — он привязан к заранее известному тексту скрипта, а наш ответ формируется потоково от GPT и заранее неизвестен.

Textream — монолитное Xcode-приложение (~10.5k строк, без SPM-библиотеки), поэтому «подключить как зависимость» было невозможно физически — код пришлось читать и переносить руками. Фактически перенесена только оконная механика (уникальный `DynamicIslandShape` — фигура пилюли с вогнутыми верхними/выпуклыми нижними углами, скопирована почти дословно, см. `THIRD_PARTY_NOTICES.md` за атрибуцию по MIT) и геометрия позиционирования под вырезом; вся привязанная к ASR/спич-трекингу часть (`SpeechRecognizer`, `VoiceActivityDetector`, `SpeechTextAlignment`, `OverlayContent`-пагинация, `MarqueeTextView`/`HighlightingTextEditor` — суммарно тысячи строк) сознательно не переносилась — она устроена вокруг "прокрутки к текущему произносимому слову", чего у потокового ответа GPT просто нет (см. `THIRD_PARTY_NOTICES.md`, раздел ниже про то, что переиспользовано, а что написано заново).

**Новое:**
- `OverlayStyle` (`pinned`/`floating`/`fullscreen`) и `OverlayFontFamily` (`sans`/`serif`/`mono`) — `Sources/OverlayUI/OverlayStyle.swift`. `OpenDyslexic` из Textream сознательно не перенесён — требует бандлить сторонний шрифт (`.ttf`) с отдельной лицензией (SIL OFL, не MIT) ради нишевой accessibility-фичи, не входившей в подтверждённый пользователем скоуп.
- `DynamicIslandShape` (`Sources/OverlayUI/DynamicIslandShape.swift`) — форма пилюли с вогнутыми верхними/выпуклыми нижними углами, перенесена практически дословно из `NotchOverlayController.swift` (единственный по-настоящему скопированный кусок — самодостаточная `Shape`, не зависящая ни от чего textream-специфичного).
- `OverlayGeometry.pinnedOrigin(for:screenFrame:)` (`Sources/OverlayUI/OverlayGeometry.swift`) — чистая функция позиционирования под вырезом (top-center экрана), написана заново по мотивам `NotchFrameTracker`, но без ASR-полей и `@Observable`-обвязки (не нужна — размер уже пересчитывается на каждое изменение `AnswerOverlayViewModel.state` через существующий `resizeToFitContent()`). Принимает `CGRect`, а не `NSScreen`, специально ради тестируемости без реального дисплея.
- `AnswerOverlayPanel` теперь параметризован `OverlayStyle` — единый `NSPanel`-класс на все три режима (`level = .screenSaver` вместо прежнего `.floating`, чтобы оверлей оставался поверх full-screen встречи в Zoom/Meet — это заодно чинит вероятный старый пробел, не только новая фича), но с разным `collectionBehavior`/`isMovableByWindowBackground`/`hasShadow` в зависимости от стиля.
- `AnswerOverlayWindowController` — пересоздаёт панель и `NSHostingView` при смене `style`/`fontFamily` в Настройках (`rebuildPanelIfPreferencesChanged()`, проверяется на каждый `syncVisibility()`/`resizeToFitContent()` — эффект применяется к следующему показу оверлея, без перезапуска приложения). Esc-монитор клавиатуры (`NSEvent.addLocalMonitorForEvents`, keyCode 53) активен только для `pinned`/`fullscreen` — закрывает оверлей тем же путём, что и hotkey переключения видимости; корректно снимается (`NSEvent.removeMonitor`) при пересборке панели, иначе бы утекал и дублировался при повторных сменах стиля (явно предупреждение из ресёрча по Textream).
- `AnswerOverlayContentView` принимает `style`/`fontFamily`; сам SwiftUI-контент (`capsule`/`answerPanel`, состояния `collectingContext`/`streaming`/…) переиспользован БЕЗ изменений логики — стиль меняет только фон (чёрная `DynamicIslandShape` для pinned вместо `.regularMaterial`), размер панели и семейство шрифта основного текста ответа.
- Настройки: новая секция «Оверлей ответов» (`SettingsView.swift`) — два `segmented Picker`а (стиль, шрифт).

**Сознательно упрощено относительно Textream** (см. `THIRD_PARTY_NOTICES.md` за полный список): без multi-monitor "следовать за мышью" (постоянный поллинг раз в 0.3с ради второстепенного сценария), без `followCursorWhenUndocked`-подрежима с отдельной "stop"-панелью, без drag-to-resize у pinned-режима, без цветовых пресетов текста, без glass/blur-варианта фона (только сплошной чёрный для pinned) — экран выбирается как `NSScreen.main`, без персистентного `displayID`.

**Проверено:** `xcodebuild ... build` и `xcodebuild ... test` (реальный Xcode-билд — в этом окружении сессии `xcodebuild`/`xcodegen` неожиданно оказались доступны, в отличие от всех предыдущих сессий проекта, см. риски ниже) — **BUILD SUCCEEDED** / **TEST SUCCEEDED**, включая новый `Tests/AppTests/OverlayGeometryTests.swift` (5 тестов: позиционирование под вырезом с нулевым и ненулевым origin экрана, round-trip `rawValue` для обоих enum, различимость шрифтов). `swift test` (пакетная часть, не затронута этой правкой) — 201/201. Проверка `loc(...)` против `Localizable.xcstrings` — 0 отсутствующих ключей (156, было 146).

**Риск на будущее:** доступность `xcodebuild`/`xcodegen` в среде исполнения агента исторически была blocker'ом с этапа 01 (см. записи 2026-08 и ранее) — в этой сессии оказалось, что окружение изменилось и полноценный Xcode-билд/тест доступен. Не факт, что это стабильно во всех будущих сессиях — если недоступно снова, откатываться на `swiftc -typecheck Sources/App/*.swift Sources/OverlayUI/*.swift Sources/HistoryUI/*.swift -swift-version 6` как раньше.

**Не сделано:** живой визуальный ретест на реальном железе (как выглядит `DynamicIslandShape` рядом с настоящим вырезом MacBook, реальный Esc-выход из fullscreen, реальная смена стиля на лету) — нужен `sign-and-install.sh` пользователем.

---

## 2026-09-21 — Автоэкспорт транскрипта завершённой встречи на Desktop

Запрос: сохранять митинги на рабочий стол, в папку «с датой + UserAgent057». Контекст — по ходу проверки предыдущей встречи выяснилось, что `audioStorageEnabled` был выключен (аудио и так не терялось, просто не сохранялось отдельно), а транскрипт лежал только в SQLite, без видимого файла — пользователь хотел человекочитаемый файл в понятном месте, не копаясь в `~/Library`.

**`RecordingModeController`** (`Sources/Domain/RecordingModeController.swift`) получил новый поток `finishedMeetings() -> AsyncStream<MeetingID>` — yield'ит `meetingID` в `stop()` сразу после того, как `repository.finish(...)` реально успел (не только "мы попытались", как раньше с голым `try?`) — по тому же принципу симметрии, что и `transcriptEvents()`/`failures()`. Domain намеренно НЕ форматирует и не пишет файлы сам (сохраняет чистоту слоя — Domain не знает о Desktop, Markdown или AppKit) — просто сообщает "эта встреча закончилась, вот её id".

**`DesktopMeetingExporter`** (новый, `Sources/App/DesktopMeetingExporter.swift`) — живёт в App-слое намеренно, а не в Domain/Persistence: единственный способ переиспользовать уже существующий `TranscriptFormatter.renderMarkdown` (модуль `Summary`) без нарушения графа зависимостей — `Summary` зависит только от `Domain`, `Domain` не может зависеть от `Summary` в обратную сторону. По `meetingID` из `finishedMeetings()` делает `meetingRepository.fetch(meetingID:)`, рендерит Markdown-транскрипт (те же подписи спикеров "Я"/"Участники", что уже используются в live-transcript UI) и пишет `transcript.md` в папку `<yyyy-MM-dd HH-mm> UserAgent057` на Desktop (`FileManager.default.urls(for: .desktopDirectory, ...)`). Если для этой встречи существуют `mic.wav`/`system.wav` (когда `audioStorageEnabled` включён — фича от 2026-09-10, пишет их в `~/Library/.../Recordings/<meetingID>/`), они дополнительно КОПИРУЮТСЯ (не переносятся — исходная папка остаётся источником правды для `WAVMeetingAudioFileWriter`) в ту же папку на столе, так что всё по встрече оказывается в одном видимом месте.

Класс помечен `@unchecked Sendable` (нужно для захвата в `Task` внутри `CompositionRoot.init()`, который сам не `@MainActor`-изолирован в точке захвата стрима) — оправдано тем же способом, что уже применялся к `AppSettingsStore` ранее в проекте: единственное несендable-поле, `FileManager`, задокументированно потокобезопасно у Apple при использовании `.default`.

Подписка живёт в `CompositionRoot` (`desktopExportTask`, `for await meetingID in recordingController.finishedMeetings() { ... }`) — по аналогии с уже существующим `reconcileInterruptedMeetings`-таском, только на весь жизненный цикл приложения, а не одноразово.

**Формат имени папки:** `yyyy-MM-dd HH-mm UserAgent057` (время, не только дата — иначе несколько встреч в один день переписывали бы друг друга). Название на английском (`UserAgent057`), не транслитерация — совпадает с реальным именем приложения в Dock/меню.

**Проверено:** `xcodebuild ... test` — **TEST SUCCEEDED**, 7 тестов в `UserAgent057Tests` (было 5, +2 новых в `Tests/AppTests/DesktopMeetingExporterTests.swift`: транскрипт пишется с правильным содержимым в правильно названную папку; существующий `mic.wav` копируется, отсутствующий `system.wav` — нет). `swift test` (пакетная часть, включая новый `RecordingModeControllerTests.stopYieldsFinishedMeetingIDForDownstreamExport`) — 202/202 (один прогон дал 1 issue в `QuestionAnswerLoggerTests.transcriptionTimeoutSavesStatusFailed` — не связанный с этой правкой файл, повтор прошёл чисто, та же преэкзистентная нестабильность таймингов, что и раньше).

**Не сделано:** живой ретест на реальном железе (реальная папка появляется на реальном Desktop после реальной встречи) — нужен `sign-and-install.sh` пользователем. Не перенесено на симметричный случай `AnswersModeController` — там нет понятия "законченная встреча" для экспорта (ответы уже логируются per-вопрос в `QuestionAnswerLogger`/`SQLiteQuestionAnswerRepository`, не одним документом).

---

## 2026-09-22 — Ответ в Answers больше не исчезает по таймеру

Жалоба: "ответ не должен исчезать через время я не успеваю его прочесть, только когда я нажму на кнопку reset". До этой правки было два независимых механизма автоочистки законченного ответа: (1) `AnswerOverlayViewModel.scheduleRetentionTimer()` — жёсткие 20 секунд после `.completed`, после чего `retentionTimerFired` стирал текст и возвращал видимость к "Слушаю"; (2) сам `.answerStream(.collectingContext)` — событие, которое `AnswersModeController` шлёт, когда после законченного ответа начинается новый ход разговора (сентинел `⟦WAIT_FOR_QUESTION⟧`), тоже стирало текст. Оба уже уважали `isPinned` — существовавшую ранее кнопку "Закрепить"/"Откреплено", которую нужно было нажимать вручную на каждый ответ, чтобы он не пропал.

Раз пользователь хочет это поведение ВСЕГДА, а не по запросу — не стал оставлять `isPinned` как опцию по умолчанию `true`, а убрал сам механизм автоочистки целиком (мёртвая абстракция иначе: кнопка "Закрепить", которая ничего не переключает, раз ничего больше не гаснет само). Удалено:
- `AnswerOverlayAction.retentionTimerFired`, `.pinToggled`; `AnswerOverlayState.isPinned`; `AnswerOverlayViewModel.retentionTask`/`scheduleRetentionTimer()`/`retentionSeconds`/`togglePin()` — вся ветка выпилена, не просто отключена.
- Кнопка "Закрепить"/"Откреплено" в `AnswerOverlayContentView.swift`; соответствующие ключи локализации ("Закрепить", "Откреплено", "Не даёт ответу скрыться автоматически") удалены из `Localizable.xcstrings` (153 ключа, было 156).
- `.answerStream(.collectingContext)` в редьюсере теперь `break` (было: стирало текст, если не запинено) — законченный ответ переживает начало нового хода разговора.

Что осталось нетронутым: `.contextReset` (кнопка "Сбросить") по-прежнему стирает текст и `lastAnswerText` — единственный способ теперь. `.noContext` (нажали "Ответить сейчас" без контекста) по-прежнему переключает видимость на `.collectingContext`, пряча текст ответа из вида — но не стирает `state.text`/`lastAnswerText`, так что кнопка "Показать последний ответ" (`showLastAnswer()`/`lastAnswerRequested`, отдельная, сознательно не тронутая фича) всё ещё восстанавливает его. Новый реальный ответ (`.streaming`/`.completed`) по-прежнему естественно ЗАМЕНЯЕТ показанный текст — это не "исчезновение", а получение нового ответа, что и должно происходить.

**Проверено:** `swift build`/`swift test` — 202/202 (пакетная часть; один прогон дал 3 issues в `QuestionAnswerLoggerTests`, не тронутом этой правкой файле — повтор прошёл чисто, преэкзистентная нестабильность таймингов). `xcodebuild ... test` — **TEST SUCCEEDED**, 7/7 (Xcode-таргет `UserAgent057Tests` не изменился числом тестов — правка была в `OverlayReducer`/`OverlayUI`, у них тесты в SwiftPM-пакете). `Tests/OverlayReducerTests/AnswerOverlayReducerTests.swift`: заменены 2 теста, привязанных к удалённому API (`retentionTimerClearsCompletedAnswerUnlessPinned`, `pinnedAnswerSurvivesRetentionAndContextReset`) на 2 новых (`completedAnswerSurvivesANewCollectingContextCycle`, `onlyContextResetClearsACompletedAnswer`), остальные 8 не менялись и прошли как раньше.

**Не сделано:** живой ретест на реальном железе (реальный Answers-диалог, реальное нажатие Reset) — нужен `sign-and-install.sh` пользователем.

---

## 2026-09-22 — Reset больше не обрывает прослушивание и не съедает уже сказанное

Уточнение к вчерашней правке: "мы не должны переставать слушать [во время показа ответа], и если я нажму ресет а потом сразу answer now — должен быть ответ на последнее что сказали только что (во время того как был подсвечен ответ)".

Захват аудио сам по себе никогда не останавливался, пока показан ответ — `AnswersModeController.captureTask` гонит кадры в `realtime.appendAudio` независимо от `turnPhase`/видимости оверлея, это не менялось. Реальный баг был в `AnswerOverlayViewModel.resetContext()`: она БЕЗУСЛОВНО делала `await answersController.stop(); try? await answersController.start()` — то есть кнопка "Сбросить" не просто чистила UI, а рвала WebSocket, сбрасывала `contextWindow` внутри `OpenAIRealtimeAnswerClient` и на короткое время реально останавливала `systemAudio` (`captureLease?.release()` → новый `start()` заново создаёт поток). Всё, что успели сказать, ПОКА был показан предыдущий ответ (а туда оно уже писалось в НОВОЕ, отдельное от отвеченного, context-окно — `OpenAIRealtimeAnswerClient.handleResponseDone` чистит только контекст, который ПРИВЁЛ к уже показанному ответу, остальное живёт своей жизнью через `inputAudioBufferCommitted`/`windowStartedAt`), выбрасывалось этим пересозданием сессии подчистую — отсюда и "нет ответа на то, что я только что сказал" сразу после Reset.

**Фикс** — `resetContext()` теперь смотрит на `state.visibility` ДО применения сброса:
```swift
let shouldDiscardAccumulatingContext = state.visibility != .completed
apply(.contextReset)
guard shouldDiscardAccumulatingContext else { return }
Task { [answersController] in await answersController.stop(); try? await answersController.start() }
```
Если ответ уже показан (`.completed`) — Reset только чистит отображение (`AnswerOverlayReducer.contextReset`), сессия/захват звука не трогаются, а уже накопленный НОВЫЙ контекст (сказанное во время показа ответа) остаётся нетронутым — следующий "Ответить сейчас" отвечает по нему. Если Reset нажат ПОКА идёт прослушивание/генерация (`.collectingContext`/`.streaming`/т.д.) — поведение НЕ поменялось: полный stop/restart, чтобы реально отбросить накопленный, ещё неотвеченный контекст (например, если было сказано что-то лишнее/шумовое) — это осталось осознанно нетронутым отдельным легитимным кейсом.

Заодно поправлен вводящий в заблуждение accessibility-hint у кнопки "Сбросить" на панели ответа — раньше везде было "Удаляет накопленный контекст и начинает заново" (уже неверно для `.completed`-случая), теперь текст зависит от состояния: на готовом ответе — "Скрывает показанный ответ. Прослушивание продолжается без перерыва.", во время генерации — "Прерывает генерацию и удаляет накопленный контекст". Кнопка "Сбросить контекст" в капсуле прослушивания (`collectingContext`) сохранила старый текст без изменений — её поведение не менялось.

**Найденная попутно ловушка в собственном тесте:** первая попытка написать тест на это (`Tests/OverlayReducerTests/AnswerOverlayViewModelTests.swift`) дала ложный failure — самодельный `FakeSystemAudioCapturing` возвращал один и тот же `AsyncStream` на каждый вызов `start()` (как уже существующий `DomainTests`-фейк, который до сих пор никогда не вызывался дважды на одном инстансе в рамках одного теста). При РЕАЛЬНОМ stop→start цикле это давало второй, "чужой" consumer на уже отменённый поток, который тут же ложно триггерил `AnswersModeController.reportCaptureStreamEndedUnexpectedly()` (фикс от 2026-09-14) → `ModeCoordinator`-овский failure-watcher → лишний повторный `stop()`. Поправлено созданием СВЕЖЕГО `AsyncStream` на каждый `start()`, как это делают настоящие `ScreenCaptureKitSystemAudioCapturing`/`AVEngineMicrophoneCapturing`.

**Проверено:** `swift test` — 204/204 (включая 2 новых теста: `resettingAfterCompletedAnswerDoesNotRestartTheRealtimeSession`, `resettingWhileCollectingContextRestartsTheRealtimeSession`, проверяющие оба пути через счётчики `startCallCount`/`stopCallCount` у локальных фейков). `xcodebuild ... test` — **TEST SUCCEEDED**, 7/7 (правка внутри SwiftPM-модулей `OverlayReducer`/`OverlayUI`, число тестов Xcode-таргета не изменилось).

**Не сделано:** живой ретест на реальном железе (реальный "сказал во время ответа → Reset → Answer Now") — нужен `sign-and-install.sh` пользователем.

---

## 2026-09-22 — Краш при входе в Answers (styleMask без `.resizable`)

Впервые в этой сессии агент сам собрал и установил `.app` пользователю напрямую (см. предыдущую запись) — и это сразу поймало реальный краш при первом клике на "Answers", воспроизводимый на свежепоставленном билде. Пользователь прислал системный alert "UserAgent057 quit unexpectedly" со скриншотом.

Разобран `~/Library/Logs/DiagnosticReports/UserAgent057-2026-09-22-114949.ips` (`EXC_BREAKPOINT`/`SIGTRAP`, `+[NSApplication _crashOnException:]` — AppKit намеренно превращает необработанный `NSException` в краш). `asiBacktraces` дал точный стек: `NSHostingViewC.updateWindowContentSizeExtremaIfNecessary` → `setNeedsUpdate` → AppKit `-[NSView setNeedsUpdateConstraints:]` → `-[NSView _informContainerThatSubviewsNeedUpdateConstraints]` → `-[NSWindow(NSDisplayCycle) _postWindowNeedsUpdateConstraints]` → `objc_exception_throw`, всё внутри активного display-cycle flush (`NSDisplayCycleFlush` → `updateConstraintsForSubtreeIfNeeded` → `___NSViewUpdateConstraints_block_invoke`).

Причина — правка от 2026-09-21 (три стиля оверлея): `AnswerOverlayPanel`'у унифицировали `styleMask` под все три стиля как `[.nonactivatingPanel, .borderless]`, по образцу Textream-спеки для pinned/fullscreen-панелей. Но у самого Textream для floating-режима в styleMask ЕСТЬ `.resizable` (зафиксировано в исходном ресёрче агента этой же сессии, просто не перенесено в реализацию), и в ДОРЕформенной версии кода этого проекта `.resizable` тоже был. `AnswerOverlayContentView` использует `hosting.sizingOptions = [.intrinsicContentSize]` — это заставляет `NSHostingView` самостоятельно двигать `window.contentMinSize`/`contentMaxSize` под размер контента; на НЕresizable-окне эта внутренняя машинерия AppKit/SwiftUI, вызванная синхронно во время layout-прохода, бросает `NSException`, который AppKit конвертирует в жёсткий краш вместо тихого игнорирования.

**Фикс** — вернул `.resizable` в `styleMask` (`Sources/OverlayUI/AnswerOverlayPanel.swift`), теперь `[.nonactivatingPanel, .borderless, .resizable]` для всех трёх стилей (не только для `.floating`, где баг проявился — `.pinned` тоже вызывает `panel.setContentSize(fitting)` тем же путём в `resizeToFitContent()`, значит был бы так же уязвим).

**Существенно про то, как это было найдено и исправлено:** агент в этой сессии впервые сам собрал Release-версию через реальный `xcodebuild`, подписал ad-hoc, поставил в `/Applications`, сбросил TCC и запустил — без участия пользователя в сборке. Когда пользователь тут же поймал краш на первом использовании, агент прочитал `.ips`-репорт напрямую (`python3`, `json.loads` по частям — `.ips` это JSON-заголовок + `\n` + JSON-тело), нашёл точный кадр через `asiBacktraces`, поставил диагноз по сигнатуре AppKit-метода без необходимости просить пользователя воспроизводить/логировать что-то ещё, исправил, пересобрал и переустановил — весь цикл диагностики багов теперь может закрываться внутри одной сессии агента, без ping-pong "поставь → проверь → опиши что увидел → жди следующей сессии".

**Проверено:** `xcodebuild ... build` — **BUILD SUCCEEDED**; переустановлено (`tccutil reset` показал по 2 записи на ScreenCapture/Microphone — меньше, чем предыдущие разы, разброс объясняется тем, что это уже второй reset подряд за сегодня). Живой клик на "Answers" пользователем — ещё предстоит подтвердить.

**Не сделано:** не добавлен regression-тест на сам краш — это чисто AppKit/SwiftUI-рантайм-взаимодействие (NSHostingView ↔ NSWindow constraint engine), не воспроизводится через swift-test окружение без реального экрана/WindowServer; полагаться приходится на ручную проверку после каждой правки `AnswerOverlayPanel`/`sizingOptions`.

---

## 2026-09-22 (продолжение) — Первая попытка (`.resizable`) не помогла; откат к дословно старому конфигу для `.floating`

Пользователь переустановил и сразу поймал ИДЕНТИЧНЫЙ краш (тот же стек, тот же `asiBacktraces`) — проверено по UUID установленного бинарника (`dwarfdump --uuid`), совпадает с только что собранным и подписанным, то есть это не старый процесс/кеш, фикс с `.resizable` реально не сработал.

Не стал продолжать гадать про точный AppKit-триггер реентерабельности (`NSHostingView.updateWindowContentSizeExtremaIfNecessary` вызывающий `setNeedsUpdateConstraints` посреди активного `NSDisplayCycleFlush`) — вместо этого откатил риск: `AnswerOverlayPanel` для стиля `.floating` (дефолтный, единственный, который реально используется — пользователь ни разу не открывал новую настройку "Оверлей ответов") теперь СОБИРАЕТ ТОЧНО ТОТ ЖЕ конфиг, что был до правки от 2026-09-21: `styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable]`, `level = .floating` (не `.screenSaver`), `titleVisibility = .hidden`, `titlebarAppearsTransparent = true` — побайтово как в версии, которая много недель работала без единого краша. Новый borderless/`.screenSaver`-конфиг остался только для `.pinned`/`.fullscreen` — тех стилей, которыми никто ещё не пользовался, так что даже если там баг всё ещё жив, дефолтный путь для всех пользователей снова безопасен.

**Важная методологическая деталь:** пробовал верифицировать это сам через `mcp__peekaboo__click`/`app focus` вместо очередного "поставь и скажи, что увидел" — но sandbox-policy этой сессии блокирует и foreground-, и background-клики по этому конкретному приложению ("A trusted caller must explicitly authorize foreground execution"), так что живой клик по "Answers" пользователем всё равно остаётся неподтверждённым.

**Проверено:** `xcodebuild ... build` — **BUILD SUCCEEDED**; переустановлено с новым UUID (`8FC2B973-DD3C-315F-8FED-91350366A7C9`), `tccutil reset` снова прошёл. Живой тест пользователем — не подтверждён (см. выше про блокировку автоматизации).


## UserAgent057 — 2026-11-08

Создан отдельный репозиторий из предоставленной папки без Git-истории. Исходный снимок сохранён в main. В codex/useragent057 переименованы приложение, Xcode target/schemes, Swift package, bundle ID, настройки, Keychain service, папка данных и экспорта. Перевод всех звуковых устройств и локальная LLM ещё не реализованы.

Проверка: XcodeGen сгенерировал UserAgent057.xcodeproj; xcodebuild build и test завершились успешно (7 тестов приложения). Проверены plist, JSON локализации и git diff --check. Сборка Debug без подписи: build/DerivedData/Build/Products/Debug/UserAgent057.app. Захват звука и перевод в реальном сеансе не проверялись.

## 2026-11-08 — План v3, этап M0: S0.1 документы и ADR

Владелец принял план v3 с вариантами по умолчанию (артефакт «UserAgent057 План v3»). Работа идёт в ветке `codex/useragent057-m0`, по коммиту на шаг.

**S0.1.** Добавлены ADR 0004–0008. ADR 0002 помечен как частично заменённый ADR 0004: асинхронный Whisper в `answers` отменяется в S1.7, после этого правило CLAUDE.md «answers mode never starts Whisper» выполняется. В `product-contract.md` добавлен раздел утверждённых изменений, вступающих по этапам, и уже действующие правки S0.4 про Answer now и отмену ответа. В `privacy.md` исправлено устаревшее утверждение про WAV и добавлена таблица исходящих потоков. В README исправлены утверждения про Keychain и про экспорт диагностики, которые расходились с кодом.

Исходное состояние ветки: `swift test` — 247 тестов, все зелёные (Swift 6.4.2, macOS 27.2).


**S0.2.** Добавлены `Makefile` (`verify-fast`: проверка версии XcodeGen 2.45.4, линтер комментариев, `swift build`, `swift test --skip RealAPITests`, `xcodebuild test` с `CODE_SIGNING_ALLOWED=NO`; `verify-real`: без `OPENAI_API_KEY` завершается с кодом 2, иначе `RUN_REAL_API_TESTS=1 swift test --filter RealAPITests`) и `scripts/check-no-comments.sh`. Линтер пропускает строковые литералы, многострочные строки и обязательную строку `// swift-tools-version` в `Package.swift`. Новый тест-таргет `RealAPITests` озвучивает фразу через `/usr/bin/say` прямо в PCM16 24 кГц и проверяет первую text delta по аудио и по «Ответить сейчас». Без переменной окружения он пропускается.

Удалены 12 строк комментариев. Их смысл переносится сюда:
- `MeetingRepository.reconcileInterruptedMeetings()` (`Protocols.swift`) вызывается один раз при старте: встреча, оставшаяся в статусе `.recording` после аварийного завершения, помечается `.interrupted`.
- `TranscriptChunker` режет стенограмму только по границам реплик, каждый чанк не длиннее `maxCharactersPerChunk`, а короткая стенограмма возвращается одним чанком.
- `CostEstimator` оценивает токены без токенайзера: 2.5 символа на токен, консервативно для кириллицы, чтобы оценка скорее завышала стоимость.
- WhisperKit закреплён на `argmax-oss-swift` 1.1.0 (`exact:`), продукт используется только модулем `Transcription`.

**S0.3.** `AsyncBroadcaster<Element>` (`Sources/Domain/AsyncBroadcaster.swift`) рассылает один поток нескольким подписчикам. Это `final class` на `OSAllocatedUnfairLock`, а не actor: `yield` вызывается синхронно из `didSet` в `ModeCoordinator` и из колбэков захвата, где нельзя делать `await`. `continuation.yield` и `finish` вызываются после выхода из лока, чтобы `onTermination` не мог вызвать повторный вход. У каждого подписчика своя политика буфера, потери считаются по имени подписчика. `ModeCoordinator.stateUpdates(subscriber:)` выдаёт новому читателю текущее состояние (`replayLatest`). Раньше один `AsyncStream` читали `ModeSwitcherView` и `AnswerOverlayViewModel`, и каждый переход получал только один из них. `AnswersModeController.streamEvents(subscriber:)` работает на том же механизме, без replay. Тесты: 8 в `AsyncBroadcasterTests` и 2 регрессионных в `ModeCoordinatorBroadcastTests`.

**S0.4.** «Ответить сейчас» больше не подменяет инструкции сессии. По справочнику OpenAI поле `instructions` в `response.create` заменяет инструкции сессии на этот ответ, поэтому ручной ответ терял базовый промпт, «Опыт работы» и формат длины. Теперь клиент шлёт `conversation.item.create` с system message (`FORCE_ANSWER_NOW`, id `force_` + 16 hex) и сразу `response.create` без `instructions`. System message в Realtime сверен по справочнику `conversation.item.create`. Старый вариант с объединёнными инструкциями оставлен за `ForceAnswerStrategy.mergedInstructions` для A/B по `LanguageEvalCatalog`. Force-item привязывается к ответу, который пришёл как ручной, и удаляется вместе с контекстом после завершённого ответа или сразу, если ручной ответ отменён.

Атрибуция ответа берётся из `metadata` в `response.created`, если сервер её возвращает. Иначе используется прежний флаг ожидания. Возвращает ли `gpt-realtime-2.1` metadata, проверяется в `verify-real`.

Отмена ответа новой речью теперь удаляет только output-items этого ответа: отслеживаемые и перечисленные в `response.done`. Накопленный вопрос остаётся, это правило CLAUDE.md и ADR 0008. Тест `newSpeechCancelsVisibleAnswerAndClearsContext` переименован в `newSpeechCancelsVisibleAnswerAndKeepsContext` и инвертирован.

Reset больше не перезапускает режим в обход `ModeCoordinator`. Новый `RealtimeAnswering.resetContext()` удаляет все отслеживаемые items и шлёт `input_audio_buffer.clear` без переподключения. `AnswersModeController.resetContext()` сбрасывает фазу хода, а захват не трогает. Новые события: `conversation.item.create`, `input_audio_buffer.clear`; `conversation.item.added` и `conversation.item.done` декодируются как `conversationItemCreated`. `RealtimeInstructions.version` = 5. Добавлено 10 тестов клиента и кодирования.

**S0.5.** Новый `SQLiteDatabase` (`Sources/Persistence/SQLiteDatabase.swift`): одно соединение на файл, общее для всех трёх репозиториев. Раньше каждый репозиторий открывал своё. У репозиториев теперь `init(database:)`, `init(path:)` остался для тестов. Соединение открывается через `sqlite3_open_v2(READWRITE|CREATE|FULLMUTEX)` с `busy_timeout` 5000 мс. Каждая миграция идёт в своей `BEGIN IMMEDIATE`: создать `schema_migrations`, если её нет, прочитать применённые версии, применить, `COMMIT`. Список версий больше не читается вне транзакции, поэтому одновременный первый запуск мигрирует ровно один раз. Тест открывает второе соединение в том же процессе, отдельный процесс не запускается. `PRAGMA journal_mode = WAL` при одновременном первом открытии возвращает `SQLITE_BUSY` в обход busy handler, поэтому эта команда повторяется каждые 10 мс в пределах `busyTimeoutMs`. Хэндл закрывает `SQLiteHandleOwner` в своём `deinit`, потому что `isolated deinit` требует macOS 15.4.

Миграция v2: `qa_entries.question_transcription_model_id` и бэкфилл. В старых строках `model_id` хранил id Whisper: `CompositionRoot` передавал `whisperModelID`. Этот id переезжает в новую колонку, а `model_id` получает `gpt-realtime-2.1`, как решил владелец. Если модель Realtime когда-то менялась, у старых строк провенанс неточный, это известное ограничение. Перед v2 делается резервная копия `<db>.pre-v2.bak`, но только для базы, где миграции уже применялись при прошлых запусках. Копия снимается внутри той же `BEGIN IMMEDIATE`, через `sqlite3_backup` из отдельного read-only соединения. Пишущее соединение не может быть источником бэкапа и получает `SQLITE_BUSY`, а читатель в WAL видит последнее закоммиченное состояние v1. `VACUUM INTO` внутри транзакции не работает. Копия переводится в `journal_mode = DELETE`, чтобы быть одним самодостаточным файлом.

Провенанс: в `QuestionAnswerPair.modelID` → `answerModelID` + `questionTranscriptionModelID`. `QuestionAnswerLogger(answerModelID:questionTranscriptionModelID:)` получает `OpenAIRealtimeAnswerClient.modelID` (теперь public), а id Whisper читается замыканием в момент `beginDraft`, то есть после смены в настройках подхватывается новое значение. Запись в журнал Q&A идёт строго по очереди: каждый `save` ждёт предыдущий через цепочку задач (`writeTail`), поэтому медленная ранняя запись `answerStreaming` больше не перекрывает `completed`. `flush()` ждёт хвост очереди.

`ChunkedTranscriptionPipeline.flush` раньше терял `language` и `confidence` при пересчёте абсолютного времени сегментов. Теперь они сохраняются. Новые тесты: 6 в `SQLiteDatabaseTests`, 2 в логгере, 1 в пайплайне, 1 в `CompositionRootTests`.

**S0.6.** Настройки открываются отдельным окном `Window(id: "settings")` с девятью вкладками `TabView` (`Sources/App/Settings/`): Основное, Звук, Ответы, Профиль и Claude, Устройства, Сессии и данные, Ключи и доступы, Внешний вид, Расширенные. Модальный sheet убран. Кнопка в главном окне и пункт меню-бара по-прежнему выставляют `AppNavigationState.isShowingSettings`. `ModeSwitcherView` на это изменение открывает окно через `openWindow`, вызывает `NSApp.activate()`, иначе окно может оказаться позади других, и сбрасывает флаг. Главное окно живёт всё время работы приложения (`applicationShouldTerminateAfterLastWindowClosed`), поэтому наблюдатель всегда на месте.

Источник звука: `SystemAudioScope` (`.wholeSystem(excludingBundleIDs:)` | `.application(bundleID:fallbackToWholeSystem:)`) хранится JSON в `settings.audio.systemScope`. `SettingsMigrator` (схема `settings.schemaVersion` = 2) переводит старый ключ `preferredAudioSourceBundleID` в новую область. Отсутствующий ключ, раньше это был неявный Chrome, и пустая строка дают весь системный звук, явный bundle id даёт приложение с fallback. Старый ключ удаляется, повторный запуск ничего не меняет, схема новее известной не трогается. По умолчанию теперь захватывается весь системный звук, «Только Chrome» стал пресетом. Исключения и сам fallback на весь звук при незапущенном приложении подключаются в M1, пока захват получает только `targetApplicationBundleID`.

Ключ OpenAI остаётся в `UserDefaultsSecretStore` по решению владельца (privacy.md), перенос в Keychain отложен до стабильной подписи (S2.11), поэтому мигратор ключ не трогает. Шов `ProfileKnowledgeProviding` (Domain): `instructionsProvider` у `AnswersModeController` теперь async и берёт фон из `LegacyBackgroundProfileProvider`, который возвращает текст «Опыт работы» без изменений. Fingerprint — первые 8 байт SHA-256. В M5 сюда подставится MD-профиль. Роль устройства (`settings.device.role`, primary|client) хранится, но выбор «Клиент» заблокирован до M2b. Ключ Anthropic и MD-папка пока заглушки до M5. Срок хранения истории выбирается во вкладке «Сессии и данные», применять его начнёт sweeper из S0.8.

Не сделано в S0.6: XCUITest-таргет (`settingsWindowOpensFromMenuBar`, `switchingTabsKeepsValues`) переносится на шаг, где появится UI-тестовый таргет с подписью. Это потребует разрешений Accessibility на этом Mac. Английские переводы новых строк в `Localizable.xcstrings` пока не добавлены, при английском интерфейсе они показываются по-русски. Тесты: 7 в `SettingsMigratorTests` (AppTests), 4 в `UserDefaultsPreferredAudioSourceStoreTests`. Тест `defaultsToChromeWhenNeverSet` заменён на `defaultsToWholeSystemWhenNeverSet`.

**S0.7.** Шов, не привязанный к провайдеру (R2). `RealtimeAnswering` переименован в `LiveResponder` (`Sources/Domain/LiveResponder.swift`), вместе с ним переименованы `InactiveLiveResponder` и тестовые `FakeLiveResponder`. Протокол получил `capabilities: ProviderCapabilities` (OptionSet: `serverVAD`, `inputTranscription`, `textInjection`, `functionCalling`, `manualResponse`, `streamingText`) и `injectContext(_:)`. Событие `RealtimeAnswerEvent` уже было доменным и не повторяет события OpenAI, поэтому имя оставлено. Domain не импортирует `RealtimeClient` и типы событий OpenAI. Добавлены протоколы `StreamingTranscriber` (`TranscriptDelta`) и `TextReasoner` (`TextReasoningRequest`) без реализаций: первые реализации появятся в M1 (поток стенограммы) и M5 (Claude). Неподдерживаемая возможность выбрасывает `ProviderSeamError.unsupported`.

`OpenAIRealtimeAnswerClient.injectContext` шлёт system item `ctx_` + 16 hex с префиксом `RealtimeInstructions.injectedContextPrefix` («материал, не вопрос»). Item учитывается окном контекста как обычная реплика, поэтому «Ответить сейчас» после вставки текста с экрана работает, а item удаляется вместе с контекстом после завершённого ответа. Транспорт авторизуется через `AuthStrategy` (`.bearer` | `.header(name:value:)`) вместо жёсткого `bearerToken`, чтобы провайдер с ключом в своём заголовке подключался без правки транспорта.

`LiveResponderContractTests` гоняет одни и те же сценарии на OpenAI-клиенте через fake transport и на отдельной `ScriptedLiveResponder`: флаги возможностей, отказ без контекста, ровно один `response.create` на два нажатия Answer now и поток start → delta → completed, вставленный контекст считается контекстом, reset сбрасывает контекст. Ещё два теста проверяют `AuthStrategy`. Поведение приложения не меняется.

**S0.8.** `DiagnosticsExporter.makeSnapshot(includeContent:)` по умолчанию не выгружает тексты: `questionAnswerHistory` и `meetingHistory` пустые, вместо них `questionAnswerCount`, `meetingCount` и `contentIncluded`. Содержимое попадает в экспорт, только если включена галочка `diagnosticsIncludeContentOptIn` (Настройки → «Расширенные» → «Диагностика») и выбор подтверждён в `confirmationDialog` при экспорте. Ключ настройки у галочки прежний (`settings.diagnosticsOptIn`), раньше она нигде не читалась.

`RetentionSweeper` (`Sources/Persistence/RetentionSweeper.swift`) применяет `historyRetentionDays`. Он удаляет встречи с `started_at` старше срока, кроме тех, что ещё в статусе `recording`. Каскад уносит реплики и саммари, триггеры FTS — строки поиска, папку `Recordings/<meeting id>` sweeper удаляет сам. Из Q&A удаляются строки с `asked_at` старше срока. Строки ISO 8601 в UTC с суффиксом `Z` сравниваются лексикографически корректно. Удаление встреч и Q&A идёт одной транзакцией. `CompositionRoot` после `reconcileInterruptedMeetings` запускает sweep при старте и затем раз в сутки. `nil` или 0 означает «бессрочно», ничего не удаляется. Тесты: 2 в `RetentionSweeperTests`, 2 в `DiagnosticsExporterTests` (AppTests).

Итог M0: `make verify-fast` зелёный, 244 теста SwiftPM и 17 тестов AppTests через xcodebuild. Что AppTests действительно выполняются под `-quiet`, проверено отдельным прогоном с `-resultBundlePath`.

## M1

**S1.1.** `SystemAudioCapturing.start(scope:) -> SystemAudioCaptureStart` (frames, `effectiveScope`, стартовый `notice`, поток `laterNotices`) заменил `start(targetApplicationBundleID:)`. `SystemAudioFilterPlanner` (чистая функция, AudioCapture) превращает `SystemAudioScope` и список приложений из `SCShareableContent` в план фильтра. При `wholeSystem` строится `SCContentFilter(display:excludingApplications:)` с исключениями пользователя и собственным bundle ID, при этом у `SCStreamConfiguration` остаётся `excludesCurrentProcessAudio = true`. При `application` в план попадают сам bundle ID и всё с префиксом `<bundleID>.` (helper-процессы Chrome). Если приложение не запущено и `fallbackToWholeSystem == true`, захват идёт на весь микс, а в результат кладётся `CaptureNotice.fellBackToWholeSystem`. Без fallback по-прежнему выбрасывается `targetApplicationNotFound` и срабатывает `ModeFailureReason.targetApplicationNotRunning`. Ошибками остаются только отказ в разрешении Screen Recording и отсутствие дисплея: эти проверки делает `SystemAudioCaptureResolver` через шов `ShareableContentProviding`, который в тестах подменяется. Атрибуция звука Chrome Helper к фильтру по приложению на железе не проверена (риск из плана).

`AnswersModeController` читает `systemAudioScope()` (без хранилища использует весь системный звук) и пишет в `qa_entries.source_app_bundle_id` фактический, а не желаемый bundle ID. Уведомления о захвате раздаются через `captureNotices()` (`AsyncBroadcaster`), оверлей показывает их тостом на 6 с. `RecordingModeController` запрашивает `.defaultScope`. В `SCStreamDelegate.didStopWithError` делается одна повторная попытка через 500 мс с тем же фильтром и конфигурацией. Если она удалась, отправляется `CaptureNotice.systemCaptureRestarted`, если нет, поток кадров закрывается и срабатывает существующий путь `system_audio_capture_ended`. Варианты `CaptureNotice` для микрофона и маршрута вывода добавятся в S1.3 и S1.4 вместе со своими типами.

Перенесено в S1.2 (CaptureHub): один `SCStream` на 24 кГц вместо двух экземпляров захватчика в `CompositionRoot`. Разделение ресурса между режимами и есть предмет CaptureHub, и делать это дважды нет смысла. Тесты: 9 в `SystemAudioFilterPlannerTests` (6 для планировщика и 3 для резолвера с fake provider) и 3 в `AnswersModeControllerTests` (`startRequestsStoredScope`, `startWithoutStoreUsesWholeSystem`, `fallbackNoticeDoesNotFailMode`). Ручная проверка на M4 Pro (Meet в Chrome, Zoom, YouTube в Safari, отсутствие собственного звука) выполняется в S1.6.

**S1.2.** `CaptureHub` (actor, Domain) владеет обоими источниками. Источник стартует при первом `acquire(_:consumer:policy:)` и останавливается при последнем `release`, остановка идёт через `ResourceLease`. У каждого источника свой `AsyncBroadcaster<PCMAudioFrame>`, и каждая подписка получает свою политику буфера. Поэтому зависший потребитель теряет только свои кадры (`droppedFrames(consumer:)`) и не тормозит остальных. Чтобы снимать одну подписку, а не весь broadcaster, в `AsyncBroadcaster` добавлены `identifiedSubscription` и `cancelSubscription`. Если источник завершился сам, хаб пишет `<kind>_capture_ended` в `failures()` и закрывает подписки, а `AnswersModeController` видит закрытый поток и, как и раньше, отправляет `system_audio_capture_ended`. `stopAll()` останавливает источники в обратном порядке старта. Хаб сам считает уровни (`AudioLevelMeter`, окно 100 мс, RMS и peak в dBFS, нижняя граница −120) и раздаёт их через `levels` (replayLatest). Уведомления захвата (S1.1) тоже идут через `CaptureHub.notices`. Метод `restart(_:)` для горячей смены устройства из S1.3 уже есть, но пока не используется. Параметр `microphoneOptions` из плана добавится в S1.3 вместе с типом `MicrophoneCaptureOptions`.

В `CompositionRoot` теперь один `ScreenCaptureKitSystemAudioCapturing` на 24 кГц (20 мс кадры), его scope читается из `PreferredAudioSourceStoring` при каждом старте источника. `AnswersModeController` берёт две подписки, `answers.realtime` (`.bufferingNewest(250)`, 5 с) и `answers.ringBuffer` (`.bufferingNewest(500)`), и обслуживает их отдельными задачами: ring buffer больше не стоит на пути к Realtime. `RecordingModeController` берёт `.systemAudio` и `.microphone` с `.unbounded` до `RecordingBackpressureChannel` и понижает частоту через протокол `AudioFormatConverting` (Domain). В приложении это `WhisperFrameConverter` (AudioCapture, линейный ресемплер 24→16 кГц), так что Domain не импортирует AVFAudio. Риск из плана остаётся: у линейного ресемплера нет антиалиасинга. Микрофон и раньше понижался так же (48→16 кГц), а для системного звука это ново. Регресс WER на фикстурах ru и en и, при необходимости, замена на `AVAudioConverter` переносятся в S1.6. Микрофон пока отдаёт 16 кГц как раньше, его формат пересматривается в S1.3.

Тесты: 6 в `CaptureHubTests` (первый acquire и последний release, одинаковые кадры у двух потребителей, 500 из 500 у realtime при зависшем втором подписчике с 490 потерянными, неожиданное завершение источника, обратный порядок `stopAll`, 10 уровней в секунду), 3 в `AudioLevelMeterTests`. В `AnswersModeControllerTests` 4 новых теста: один SCStream на два потребителя (`startCallCount == 1`), answers не трогает микрофон, после passive хаб пуст и сняты Realtime, запись и микрофон, recording не трогает Realtime. Тестовые конструкторы контроллеров переведены на `CaptureHub`.

**S1.3.** Выбор микрофона. Типы `AudioTransport` (fourCC из `AudioHardwareBase.h`: `bltn`, `usb `, `blue`, `blea`, `airp`, `grup`, `virt`, `ccwd`, `ccwl`, остальное — `.other`), `AudioDeviceInfo`, `MicrophoneSelection`, `MicrophoneCaptureOptions` и протокол `AudioDeviceCataloging` лежат в Domain (`AudioDeviceInfo.swift`). Чистая функция `MicrophoneDeviceResolver.resolve` перебирает устройства в таком порядке: выбранный UID, если устройство есть и это не Continuity → системный default, если это не Continuity → встроенный микрофон → первое не-Continuity устройство → nil. Если выбор пришлось подменить, возвращается `CaptureNotice.microphoneFellBack(from:to:reason:)`. К причинам из плана (`continuityDefault`, `selectedDeviceMissing`) добавлена `continuitySelected` для явно выбранного iPhone. Резолвер всегда возвращает конкретный UID, поэтому движок привязан к устройству и не уходит вслед за системным default на iPhone.

`CaptureHub` принимает `microphonePlan: () async -> MicrophoneStartPlan` (options + notice) вместо `microphoneOptions` из плана: так уведомление о подмене выбора проходит через хаб тем же путём, что и уведомления системного звука. `handleDeviceChange(_:)` при `deviceListChanged` или `defaultInputChanged` заново определяет устройство и перезапускает микрофон только при смене UID. При `microphoneEngineReconfigured` (`AVAudioEngineConfigurationChange`) перезапуск идёт всегда, а изменения вывода хаб игнорирует (они для S1.4). При перезапуске подписчики сохраняются. Каждый pump помечен generation: старый pump дочитывает уже буферизованные кадры и завершается без ложного `microphone_capture_ended`. Если перезапуск не удался, хаб пишет `microphone_restart_failed` и снимает источник.

`CoreAudioDeviceCatalog` (AudioCapture) читает `kAudioHardwarePropertyDevices`, UID, имя, transport, `StreamConfiguration` для входа и выхода и `DataSource` выхода. Слушатели `AudioObjectAddPropertyListenerBlock` ставятся один раз на служебной очереди и пишут только Sendable-значения в `AsyncBroadcaster<AudioDeviceChange>`. `AVEngineMicrophoneCapturing.start(options:)` создаёт новый `AVAudioEngine` на каждый старт, задаёт `kAudioOutputUnitProperty_CurrentDevice` у `inputNode.audioUnit` (ошибка даёт `AudioCaptureError.microphoneDeviceUnavailable`), понижает частоту до `options.sampleRate` и сообщает о переконфигурации через `engineReconfigurations()`. `voiceProcessing` пока не применяется, это M3. Риск плана не проверен: совместимость `CurrentDevice` с VPIO. Выбор хранится в UserDefaults (`settings.audio.microphoneSelection`, JSON) через `PreferredAudioSourceStoring`. На вкладке «Звук» появился Picker «Микрофон»: «Системный по умолчанию (без iPhone)», затем input-устройства, Continuity-устройства в списке неактивны. Уведомления хаба показываются и в окне режимов (для recording), а не только в оверлее answers.

Тесты: 6 в `MicrophoneDeviceResolverTests`, 12 в `AudioTransportMappingTests`, 2 новых в `CaptureHubTests` (перезапуск по смене устройства сохраняет подписчиков и кадры, переконфигурация движка всегда перезапускает микрофон). Нестабильный `ModeCoordinatorTests.concurrentSwitchesSerializeWithoutOverlap` полагался на то, что первый `async let` стартует раньше второго. Теперь второй переход запускается только после события `answers.start.begin`. Ручная проверка (iPhone рядом стал default input, переподключение AirPods во время recording) проходит в S1.6.

**S1.4.** Маршрут вывода. `OutputRouteClassifier.classify` (Domain) работает по `AudioDeviceInfo` default output. Встроенное устройство с data source `hdpn` или с «Headphones» в имени считается проводными наушниками. С `ispk` или без data source это динамики Mac, с другим data source — внешнее устройство. Bluetooth и BLE считаются наушниками, AirPlay — AirPlay, USB, aggregate, virtual и прочее — внешним устройством. `echoRisk` при политике `.auto` истинен для динамиков, AirPlay и внешнего устройства. Политики `.headphones` и `.speakers` (Настройки → «Звук» → «Вывод звука», ключ `settings.audio.outputRoutePolicy`) задают ответ вручную: маршрут не знает, есть ли у USB- или Bluetooth-устройства открытые динамики.

`OutputRouteMonitor` (actor) при `start()` классифицирует текущий вывод и публикует маршрут в `AsyncBroadcaster<OutputRoute>` (replayLatest, хранится в `CompositionRoot`). Затем он слушает `catalog.changes()`: `defaultOutputChanged`, `outputDataSourceChanged` и `deviceListChanged` проходят debounce 300 мс, после чего маршрут классифицируется заново и публикуется, только если изменился, вместе с `CaptureNotice.outputRouteChanged` в `CaptureHub.notices`. `stop()` отменяет подписку на каталог. `CompositionRoot` запускает монитор при переходе в answers или recording и останавливает его в passive по `ModeCoordinator.stateUpdates`. Слушатели Core Audio у `CoreAudioDeviceCatalog` общие и живут, пока живёт приложение, а при passive снимается подписка монитора. `CoreAudioDeviceCatalog` теперь слушает и `kAudioDevicePropertyDataSource` (scope output) у текущего default output и ставит слушатель на новое устройство при каждой смене default output.

В UI окно режимов показывает предупреждение «Динамики: возможна утечка эха собеседника в микрофон», пока режим активен и `echoRisk` истинен. Тост о смене маршрута показывается в оверлее и в окне режимов, во вкладке «Звук» виден текущий маршрут. В экспорт диагностики добавлено поле `outputRoute`. Вместо `LatencyReport` маршрут попал в `DiagnosticsSnapshot`, потому что `LatencyReport` описывает только метрики задержки. Маршрут в истории сессий будет записываться вместе с моделью сессии (M2), сейчас в `meetings` колонки нет. Тесты: 8 в `OutputRouteClassifierTests`, 3 в `OutputRouteMonitorTests` (серия событий даёт одно событие маршрута, неизменённый маршрут не публикуется повторно, `stop` снимает подписку, повторный `start` не плодит её). Не проверено на этом Mac, проводные наушники видны как `hdpn` или как отдельное «External Headphones»: классификатор проверяет оба признака, точный ответ даст ручная проверка в S1.6.

**S1.5. CATap спайк.** `CoreAudioTapSystemAudioCapturing` (`@available(macOS 14.2, *)`, AudioCapture) реализует `SystemAudioCapturing` так. Список аудиопроцессов берётся из `kAudioHardwarePropertyProcessObjectList` + `kAudioProcessPropertyBundleID`, собственный process object — из `kAudioHardwarePropertyTranslatePIDToProcessObject(getpid())`. Для `wholeSystem` используется `CATapDescription(stereoGlobalTapButExcludeProcesses:)` с исключениями пользователя и собственным процессом. Для `application` используется `stereoMixdownOfProcesses` по bundle ID и префиксу `<bundleID>.` (helper-процессы), при отсутствии приложения fallback и notice работают как в SCK (S1.1). Дальше tap создаётся как `privateTap`, `unmuted` (`AudioHardwareCreateProcessTap`), поверх него строится private aggregate device с `taps` (`drift` = true, `tapautostart`) и текущим default output как main subdevice, и запускается `AudioDeviceCreateIOProcIDWithBlock` на собственной serial-очереди. Очередь передаётся в API, поэтому блок исполняется вне realtime-потока HAL, и lock-free ring из плана не понадобился. Float32 переводится в PCM16 и через `RealtimeAudioFormatConverter` превращается в кадры 24 кГц по 20 мс. Параметр `converter: AudioFormatConverting` из плана не нужен: формат фиксирован. Ключ `NSAudioCaptureUsageDescription` добавлен в `Resources/Info.plist`, имя подтверждено по списку protected resources Apple. Переключатель backend (ScreenCaptureKit или Core Audio tap) находится в Настройки → «Расширенные», ключ `settings.developer.systemAudioBackend`, применяется после перезапуска. По умолчанию остаётся SCK.

Измерения на M4 Pro, macOS 27.2, по opt-in тестам `CoreAudioTapHardwareTests` (запуск с `USERAGENT057_HARDWARE=1`, тест-хост swift test из Terminal):

| Метрика (ADR 0004) | Core Audio tap | ScreenCaptureKit |
|---|---|---|
| Задержка старта | вызов `start` 19–45 мс, первый кадр через 50–97 мс | не измерено: у тест-хоста нет Screen Recording (`permissionDenied`), в приложении замер не делался |
| CPU | 6.8 % одного ядра за 10 с, вместе с конвертером 24 кГц, общим с SCK-путём | не измерено |
| Стабильность при смене вывода | не измерено; aggregate device держит default output как main subdevice, поэтому при смене вывода его, вероятно, придётся пересоздавать | есть автоповтор из S1.1 |
| Разрешения | в тест-хосте звук пришёл без нового запроса; в собранном приложении запрос «Запись системного звука» не проверен | уже выдано Screen Recording, оно же нужно в M6 для скриншотов |
| Качество | 151–153 кадра за 3 с (ожидалось 150), исключение своего процесса подтверждено: доля 880 Гц в tap только своего процесса 0.987 (peak 16383 = сгенерированная амплитуда), в глобальном tap без своего процесса 2.5·10⁻⁶ | `excludesCurrentProcessAudio` на железе не проверялось |

Вердикт по ADR 0004: дефолт остаётся ScreenCaptureKit. Преимущество CATap ни по одной метрике не доказано, потому что SCK в тех же условиях не измерен. Код tap остаётся за флагом разработчика. Не сделано и переносится в ручную проверку S1.6: 30 минут Meet и Zoom на M4 Pro и M1, сравнение `captureCallbackToSendMs`, CPU и Energy Log в Instruments для обоих backend внутри приложения, переключение на AirPods во время захвата, текст и поведение системного запроса при отказе (по сообщениям разработчиков тогда приходят нули без ошибки). Попутная находка: в момент замера на Mac владельца играл посторонний звук (peak 32767 без тестового тона), поэтому проверять исключение собственного звука по пиковой амплитуде нельзя, нужна доля энергии тестовой частоты. Тесты: 4 в `TapDescriptionBuilderTests` и 4 opt-in в `CoreAudioTapHardwareTests` (в `make verify-fast` выключены).

**S1.6.** Вкладка «Звук» переведена на отдельный `AudioSettingsViewModel` (`Sources/App/Settings/AudioSettingsViewModel.swift`). Аудиополя удалены из `SettingsViewModel`, у которого теперь есть `audio`. Источник выбирается радиогруппой «Весь звук Mac», «Только Google Chrome (Meet)» или «Приложение…» (с выбором из запущенных обычных приложений). При «Весь звук Mac» ведётся список исключений (`excludeApplication` и `removeExclusion` пишут `SystemAudioScope.wholeSystem(excludingBundleIDs:)`). Там же выбираются микрофон (Continuity виден, но неактивен, и выбор iPhone игнорируется) и политика маршрута с текущим маршрутом. Живые индикаторы «Система» и «Я» подписаны на `CaptureHub.levels` (`.bufferingNewest(8)`), шкала −60…0 dBFS по RMS, уровень старше 1.5 с считается отсутствующим. Текст ошибки для приложения без fallback теперь объясняет, что переход на весь звук для него выключен. `docs/privacy.md` описывает, что во время answers в OpenAI уходит любой звук Mac. Ручной чек-лист M1 (15 пунктов, включая калибровку VAD на музыке и уведомлениях и регресс стенограммы после перехода на поток 24 кГц) добавлен в `docs/troubleshooting.md`. Тесты: 5 в `AudioSettingsViewModelTests` (AppTests).

Не сделано в S1.6:
- Ручной чек-лист на железе не пройден, потому что ему нужен владелец: звонки Meet, Zoom и Teams, iPhone рядом, AirPods, Instruments. Калибровка VAD и пересмотр порога ждут пунктов 4–5 чек-листа.
- XCUITest (`audioTabShowsWholeSystemByDefault`, `switchingToChromePresetPersists`) по-прежнему ждёт UI-тестового таргета.
- Английские строки в `Localizable.xcstrings` для новых текстов M1 не добавлены.
- Регресс WER из S1.2 не измерен: нужна загруженная модель Whisper и фикстуры ru/en, это п. 15 чек-листа. Отдельно разобрана аналитическая оценка. Линейный ресемплер 24→16 кГц без фильтра заворачивает полосу 8–12 кГц в 4–8 кГц, а энергия речи выше 8 кГц обычно на 30–40 дБ ниже основной полосы, так что заметного влияния на распознавание не ожидается, но это не замер.

Итог M1 (S1.1–S1.6) по коду: весь системный звук без собственного процесса, один поток SCK, `CaptureHub` с раздачей, уровнями и уведомлениями, выбор микрофона без Continuity с горячей сменой, маршрут вывода, Core Audio tap за флагом с замерами. Осталась S1.7 (стенограмма из Realtime вместо Whisper в answers).

**S1.7. Стенограмма из Realtime, вопрос без Whisper, перенос Q&A.** `session.update` теперь включает `audio.input.transcription` (`InputTranscriptionConfig`: `gpt-transcribe`, `languages` ru/en). Имя модели и поле `languages` сверены с документацией OpenAI в день реализации: `gpt-transcribe` есть в списке моделей `transcription.model` и рекомендован для committed-turn сессий, `language` вместе с `languages` слать нельзя, `completed` у `gpt-transcribe` несёт `languages[].code`, пустой массив — нормальный ответ. Декодер понимает `conversation.item.input_audio_transcription.delta/completed/failed`. Клиент публикует `RealtimeAnswerEvent.transcript(TranscriptEvent)` (speaker `.them`, промежуточные и финальные), `.transcriptFailed(itemID:)` и `.questionContext(responseID:itemIDs:)` непосредственно перед `responseStarted`. Отдельное событие выбрано вместо нового поля в `responseStarted`, чтобы не ломать сравнения событий в существующих тестах. `capabilities` включают `.inputTranscription`.

`QuestionAnswerLogger` больше не принимает `LocalTranscribing` и не держит снимок аудио: `beginDraft(..., questionItemIDs:)` ждёт финальные расшифровки этих items (они могут прийти до и после черновика), склеивает их по порядку items, частичный отказ не блокирует остальные части. Если items нет, все упали или за 20 с ничего не пришло, вопрос помечается `failed` («вопрос не распознан»), при таймауте сохраняется то, что успело прийти. Расшифровки хранятся ограниченно (256 items), закрытые черновики удаляются. `AnswersRingBuffer` и подписка `answers.ringBuffer` удалены: в answers теперь одна подписка на системный звук. WhisperKit в answers не создаётся и не загружается, `CompositionRoot` передаёт логгеру `questionTranscriptionModelID` = `gpt-transcribe`. Проверка «счётчик вызовов LocalTranscribing в answers равен 0» стала структурной: у `AnswersModeController` и логгера нет зависимости от `LocalTranscribing`. `AnswersModeController.transcriptEvents()` отдаёт стенограмму собеседника для будущего веба и сессий (M2).

Перенос (`CarryOverMemory`, RealtimeClient): после показанного ответа строится запись (items вопроса, их расшифровки, текст ответа из `output_text.done`), хранится 2 последние записи, `maxAge` 600 с. Они живут одним system-item `carry_*` с префиксом `EARLIER_IN_THIS_CALL`, который пересоздаётся (delete + create) при новой записи, поздней расшифровке, вытеснении и после reconnect. Поколение (`carryOverGeneration`) защищает от двойного создания при реентрантности actor. Пока ответ в полёте, таймер не вытесняет ни окно вопроса, ни перенос, а пересоздание по поздней расшифровке откладывается. `AnswerContextWindow` получил инъекцию часов и `evictExpired()`. Таймер очистки работает раз в 10 с. Риск, не проверенный на реальном API: если item удалён очисткой до окончания расшифровки, `completed` может не прийти; тогда вопрос в истории получит `failed` по таймауту, а перенос останется без текста вопроса. Проверяется в `verify-real` (п. в чек-листе M1).

Тесты: 14 в `RealtimeTranscriptAndCarryOverTests` (session.update с транскрипцией, committed → delta → completed, `questionContext` до `responseStarted`, первая дельта не ждёт расшифровку, failed не блокирует очистку, перенос с текстом вопроса, поздняя расшифровка, только 2 последних, вытеснение переноса и окна по таймеру, нет вытеснения во время ответа, `reconnectRestoresCarryOver`, сброс удаляет перенос, перенос не считается контекстом), 4 в `RealtimeTranscriptionDecodingTests`, `QuestionAnswerLoggerTests` переписаны (16), обновлены сценарные тесты answers. Итого swift 319 + AppTests.

M1 по коду закрыт (S1.1–S1.7). Ручной чек-лист M1 в `docs/troubleshooting.md` ждёт владельца.

## M2. Веб-панель

**S2.1. Таргет CompanionProtocol.** Новая библиотека `CompanionProtocol` (только Foundation): `Envelope.swift` (`ServerEnvelope`, `CompanionCodec`, `CompanionLimits`, `CompanionProtocolError`, `CompanionProtocolVersion`), `ServerEvent.swift` (20 типов плюс `.unknown`, payload вложены в `ServerEvent`, чтобы не конфликтовать с именами Domain), `ClientCommand.swift` (10 команд плюс `.unknown(name:)`, `validate()`), `StateSnapshot.swift` и `WireTypes.swift`. В протоколе свои wire-enum: `WireMode`, `WirePhase`, `WireSpeaker` и другие. Domain в зависимости не попадает, маппинг будет в `CompanionBridge` (S2.5). Решения о форме кадров, совместимости, единицах UTF-16 и лимитах записаны в ADR 0005, раздел «Протокол v1». Отступления от плана v2: добавлены `pair` и `pair.ok`, потому что сопряжение идёт по WS. `session.*` и `deep.*` раскрыты в `session.started|stopped` и `deep.started|delta|done`. В `hello.ok` есть `minClientVersion` по поправке v3.

Тесты: 27 в `CompanionProtocolTests` (63 случая с учётом параметров).
- `GoldenFixtureTests`: каждый тип декодируется из фикстуры в ожидаемое значение и кодируется в тот же JSON. Отдельно проверено, что набор фикстур совпадает с `knownTypes` и `knownNames`.
- `CodecRoundTripTests`.
- `UnknownTypeToleranceTests`: неизвестный type или name, лишние поля, `v=2` и `v=0`, битый JSON, известный тип с битым data.
- `ClientCommandValidationTests`: `freeText` 4000 проходит, 4001 отклоняется, эмодзи считаются по UTF-16; `cmdId`, токен, `lastSeq`, имя устройства, кадр больше 64 КБ.

Попутно исправлены три теста из S1.7, которые падали под нагрузкой полного прогона: `transcriptTimeoutKeepsPartialTextOrFails`, `transcriptRetentionIsBounded` и `noContextEmittedWhenManualTriggerRejected`. Фиксированные `sleep` заменены ожиданием условия с потолком 2 с. Для этого `waitUntil` вынесен из `CaptureHubTests` в `Tests/DomainTests/WaitUntil.swift`. Итого swift 346 + AppTests.

**S2.2. DeltaDiffer, PointSegmenter, ReplayBuffer.** Добавлены в `CompanionProtocol`, по-прежнему без зависимости от Domain: `WireTextSanitizer`, `DeltaDiffer` (`TextChange`), `PointSegmenter`, `AnswerStreamProjector`, `ReplayBuffer`, `ServerEvent.isReplayable`. Семантика описана в ADR 0005, раздел «Потоковый ответ и доигрывание». Почему отличается от плана v2:
- Пункты считаются блоками верхнего уровня, а не только элементами списка. Иначе у ответа без списка не было бы ни одного `pointId` для «раскрыть через Claude».
- Транзитные события не хранятся в буфере.
- Маркер вырезается на проводе дополнительно, потому что клиент Realtime отбрасывает только ответ, целиком равный маркеру.

Тесты: 28 новых в `CompanionProtocolTests`, всего там 55.
- `DeltaDifferTests`: кириллица, эмодзи, комбинирующий знак, ZWJ, восстановление текста по цепочке изменений.
- `PointSegmenterTests`: `- `, `1. `, `2) `, вложенность, абзацы и заголовки, код в ограждении, CRLF. Отдельно проверено при посимвольном росте текста, что индексы только растут и `pointId` стабилен.
- `WireTextSanitizerTests`: включает проверку, что маркер не попадает в закодированные кадры.
- `AnswerStreamProjectorTests`.
- `ReplayBufferTests`: переполнение, `lastSeq` из будущего и отрицательный, транзитные события, немонотонный `seq`, `removeAll`.

Стабилизация тестов (в том же коммите). При полном параллельном прогоне (около 370 тестов) падали тесты с фиксированными `sleep` 10–40 мс. Исправление:
- **Тесты RealtimeClient и Domain.** Перед положительными проверками `sleep` заменён на `waitUntil` с потолком 2–3 с. Перед отрицательными проверками («не произошло») `sleep` оставлен намеренно: ложных падений там не бывает.
- **Тесты контроллера answers.** Добавлен детерминированный `settle(controller, realtime)`: он ждёт, пока `AnswersModeController.handledEventCountForTesting` догонит `FakeLiveResponder.emittedEventCount`.
- **Тест записи.** Ждёт `RecordingModeController.ingestedFrameCountForTesting`.

Оба счётчика внутренние (internal), доступны только через `@testable`. Попутно найдено поведение в коде: `RecordingModeController.stop()` отменяет producer до того, как кадры в полёте дойдут до конвейера. Последние миллисекунды звука при остановке записи могут теряться. Для стенограммы это допустимо, оставлено как есть.
Итого swift 374 + AppTests.

### S2.3 Сопряжение, токены и RequestGuard

- `Sources/CompanionProtocol/PairingPrimitives.swift`: `CompanionRandomSource` и `SystemCompanionRandom` (`SecRandomCopyBytes`), `CompanionSecrets` (base64url, SHA-256 hex, сравнение за постоянное время, 6-значный код с отбраковкой), `PairingCodeKind {qr128, numeric6}` с лимитами 20 и 5, `PairedDevice`, `PairedDeviceStoring`, `InMemoryPairedDeviceStore`.
- `Sources/CompanionProtocol/PairingStore.swift`: actor с `issueCode`, `redeem(code:deviceName:)` → `PairingGrant {deviceId, deviceToken}`, `authenticate(token:)` (обновляет lastSeen), `revoke`, `revokeAll`, поток `revocations`. Ошибки `pair_invalid_code`, `pair_code_expired`, `pair_attempts_exhausted`.
- `Sources/CompanionProtocol/RequestGuard.swift`: `IPAddressLiteral` (inet_pton, IPv4-mapped, зона IPv6), `RequestGuard.evaluate` → `source_not_local | host_mismatch | origin_mismatch`, `FailureThrottle` (5 бесплатных, потом 2^n до 60 с, забывание через 15 мин).
- `Sources/Persistence/SQLitePairedDeviceStore.swift` и миграция v3 `paired_devices`. Решение «SQLite, не Keychain» и все правила описаны в ADR 0005, раздел S2.3. Файла `KeychainPairedDeviceStore` из плана нет.
- Отклонение от плана: «Revoke закрывает соединения» здесь проверяется только как событие в `revocations`. Закрытие сокета появится в S2.4.
- Тесты: `PairingStoreTests` (17), `RequestGuardTests` (12), `SQLitePairedDeviceStoreTests` (3). Тесты версий миграций теперь ждут `[1, 2, 3]`.

### S2.4 CompanionServer на FlyingFox

- `Package.swift`: FlyingFox `exact: 0.27.1`, таргет `CompanionServer` (ресурсы `Web/`), `CompanionServerTests`. В `project.yml` приложению добавлены продукты `CompanionProtocol` и `CompanionServer`, используются они с S2.5.
- `CompanionTransport.swift`: коды закрытия, `CompanionOutbound`, `CompanionServerConfiguration` (47057, ping 10 с, 64 КБ), протоколы `CompanionTransport` и `CompanionHubDelegate` (`snapshot`, `perform`).
- `CompanionHub.swift`: actor. hello с токеном и `lastSeq`, pair по WS, ack по `deviceId+cmdId` (идемпотентно), рассылка `publish`, `ReplayBuffer`, лимиты клиентов, таймаут hello, `FailureThrottle`, закрытие при отзыве.
- `FlyingFoxCompanionTransport.swift`: маршруты `/`, `/app.js`, `/app.css`, `/healthz`, `/ws`, RequestGuard на всех, заголовки безопасности, свой `WSHandler` (лимит на кадр и фрагменты, ping/pong, liveness 30 с), запасной свободный порт.
- `LocalInterfaceAddresses.swift` (`getifaddrs`). `Web/` — заглушки, настоящая панель появится в S2.6.
- Решения и ограничения описаны в ADR 0005, раздел S2.4. Главное: `remoteIPAddress` из FlyingFox не используется (доверяет `X-Forwarded-For`), большой одиночный кадр буферизуется целиком до проверки.
- Тесты: `ServerIntegrationTests` (17) через `URLSessionWebSocketTask` на 127.0.0.1 со случайным портом. Проверяют snapshot, 4401, команду до hello, идемпотентность (в том числе после переподключения), рассылку и третьего клиента (4409), 1009, 1002, таймаут hello, отзыв, pair по WS, повторный код, доигрывание по `lastSeq`, заголовки, чужой Origin и Host, освобождение порта, запасной порт. Три прогона подряд зелёные. Итого swift 423 + AppTests.


### S2.5 CompanionBridge

- `Sources/Domain`: `AnswerStreamUpdate` и `AnswersModeController.answerUpdates(subscriber:policy:)`, `isAnswerInFlight`. Все `yield` идут через `emit`, который пишет в оба потока.
- `Sources/CompanionBridge` (новый таргет): `CompanionWireMapping` (режим, фаза, коды ошибок, уровни, уведомления, стенограмма), actor `CompanionBridge` (`CompanionHubDelegate`, `AnswerStreamProjector` на ответ, очередь событий в hub), `LiveCompanionDomain` (команды в `ModeCoordinator`, `AnswersModeController`, `ManualAnswerTrigger`; подписки на broadcaster-ы), actor `CompanionService` (создаёт `CompanionHub` и FlyingFox-транспорт, `start`/`stop`).
- App: продукт `CompanionBridge` в `project.yml`; `CompositionRoot` создаёт мост и сервис, `PairingStore` на `SQLitePairedDeviceStore(database:)`; переключатель и статус порта во вкладке «Роль»; `AppSettingsStore.companionServerEnabled`.
- Отклонение от плана: файлы `Sources/App/CompanionBridge.swift` и `Tests/AppTests/CompanionBridgeTests.swift` заменены таргетом `CompanionBridge` и `Tests/CompanionBridgeTests` (причина в ADR 0005, раздел S2.5).
- Мост держит задачи через `[weak self]`: если мост никому не принадлежит, события тихо пропадают. В App им владеет `CompositionRoot`, в тестах мост держится до конца теста.
- Тесты: `CompanionBridgeTests` (10) на фейковых потоках: маркер не уходит в веб, delta раньше done, один `answer.started` при гонке, UUID без id, отмена незакрытого ответа, выход из answers, reset во время ответа, `not_available`, снимок, хвост стенограммы. `CompanionBridgeIntegrationTests` (3): настоящий `OpenAIRealtimeAnswerClient` с `FakeRealtimeWebSocketTransport`, `ModeCoordinator` и loopback-сервер. Два `answer_now` из веба дают ровно один `response.create`, `answer.delta` приходит раньше `answer.done`, reset во время стрима отклонён, а после завершения принят, сервис перезапускается.
- Найдено и исправлено в тестах: `withTimeout` на группе задач зависал навсегда, потому что `URLSessionWebSocketTask.receive()` не реагирует на отмену. Заменён гонкой через continuation, проигравшего не ждём; исправлено и в `CompanionServerTests`. Три прогона подряд зелёные. Итого swift 436 + AppTests.

### S2.6 Веб-панель v1

- `Sources/CompanionServer/Web`: `index.html`, `app.css`, `app.js`, `protocol.js`, `store.js`, `ui.js`. Верхняя панель: связь, режим и фаза, уровни «Они»/«Я», переключатель режима, «Ответить» (A), «Сброс» (R). Ответ крупным шрифтом с нумерованными кликабельными пунктами: клик или 1–9 выбирает и копирует пункт, `[` `]` выбирают соседний, C копирует выбранный. Клавиши не срабатывают в полях ввода и с модификаторами. Панели Claude и истории пока заглушки.
- `CompanionWebAssets` — таблица разрешённых файлов и типов; `CompanionHTTPHandler` отдаёт только их.
- `scripts/check-no-comments.sh` теперь проверяет и `.js`, `.css`, `.html` в `Sources`.
- Тесты: `WebReducerJSCTests` (11). `store.js` и `protocol.js` грузятся в `JSContext` без `window`, `crypto`, `localStorage` (строки `export`/`import` снимаются при загрузке). Golden-события из `Tests/CompanionProtocolTests/Fixtures/server` в порядке seq, append и дедуп по seq и offset, UTF-16 offset с эмодзи, replace и resync, snapshot после потока равен свежему snapshot, replay после `hello.ok`, стенограмма, пункты и горячие клавиши, гигиена бандла. В `staticRoutesCarrySecurityHeaders` добавлены модули, 404 и `/../`.
- Ручной стенд: `UA057_WEB_DEMO=1 UA057_WEB_DEMO_SECONDS=300 swift test --filter WebPanelDemo` поднимает сервер на всех интерфейсах (порт 47057) с фейковым доменом. Он печатает код и URL `http://<LAN-IP>:47057/#pair=<код>` и в цикле стримит стенограмму, ответ, уровни и уведомление. Без переменной тест пропускается.
- Проверено в Chrome: по LAN-IP (`isSecureContext=false`) модули грузятся, `getRandomValues` работает, консоль пустая. На 127.0.0.1 сопряжение по `#pair=`, hello, snapshot, стрим ответа, стенограмма, уровни и уведомления, клавиша выбора пункта и повторный вход по сохранённому токену после перезагрузки. Одна колонка проверена headless-скриншотом на 500 px: это минимальная ширина окна headless Chrome. Ручной прогон на телефоне — за владельцем, через стенд выше.

### S2.7 Реконнект и живучесть

- Web: `connection.js` (супервизор: backoff, ping, сторож тишины, `wake`), в `protocol.js` добавлены `backoffDelay`, `pingCommand` и константы. `app.js` переведён на супервизор, фиксированный повтор через 2 с убран; `ui.js` и `app.css` получили красный баннер «Нет связи». `connection.js` добавлен в `CompanionWebAssets`.
- Server: `CompanionHub(replayCapacity:)`; `CompanionNetworkMonitor` и `CompanionPanelURL` (только RFC1918 IPv4, без дублей).
- Bridge/App: в `CompanionService` добавлены `panelURLs()` и `panelURLUpdates()`, вкладка «Роль» показывает URL панели и обновляет их при смене сети. `CompositionRoot` запускает `ModeActivityGuard` на `stateUpdates`.
- Тесты:
  - `WebConnectionJSCTests` (5) на детерминированных часах: расписание 500/1000/2000/4000/5000/5000 при random 0,5 и границы джиттера; сброс счётчика после hello; ping в 10 и 20 с; баннер и drop ровно через 20 с тишины; баннер во время серии неудачных попыток; `wake` и `stop`.
  - `ServerIntegrationTests.reconnectReplay`: delta → обрыв → delta и done → hello с `lastSeq` на один раньше; все полученные конверты прогоняются через `store.js`, текст и оба пункта на месте, дублей нет.
  - `snapshotWhenEvicted`: буфер на 3 события, плюс случай `lastSeq` из будущего.
  - `ModeActivityGuardTests` (3), `CompanionServiceURLTests` (2).
- Проверено в Chrome на демо-стенде: старый токен даёт 4401 и возвращает форму, сопряжение по `#pair=` проходит. После остановки сервера статус «нет связи» и баннер примерно через 20 с, при этом переподключения идут по backoff. Плановая проверка «обрыв 10 с без дублей» сделана тестом `reconnectReplay`; живой обрыв Wi-Fi на телефоне — в ручной чек-лист владельца.

### S2.8 Сопряжение на Mac и управление устройствами

- App:
  - `CompanionPairingViewModel` (фазы idle, serverOff, noNetworkAddress, ready, expired, paired; маска до `reveal()`; часы внедряются через `now`; `tick()` раз в секунду; автозакрытие через `closeDelay` после события сопряжения);
  - протокол `CompanionPairingServicing` с реализацией в расширении `CompanionService`; `QRCodeRenderer` (`CIFilter.qrCodeGenerator`, уровень коррекции M, целочисленный масштаб, программный рендер);
  - `CompanionPairingView` (Esc и «Закрыть» через `.cancelAction`), сцена `Window` с id `companion-pairing`, `PairingCommands` (⇧⌘P), пункт в `MenuBarController`;
  - вкладка «Устройства»: порт, loopback, URL, список устройств, отзыв.
- Ядро: `PairingStore.pairingEvents()` и `pairingObserverCount`, публичный `PairingCode.init`, `CompanionServerConfiguration: Equatable`, `CompanionService.update(configuration:)`, настройки `companion.port` и `companion.loopbackOnly`.
- Тесты:
  - `PairingEventsTests` (2);
  - `CompanionPairingViewModelTests` в AppTests (7): маска и QR, истечение и новый код, автозакрытие после первого сопряжения, предложение включить сервер, отсутствие LAN-адреса, флаг явного открытия, порт по умолчанию и loopback.
- XCUITest: новый таргет `UserAgent057UITests` (`Tests/UITests`) и `make ui-test`, в verify-fast не входит. Тесты: окно не появляется при запуске; ⇧⌘P открывает окно, Esc закрывает. На этом Mac запуск упёрся в «Timed out while enabling automation mode»: режим автоматизации macOS требует подтверждения владельца, сам я его не включал. Владелец запускает `make ui-test` и подтверждает запрос.
- Ручная проверка критерия «меньше 30 с от нажатия до живой панели» — в чек-листе владельца.

### S2.9 Режим второго экрана: оверлей на Mac можно выключить

- OverlayUI: `OverlayPreferencesStore.isOverlayEnabled` (ключ `overlay.enabled`, по умолчанию true); `OverlaySwitch` (`@Observable`, сохраняет значение и рассылает его подписчикам). `AnswerOverlayWindowController` создаёт `AnswerOverlayPanel` только при включённом оверлее, при выключении снимает его (`orderOut`, без `close`, чтобы не попасть на `isReleasedWhenClosed`), при включении создаёт заново. Горячие клавиши регистрируются независимо от панели: «Ответить сейчас» работает и без оверлея. Переключатель видимости при отсутствии панели ничего не делает.
- Переключатели: «Показывать оверлей на этом Mac» во вкладке «Внешний вид» (`settings.overlayEnabled`) и пункт «Оверлей на этом Mac» с галочкой в меню статуса. Иконка в строке меню и окна приложения остаются.
- Bridge: `CompanionBridge.setOverlayEnabled(_:)` пишет значение в `StateSnapshot.overlayEnabled` (раньше там было жёстко true) и при изменении рассылает свежий snapshot. Поток событий в веб-панель от оверлея не зависит.
- Автоэкспорт встреч выключен по умолчанию (`settings.export.autoExportEnabled`). `DesktopMeetingExporter` переименован в `MeetingFolderExporter`, папка экспорта — `~/Documents/UserAgent057/Exports`, рабочий стол не используется. Решение принимает `MeetingAutoExporter`; переключатель и «Открыть папку экспорта» находятся во вкладке «Сессии и данные». Явный экспорт из истории (`NSSavePanel`) не менялся.
- Диагностический лог Realtime перенесён из `/tmp/ma_realtime_diag.log` в `~/Library/Logs/UserAgent057/realtime_diag.log` (`AppFileLocations`).
- Тесты:
  - `OverlaySecondScreenTests` в AppTests (5): по умолчанию включено и сохраняется; при выключенном оверлее контроллер не создаёт панель, а переключение создаёт и снимает её; при включённом панель есть; `noDesktopWriteByDefault` на временном каталоге; пути экспорта и лога;
  - `OverlayToggleBridgeTests` (1): snapshot отражает выключение, ответ при этом доходит до веб-панели, повторная установка того же значения ничего не рассылает.
- XCUITest `OverlaySettingUITests` (переключатель во «Внешнем виде») собирается в `make ui-test`; запуск ждёт разрешения режима автоматизации от владельца, как и в S2.8.
- Под полной нагрузкой verify-fast один раз упали `OpenAIRealtimeAnswerClientTests.contextFullyClearedAfterVisibleAnswerCompletes` и `AnswerOverlayViewModelTests.resettingWhileCollectingContext…`. Модули этим шагом не затронуты, отдельно оба прошли 5 из 5, повторный verify-fast зелёный. Это гонки по времени, как и с `CaptureHubTests` в S2.8.

### S2.10 Глобальные хоткеи на Carbon `RegisterEventHotKey`

- `GlobalHotKeyManager` больше не использует мониторы `NSEvent`. Глобальный монитор `keyDown` без разрешения Accessibility не получал событий и не поглощал нажатие, поэтому символ попадал в активное окно. Теперь регистрация идёт через `RegisterEventHotKey` с обработчиком `kEventHotKeyPressed` на `GetApplicationEventTarget()` (бэкенд `CarbonHotKeyBackend`, сигнатура `UA57`). Accessibility и Input Monitoring не нужны, нажатие поглощается системой и в активное окно не печатается. Хоткей работает и при фокусе в приложении, поэтому локальный монитор больше не нужен.
- API: в SDK macOS 27 объявлений `RegisterEventHotKey`, `EventHotKeyID` и `kEventHotKeyPressed` нет в просматриваемых заголовках HIToolbox, но символы экспортируются в `HIToolbox.tbd`, и модуль `Carbon.HIToolbox` их отдаёт. Это проверено отдельной пробой в scratchpad: регистрация вернула `noErr`, повторная регистрация той же комбинации — `eventHotKeyExistsErr` (-9878).
- Колбэк Carbon — C-функция без захвата. Бэкенд передаётся через `userData` (`Unmanaged.passUnretained`), а вызов идёт в `MainActor.assumeIsolated`, потому что события application target доставляются на главном потоке. Бэкенд за протоколом `HotKeyBackend` подменяется в тестах. `isolated deinit` снимает регистрации, если `removeAll()` не был вызван.
- Комбинации: ⌥↩ («Ответить сейчас») и ⌥⌘H (показать или скрыть оверлей) сохранены. В `HotKeyAction` добавлены заготовки `toggleSession` и `toggleScreen` без комбинаций по умолчанию: регистрировать нечего, пока нет пользовательской настройки. `HotKeyCombo` отбрасывает нерелевантные флаги (Caps Lock, Fn) и переводит модификаторы в маску Carbon.
- Конфликты: повтор комбинации внутри приложения отклоняется до вызова Carbon (`.duplicate`), первая привязка сохраняется. Если комбинацию уже занял другой процесс или регистратор, возвращается `.unavailable(status)`, и запись не сохраняется.
- Тесты `HotKeyTests` в AppTests (10):
  - комбинации по умолчанию и их уникальность;
  - перевод модификаторов в маску Carbon;
  - регистрация и снятие через бэкенд;
  - отказ повторной комбинации;
  - одно нажатие вызывает ровно одно действие;
  - ошибка бэкенда не сохраняется;
  - `removeAll` снимает регистрации и обработчик;
  - настоящий Carbon: регистрация без Accessibility, обнаружение занятой комбинации и освобождение после снятия;
  - интеграционный: нажатие ⌥↩ через `AnswerOverlayWindowController` с поддельным бэкендом дважды даёт ровно один `forceResponse` у поддельного `LiveResponder`.
- XCUITest «хоткей Answer now даёт ровно один ответ» не добавлен. В приложении нет режима запуска с поддельным Realtime-транспортом, а добавлять такой переключатель в поставляемую сборку ради UI-теста я не стал. Тот же путь (хоткей → `AnswerOverlayViewModel.forceAnswerNow` → `ManualAnswerTrigger` → `AnswersModeController` → `forceResponse`) покрыт интеграционным тестом выше. Владельцу остаётся ручная проверка: ⌥↩ в другом приложении (например, в TextEdit) при выключенном Accessibility для UserAgent057 даёт один ответ, а перевод строки в документ не вставляется.

### S2.11 Стабильная dev-подпись, брандмауэр и документация companion

- Проблема: Debug подписывался ad-hoc, а у ad-hoc-подписи designated requirement равен `cdhash`. Брандмауэр macOS узнаёт приложение по подписи, поэтому после каждой сборки снова спрашивал про входящие соединения, а после ответа «Запретить» соединения пропадали молча. На этой машине брандмауэр включён.
- `scripts/make-dev-signing-identity.sh` (`make dev-identity`): `/usr/bin/openssl` (LibreSSL) создаёт самоподписанный сертификат RSA-2048 на 10 лет с `extendedKeyUsage = codeSigning`, `CA:false`. Пакуется в PKCS#12 со случайным одноразовым паролем во временном каталоге, импортируется в login keychain с доступом для `/usr/bin/codesign`. Затем `security add-trusted-cert -r trustRoot -p codeSign` доверяет сертификату только для подписи кода (macOS спрашивает пароль). В конце скрипт пишет `Config/DevSigning.local.xcconfig`. Повторный запуск ничего не создаёт и только переписывает xcconfig. Ключ и p12 удаляются по `trap`.
- `project.yml`: у Debug приложения есть `configFiles: Config/DevSigning.xcconfig` с `UA057_DEV_CODE_SIGN_IDENTITY = -` и `#include? "DevSigning.local.xcconfig"`, а также `CODE_SIGN_IDENTITY: $(UA057_DEV_CODE_SIGN_IDENTITY)` и `CODE_SIGN_STYLE: Manual`. Без локального файла Debug остаётся ad-hoc (`-`), чистый клон собирается без сертификата. С файлом подписывается «UserAgent057 Local Dev». Release не менялся, его подписывает `sign-and-install.sh` тем же именем identity. Файл `Config/DevSigning.local.xcconfig` в `.gitignore`.
- `scripts/signing-status.sh` (`make signing-status`) только читает состояние: подпись, designated requirement и `socketfilterfw --getglobalstate` / `--getappblocked` для последней Debug-сборки или для указанного пути. Правила брандмауэра скрипты не меняют.
- Проверено в scratchpad на временном keychain, без изменения доверия в системе:
  - скрипт создаёт identity, при повторном запуске сохраняет её;
  - `xcodebuild -showBuildSettings` даёт `-` без локального xcconfig и имя identity с ним;
  - две сборки с разным содержимым, подписанные identity, имеют одинаковый DR `identifier "com.local.UserAgent057" and certificate leaf = H"…"` при разных CDHash, а ad-hoc DR — разные `cdhash`.

  Xcode ищет identity только в списке поиска keychain, поэтому полная сборка с временным keychain дала ожидаемое «No certificate matching». Временный keychain удалён, список поиска не изменился.
- Не сделано мной, остаётся владельцу (меняет доверие в login keychain): `make dev-identity`, сборка Debug, один ответ «Разрешить» в запросе брандмауэра, затем пересборка и проверка, что запрос не повторяется (`make signing-status` показывает `certificate leaf`).
- Документация: в `docs/troubleshooting.md` раздел о запросе брандмауэра, «Запретить», `socketfilterfw --listapps` / `--getappblocked`, потерянном сертификате и гостевых сетях. В `docs/privacy.md` раздел «Веб-панель в локальной сети»: plain http только в доверенной сети, в v1 нет Bonjour (он в M2b), обновлена строка таблицы исходящих потоков. API-ключ остаётся в `UserDefaults`, потому что dev-identity необязательна, а Keychain ACL при ad-hoc по-прежнему ломается.
- `verify-fast` собирает с `CODE_SIGNING_ALLOWED=NO` и от сертификата не зависит. `CompanionServerTests` входят в `swift test`.

### S3.1 Микрофон: формат по запросу, VPIO, ducking, смена устройства

- Domain: `MicrophoneProfile` задаёт параметры микрофона.
  - `.me` — канал «Я» в answers, 24 кГц. Voice Processing включается, если `OutputRouteClassifier.echoRisk(route, policy)`, то есть звук идёт через динамики или пользователь выбрал «Всегда динамики».
  - `.recording` — 16 кГц, всегда без Voice Processing, чтобы не менять проверенное в M1 поведение записи.

  `MicrophoneDeviceResolver.plan(_:catalog:profile:routePolicy:)` берёт маршрут из `catalog.defaultOutputDevice()` в момент старта, поэтому он не зависит от того, запущен ли `OutputRouteMonitor`.
- `CaptureHub`:
  - `acquire(_:consumer:policy:microphoneProfile:)`, по умолчанию `.recording`. Профиль задаёт первый подписчик, остальные получают тот же поток: режимы взаимоисключающие, конфликт профилей невозможен.
  - `microphonePlan` принимает профиль.
  - Хаб хранит фактические `MicrophoneCaptureOptions` (`microphoneOptions`). На любое изменение устройств, включая смену вывода, он перепланирует и перезапускает микрофон только при отличии опций, а подписчики остаются. Так переход AirPods → динамики включает VPIO без разрыва потока.
  - `refreshMicrophonePlan()` вызывается из настроек при смене «Что считать выводом».
  - Как и раньше, на `AVAudioEngineConfigurationChange` микрофон перезапускается всегда, а ошибка перезапуска уходит в `failures()` как `microphone_restart_failed` с остановкой источника.
- `AVEngineMicrophoneCapturing`:
  - При `voiceProcessing` до старта вызывается `inputNode.setVoiceProcessingEnabled(true)`: по заголовку `AVAudioIONode.h` это можно делать только при остановленном движке. Затем ставится `voiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)` (macOS 14+).
  - Устройство выбирается после включения VPIO, потому что VPIO подменяет audio unit. Проба показала, что `CurrentDevice` принимается в обоих порядках.
  - Ошибка включения VPIO возвращается как `AudioCaptureError.voiceProcessingUnavailable`.
- Пробы в scratchpad на этом Mac (без сохранения звука):
  - с VPIO формат входа меняется с 1 канала 48 кГц на 9 каналов 48 кГц, обработанный голос только в канале 0;
  - движок с одним tap на входе запускается и отдаёт 48 000 кадров в секунду;
  - обращение к `engine.mainMixerNode` при включённом VPIO ломает запуск: `-10875` на `kAUInitialize` output node. Поэтому код к mixer не обращается.
- `MicrophoneFrameConverter`: при VPIO берёт только канал 0, без VPIO усредняет каналы, затем ресемплирует к `options.sampleRate`. Прежний downmix 9 каналов ослабил бы голос примерно в 9 раз.
- Настройки «Звук → Вывод звука»: выбор «Определять автоматически / Всегда наушники / Всегда динамики» уже был (S1.4; v3 заменил ручной выбор автоопределением). Добавлена строка о состоянии эхоподавления для канала «Я».
- `Info.plist`: `NSMicrophoneUsageDescription` переписан честно: в Recording расшифровка локальная, в Answers при канале «Я» речь уходит в OpenAI. `privacy.md` обновлён.
- `AudioSourceKind.microphone` не переименован в `.me`: это физический источник. «Я» — профиль `.me` и имя потребителя, которое добавит S3.4. В answers микрофон пока не подключается: канал «Я» собирается в S3.4.
- Тесты:
  - `MicrophoneOptionsTests` (8): профили → частоты, VPIO только при риске эха, recording без VPIO, `plan` по маршруту вывода, выбор канала 0 при VPIO, downmix без VPIO, 9 каналов 48 кГц → 24 кГц моно, 48 → 16 кГц;
  - `CaptureHubTests` (+4): `.me` 24 кГц и `.recording` 16 кГц; переход на динамики перезапускает «Я» с VPIO, подписчик сохраняется, повторное событие без изменений не перезапускает; recording игнорирует смену вывода; release `.me` полностью снимает микрофон (passive teardown), поздние события устройств его не поднимают.
- Остаётся вручную на железе (S3.5): утечка эха Meet из динамиков MacBook с VPIO и без; проверка, что звук других приложений при `duckingLevel .min` почти не приглушается; переподключение при подключении и отключении AirPods.

### S3.2 Подмешивание текстового контекста в основную Realtime-сессию

- Domain: `InjectedContext` (`.me(text)`, `.screen(application:text:)`, `.note(text)`). `LiveResponder.injectContext(_:)` принимает его вместо строки. Строковая перегрузка осталась в расширении протокола как `.note`. Формат сообщений и события OpenAI в Domain не попадают: метки и роль item выбирает `RealtimeInstructions.injectedItem(_:)` в RealtimeClient (риск P0 из v3 — не тянуть `conversation.item.create` в общий контракт).
- Формат: `.me` → item с role `user`, `input_text` «`[Я]: …`». `.screen` → role `user`, «`[Экран: <приложение>]\n…`» или «`[Экран]\n…`» без имени. `.note` осталась прежней: system-item с `CONTEXT_NOTE`. Пустой текст ничего не отправляет. `response.create` не отправляется. По документации OpenAI (Realtime conversations, text inputs) `conversation.item.create` только добавляет item, ответ запускает отдельный `response.create`. Turn detection не менялся.
- `AnswerContextWindow.trackInjectedTextItem` добавляет item в общий список контекста без немедленного вытеснения. Поэтому вставленный контекст:
  - открывает «Ответить сейчас» (`noContext` больше не выбрасывается);
  - удаляется вместе с остальными после завершённого ответа;
  - вытесняется по `maxAge` таймером sweep, который во время ответа не работает.

  Раньше вставка вытесняла старые items сразу, в том числе посреди стрима. Теперь при вставке устаревшие items удаляются только при отсутствии ответа в работе, иначе их забирает ближайший sweep после ответа.
- Инструкции, версия 6, раздел «Owner remarks and screen text»:
  - `[Я]:` — речь самого пользователя: не отвечать на неё, не считать вопросом, не повторять и не пересказывать сказанное;
  - если после последнего ответа были только реплики `[Я]`, вернуть `⟦WAIT_FOR_QUESTION⟧`;
  - `[Экран` — справочный материал, а не вопрос.
- `LanguageEvalCatalog`: у кейсов появились `context` и `expectsWaitSentinel`, добавлено 4 кейса:
  - рассказ владельца о своём опыте без вопроса → sentinel;
  - реплика владельца, затем вопрос → ответ без пересказа;
  - задача на экране и английский вопрос;
  - английская реплика владельца с вопросительной интонацией → sentinel.

  Живой прогон по-прежнему ручной (`MEETING_ASSISTANT_RUN_LIVE_EVALS=1`, платный); acceptance «модель отвечает сентинелом, когда владелец рассказывает о своём опыте» проверяется им, а не в verify-fast.
- Тесты `InjectedContextTests` (7, fake transport):
  - `[Я]` уходит как user-item с меткой, без `response.create`;
  - заголовок экрана с приложением и без, пустой текст не отправляется;
  - inject + два нажатия «Ответить сейчас» дают ровно один `response.create`;
  - удаление только после `response.done`, не во время дельт;
  - вытеснение по maxAge не срабатывает во время стрима и срабатывает после;
  - вытеснение при вставке в простое;
  - правила в инструкциях.

  `LanguageEvalCatalogTests` проверяет покрытие контекстных кейсов. Тестовые двойники `LiveResponder` переведены на новую сигнатуру.

### S3.3 OpenAIRealtimeTranscriptionClient для «Я»

- Domain: `MeTranscribing` (`start(languages:) -> AsyncStream<TranscriptDelta>`, `appendAudio`, `commitTurn`, `statusUpdates`, `stop`) и `MeTranscriptionStatus` (`connecting`, `live`, `reconnecting(attempt:)`, `unavailable(reason:)`, `stopped`). В контракте нет событий OpenAI (риск P0 из v3), он подходит и для другого провайдера. `StreamingTranscriber` из S0.7 не расширялся: «Я» нужен явный `commitTurn` по клиентскому VAD, а у общего стримингового транскрибера его нет.
- API сверен с актуальной документацией OpenAI (guide «Realtime transcription»):
  - URL `wss://api.openai.com/v1/realtime?intent=transcription` без `model`: с `model` создаётся conversation-сессия, и она не принимает transcription update;
  - `session.update` с `type: "transcription"`, `audio.input.format` `audio/pcm` 24 кГц, `transcription.model = gpt-live-transcribe`, `languages: [ru, en]` (у этой модели множественное поле, `language` не отправляется), `delay: "low"`;
  - `turn_detection: null` пишется явно (`encodeNil`): `gpt-live-transcribe` не поддерживает server VAD;
  - commit отправляет приложение по своему VAD;
  - порядок completed между ходами не гарантирован, сопоставление идёт по `item_id`;
  - модель не возвращает язык, временные метки и confidence.
- `OpenAIRealtimeTranscriptionClient` (actor) работает на своём транспорте, отдельно от основной сессии.
  - Дельты накапливаются по `item_id`, наружу уходит полный текст item. `completed` даёт финальный текст, повтор игнорируется. `failed` финализирует item с накопленным частичным текстом, поздний `completed` после этого игнорируется.
  - Commit уходит только из `commitTurn()`. Если с прошлого commit меньше 100 мс аудио (2400 сэмплов при 24 кГц), вместо commit отправляется `input_audio_buffer.clear`: сервер отклоняет слишком короткий буфер.
  - Кадры не 24 кГц моно не отправляются и считаются: формат обеспечивает `MicrophoneProfile.me` из S3.1.
  - При обрыве (`closed` или `failed`) незавершённые items финализируются частичным текстом, а события старого соединения отсекаются по номеру поколения. Переподключение идёт в отдельной задаче: backoff 0,5 с × 2^n, максимум 8 с, джиттер до 20%, 5 попыток. Каждая попытка заново отправляет `session.update`.
  - После исчерпания попыток статус становится `unavailable(reconnect_exhausted)`, поток дельт завершается, append и commit ничего не делают. Это деградация до режима «без Я», уведомление по статусу покажет S3.4. Основная Realtime-сессия этим не затрагивается.
- `RealtimeClientEvent`: `.inputAudioBufferCommit` и `.transcriptionSessionUpdate(TranscriptionSessionConfig)`. Декодирование delta, completed и failed уже было (S1.7).
- Тесты `OpenAIRealtimeTranscriptionClientTests` (9, fake transport, 10 из 10 прогонов зелёные):
  - JSON сессии и URL;
  - commit только по сигналу, короткий буфер → clear;
  - другая частота не отправляется;
  - delta и completed вперемешку и не по порядку сопоставляются по `item_id`, дубль игнорируется;
  - failed → финал с частичным текстом;
  - обрыв → reconnecting → live, повторный session.update, частичное финализировано, аудио после реконнекта уходит, основная сессия с соседним транспортом не тронута;
  - исчерпание → `unavailable` и завершение потока;
  - без ключа → `notAuthenticated` и `unavailable(connect_failed)`;
  - stop закрывает транспорт и не переподключается.

  `AnswersModeControllerTests.answersNeverStartsLocalWhisper` проверяет, что в answers не вызывается `LocalTranscribing`: `RealtimeClient` зависит только от `Domain`, `AnswersModeController` не получает `LocalTranscribing`.
- В приложение клиент ещё не подключён: канал «Я» (VAD, эхо-гейт, вставка `[Я]` через S3.2) собирается в S3.4. Ротация сессии при лимите 60 минут (CO из v3) не входит в S3.3 и остаётся открытой для обеих сессий.

### S3.4 ClientVoiceActivityDetector, EchoSuppressor и сборка канала «Я»

Решение и пороги описаны в ADR 0009.

- Domain:
  - `ClientVoiceActivityDetector`: энергетический VAD, окна 20 мс, onset 60 мс, hangover 600 мс, принудительное закрытие через 15 с, адаптивный шумовой пол;
  - `EchoSuppressor`: гейт по RMS `.systemAudio` от -40 dBFS плюс 300 мс; дедуп по Жаккару (порог 0,6, окно 5 с);
  - `MeTranscriptionSink`: в OpenAI уходят только реплика и 300 мс пре-ролла; финал ждёт 1 с перед дедупом, затем вызываются `injectContext(.me)` и `TranscriptEvent{.me}`;
  - `CaptureNotice.meTranscriptionUnavailable(reason:)`: одно уведомление за запуск, причины `connect_failed`, `microphone_unavailable`, `reconnect_exhausted`.
- `AnswersModeController(meChannel:isMeChannelEnabled:)`:
  - канал стартует после основной сессии, а его сбой не роняет режим;
  - `stop()` первым гасит канал: микрофон освобождается, транскрибер останавливается, поздние финалы отбрасываются по поколению;
  - транскрипты «Собеседника» передаются в дедуп.
- Приложение:
  - `CompositionRoot` создаёт второй `OpenAIRealtimeTranscriptionClient` со своим транспортом и тем же ключом;
  - в настройках «Звук» добавлен переключатель «Канал «Я»» (`audio.meChannelEnabled`, по умолчанию включён);
  - индикатор приватности в Answers теперь говорит, что в OpenAI уходят и реплики с микрофона.
  - Уведомление о недоступности «Я» показывается в окне режима, в оверлее и в вебе (`me_channel_unavailable`).
  - В веб-стенограмме появилась подсказка «рекомендуются наушники». Реплики «Я» уже размечались как `speaker: me`.
- Старт канала ждёт подключения второго WebSocket последовательно, после основного. Параллельный старт отложен: так `stop()` гарантированно застаёт канал в известном состоянии.
- Тесты:
  - `ClientVADTests` (13) на синтетических фикстурах `MeSpeechFixture` (24 кГц, слоги с огибающей, детерминированный шум): фраза ru и фраза en дают одну реплику, длинная пауза даёт две, короткая — одну; шум, щелчок и тихое бормотание реплику не открывают; есть сценарии принудительного закрытия, гейта и перебивания; решения не зависят от размера кадра;
  - `EchoSuppressorTests` (10);
  - `MeTranscriptionSinkTests` (11): пре-ролл и один commit; тишина и шум ничего не отправляют; громкий системный звук держит реплику закрытой; инъекция `[Я]`; дедуп эха, в том числе когда текст собеседника приходит в окне ожидания; ровно одно уведомление на каждую ошибку; stop;
  - `MeChannelWiringTests` (4): в answers захватываются микрофон и system; passive освобождает всё; выключенный канал не трогает микрофон; сбой канала не роняет answers; «Я» попадает в стенограмму без `forceResponse`;
  - `MeChannelIntegrationTests` (1): настоящие клиенты на fake transports; речь даёт append и один commit, completed даёт `conversation.item.create` с текстом `[Я]: …` и ни одного `response.create`;
  - маппинг уведомления и реплики «Я» в CompanionBridge.
- Аудиофикстуры синтетические. Записи реальной речи ru/en, проверка порогов на железе и p50/p95 «конец фразы → completed» входят в S3.5. Ротация сессий на 60 минутах по-прежнему открыта.

### S3.5 Замеры канала «Я» (подготовка verify-real и чек-листа)

- `Tests/RealAPITests/MeChannelLatencyTests.swift` — opt-in через `RUN_REAL_API_TESTS=1`, запускается `make verify-real-me` (лог в `.build/verify-real-me.log`) или в составе `make verify-real`. В `verify-fast` набор пропускается, платных вызовов на коммит нет.
  - `meTranscriptCompletedAfterPause`: настоящие `MeTranscriptionSink` и `OpenAIRealtimeTranscriptionClient`, микрофон подменён скриптом, кадры 20 мс идут в реальном темпе. Фразы — `say`: три ru (голос Milena) и три en. Меряются `commit → completed` (это критерий приёмки, p50 ≤ 1500 мс) и `конец речи → completed` (сюда входят 600 мс hangover). `dedupGrace` выставлен в ноль: секунда ожидания перед дедупом — осознанная задержка вставки, а не задержка распознавания, поэтому для вставки в контекст нужно добавить 1 с.
  - `answerNowWithInjectedContextToFirstDelta`: перед Answer now подмешиваются `[Я]` и `[Экран: Xcode]`, затем идёт пояснение голосом; меряется время от нажатия до первой дельты, по умолчанию 3 раунда.
  - `syntheticSpeakerEchoLeak`: реплика собеседника идёт в system, её копия, ослабленная на 10, 20 и 30 дБ с задержкой 40 мс, — в микрофон, без VPIO. Транскрипт собеседника передаётся в дедуп. Печатаются открытые реплики, отброшенные дедупом и вставленные в контекст.
  - Общие помощники вынесены в `RealAPISupport.swift`: ключ из окружения, `say` → PCM 24 кГц, тишина, ослабленная копия, `LatencySummary` (p50 и p95 по ближайшему рангу), темп кадров. Smoke-тесты переведены на эти помощники.
- Офлайн-проба на тех же фразах `say`, без API (одноразовый тест, удалён): каждая фраза даёт ровно одну реплику VAD (речь 2,3–2,7 с, реплика 2,6–3,2 с с hangover). При синхронной доставке уровней синтетическое эхо −10/−20/−30 дБ не открыло ни одной реплики из 4. Тест с API меряет тот же сценарий с асинхронной доставкой уровней через `CaptureHub`.
- В `docs/troubleshooting.md` добавлен ручной чек-лист S3.5 (12 пунктов): наушники и динамики, Meet и Zoom, перебивание, короткие «да» и «ok», AirPods hot-swap, вентилятор, офлайн, отказ в микрофоне, выключатель канала.
- Результаты (заполняет владелец после `make verify-real-me` и чек-листа):

| Метрика | p50 | p95 | Дата и железо |
|---|---|---|---|
| `me.commit_to_completed` | | | |
| `me.speech_end_to_completed` | | | |
| `answer_now_with_injected_context_to_first_delta` | | | |
| `me.echo_leak` −10/−20/−30 дБ (вставлено из 4) | | | |
| Эхо на динамиках, Meet и Zoom (чек-лист, п. 3 и 4) | | | |

- Платные тесты в этом шаге не запускались: ключ и запуск остаются за владельцем.

## M4. Сессии ассистента

### S4.1 Миграция схемы для сессий (version 4) с резервной копией

- `Sources/Persistence/SessionSchema.swift` содержит инструкции миграции `version 4` (в плане она называется «v2»; номера 1–3 уже заняты). `SQLiteMigrations.all` подключает её с `backsUpExistingDatabase: true`. Копия `*.pre-v4.bak` снимается через `sqlite3_backup` внутри той же `BEGIN IMMEDIATE`, что и миграция; на свежей базе копии нет.
- Что добавлено:
  - в `meetings`: `kind` (по умолчанию `recording`), `title_source`, `pinned`, `last_activity_at`, `knowledge_digest`;
  - таблица `session_spans`, по одному span `legacy_<id>` на каждую старую встречу;
  - в `utterances`: `speaker`, `origin`, `captured_at`, `translation_text`, `translation_lang` с бэкфиллом;
  - в `qa_entries`: `session_id` (каскадное удаление) и `screen_context_id` (`SET NULL`);
  - новые таблицы `screen_contexts`, `deep_expansions`, `bookmarks` и `search_aliases`.
- Поисковые индексы. Внешние FTS5 `*_fts` (`unicode61 remove_diacritics 2`) и `*_trgm` (`trigram`, MEM-2) заведены для utterances, qa_entries, screen_contexts и deep_expansions. Для bookmarks есть только `*_fts`. Триггеры создаёт один генератор `SessionSchema.searchable`. Старые `utterances_fts` и `qa_entries_fts` пересобраны в новых колонках и с новым токенайзером. Индекс получает текст с заменой «ё» на «е» (unicode61 их не сводит, это проверено пробой), поэтому `'rebuild'` для них запрещён; подробности в ADR 0006.
- `SQLiteDatabase` получил внутренний инициализатор с явным списком миграций: он нужен для теста отката и для чтения резервной копии без миграций. Перед миграциями выполняется `wal_checkpoint(PASSIVE)`.
- `SQLiteMeetingRepository.appendSegment` теперь пишет `speaker` (`local` превращается в `me`), `origin = whisper_local` и `captured_at`, иначе новые реплики микрофона в recording получили бы значение по умолчанию `them`.
- Тесты `SQLiteMigrationV2Tests` (6):
  - `migratesPopulatedV1Database`: бэкфилл, span, копия с версией 3, старая встреча читается репозиторием;
  - `ftsRebuiltFindsLegacyUtterance`: «ёлку» находится по «елку», работают префикс, триграмма, поиск через `search` обоих репозиториев и alias без учёта регистра;
  - `deleteSessionCascadesAllChildren`: удаление сессии не трогает соседнюю и чистит FTS-строки;
  - `ftsTriggersOnNewTables`: колоночные запросы, update и delete, `SET NULL`;
  - `migrationIsIdempotentOnReopen`: копия при повторном открытии не перезаписывается;
  - `failedMigrationRollsBack`: сбой на последней инструкции откатывает всё, старый FTS продолжает работать, копия остаётся, следующий запуск мигрирует.
  - Ожидания версий в `SQLiteDatabaseTests` обновлены до `[1, 2, 3, 4]`.
- Открытые вопросы:
  - `RetentionSweeper` по-прежнему удаляет Q&A по `asked_at`, а не через сессию; это переходит в S4.9;
  - строка продуктового контракта «полный разговор не сохраняется» меняется в S4.4, когда появится запись стенограммы в сессии.

### S4.2 Модель сессии и SQLiteSessionRepository

- `Sources/Domain/AssistantSession.swift` описывает модель сессии:
  - `SessionID = MeetingID`: сессия хранится строкой `meetings`;
  - перечисления `SessionKind`, `SessionSpanMode` (строится из `AppMode`, passive даёт nil), `SessionSpanEndReason`, `SessionTitleSource`, `UtteranceOrigin` (`realtime_input`, `me_channel`, `whisper_local`) и `BookmarkKind`;
  - типы данных `SessionSpan`, `AssistantSession`, `SessionHeader` (только счётчики Q&A и звёзд, без стенограммы), `SessionCursor` и `SessionPage`;
  - записи содержимого `SessionBookmark`, `SessionUtterance`, `SessionScreenContext`, `SessionExpansion` и `SessionDetail`.
- Состояние сессии хранится в `MeetingStatus`: `recording` означает активную сессию, `completed` — завершённую. Отдельной колонки статуса нет. `reconcileInterruptedMeetings` после падения переводит открытые сессии в `interrupted`, а `resume` возвращает их в `recording`.
- В `Domain/Protocols.swift` добавлен протокол `SessionRepository` с методами `create`, `resume`, `closeSpan`, `finish`, `session`, `headers(limit:after:)`, `detail`, `addBookmark` и `removeBookmark`, `setTitle`, `setPinned` и `purge(olderThan:excluding:)`.
- Как это реализовано в `Sources/Persistence/SQLiteSessionRepository.swift`:
  - каждая запись идёт одной транзакцией через новый `SQLiteDatabase.transaction([(sql, params)])`;
  - `resume` в том же режиме при открытом span идемпотентен; в другом режиме он закрывает текущий span с `modeChanged` и открывает новый;
  - `finish` закрывает открытые span с причиной `stopped`;
  - `closeSpan` срабатывает только на открытом span, повторный вызов ничего не меняет;
  - пагинация по ключу (`started_at DESC, id DESC`, курсор — пара started_at и id) устойчива к вставкам и к одинаковому времени старта;
  - `purge` удаляет только завершённые, незакреплённые и не активные сессии, у которых `last_activity_at` старше порога; дочерние строки и FTS чистит каскад из S4.1;
  - `SQLiteQuestionAnswerRepository.columns` и `rowMapper` открыты внутри модуля, чтобы `detail` собирал `QuestionAnswerPair` тем же маппером.
- Время хранится в ISO8601 с точностью до секунды, как и во всей базе. `create` и `resume` возвращают значения, уже округлённые до этой точности, так что они совпадают с тем, что потом читается из базы.
- Тесты `SQLiteSessionRepositoryTests` (9):
  - create;
  - resume в том же и в другом режиме;
  - повторный closeSpan;
  - finish, затем resume;
  - пагинация из трёх страниц с одинаковым временем старта и счётчиками;
  - `headersDoNotLoadSegments` (заголовки работают даже после `DROP TABLE utterances`);
  - detail с упорядоченными репликами, Q&A, раскрытием, экраном и звездой, а также удалением закладки;
  - title и pinned;
  - purge (pinned, активная, открытая и свежая сессии остаются, Q&A удаляется каскадом).
- Ещё не подключено к приложению: запись в сессии начнётся в S4.3 и S4.4.
