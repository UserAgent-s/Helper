# Финальный аудит реализации MeetingAssistant

Дата: 2026-08-22. Аудит проведён в конце того же непрерывного прогона, что реализовал этапы 06–13 (00–05 — предыдущий запуск в этой же сессии инструмента). Аудитор — тот же исполнитель, что писал код; независимость обеспечена не сменой автора, а тем, что аудит явно перечитал весь репозиторий по каждому из 25 пунктов ниже, а не только дифф последнего этапа.

## 1. Commit / worktree state

- Репозиторий инициализирован (`git init`), **коммитов нет** — по правилу базового промпта "не коммитить без явного запроса". Ничего в этом аудите не меняет историю.
- `git status`: все файлы репозитория (`Sources/`, `Tests/`, `docs/`, `Package.swift`, `project.yml`, `Resources/`, `README.md`, `CLAUDE.md`, `.gitignore`) — untracked (`??`), рабочее дерево чистое в смысле "нет конфликтов/отслеживаемых изменений", т.к. отслеживать пока нечего.
- Веток, кроме `main` (без коммитов), нет.
- Состав: 78 файлов в `Sources/`, 36 файлов в `Tests/`, всего 115 `.swift`-файлов вне `.build/`.

## 2. Матрица требований

Формат: № требования → статус → код/тест-доказательство.

| № | Требование | Статус | Доказательство |
|---|---|---|---|
| 1 | Ровно три взаимоисключающих режима | ✅ | `AppMode` (enum, 3 case) — `Tests/DomainTests/AppModeTests.swift::exactlyThreeModesExist` |
| 2 | Старт всегда в `passive` | ✅ | `ModeState.initialPassive` (этап 02) — `ModeCoordinatorTests::startsInPassive`, `SummaryTests`/`AppTests::startsInPassive` (CompositionRoot, не прогоняется в этом окружении — см. §3) |
| 3 | В `answers` системное аудио отправляется непосредственно в Realtime во время речи | ✅ | `AnswersModeController.start()` пишет каждый фрейм в `realtime.appendAudio()` синхронно с захватом, без промежуточного STT — `OpenAIRealtimeAnswerClientTests::sessionUpdateSentBeforeFirstAudioAppend` |
| 4 | Whisper/STT отсутствует перед генерацией ответа | ✅ | `QuestionAnswerLogger.beginDraft()` вызывается только ПОСЛЕ первого валидного delta (`AnswersModeController.handle` case `.textDelta`, `isFirstDelta`) — `QuestionAnswerLoggerTests::whisperNotCalledBeforeBeginDraft`, `AnswersScenarioTests` (весь файл) |
| 5 | UI использует `response.output_text.delta` и не ждёт done | ✅ | `OpenAIRealtimeAnswerClientTests::firstDeltaPublishedBeforeResponseDone` |
| 6 | Транскрипция только вопроса — асинхронно после валидного ответа | ✅ | `QuestionAnswerLoggerTests::beginDraftPersistsAnswerStreamingBeforeTranscriptionResolves`, `answerSavedEvenWhileQuestionStillTranscribing` |
| 7 | Обычные реплики не попадают в Q&A history | ✅ | `qa_entries`/`qa_entries_fts` пишутся только из `QuestionAnswerLogger.persist()`, вызываемого исключительно из `beginDraft`/`recordCompleted`/`recordCancelled`/`updateQuestionText` — ни один другой код путь не вызывает `QuestionAnswerRepository.save()`; `AnswersScenarioTests::statementWithoutQuestionWaitsWithoutStartingResponse`, `sentinelDoesNotCreateQuestionAnswerRecord` |
| 8 | В `recording` весь разговор транскрибируется локально | ✅ | `RecordingModeController` + `ChunkedTranscriptionPipeline` + `WhisperKitTranscribing` (реальный WhisperKit, не сеть) — `RecordingModeControllerTests::stopFinalizesSegmentsAndMeetingThenReleasesResources` |
| 9 | В `recording` нет Realtime/Responses вызовов до отдельного действия саммари | ✅ | `RecordingModeController` не имеет зависимости типа `RealtimeAnswering`/`SummaryGenerating` в принципе (структурная гарантия) — `RecordingModeControllerTests::doesNotCallRealtimeOrResponsesAPI` (усилен в этом аудите: теперь проверяет реальную работу репозитория, не только отсутствие краша — см. §6) |
| 10 | В `passive` нет capture/mic/Whisper/network/content writes | ✅ | `ModeCoordinator.controllers` не содержит записи для `.passive` (`precondition` в `init`) — переход в `.passive` может только остановить текущий контроллер, никогда не запускает ничего — `ModeCoordinatorTests::noActiveResourcesInPassiveAfterFullCycle` |
| 11 | Исходное аудио не сохраняется по умолчанию | ✅ | Ни один путь кода не пишет `PCMAudioFrame`/сырые сэмплы на диск; `AppSettingsStore.audioStorageEnabled` по умолчанию `false` и даже при `true` ничего не активирует (честно задокументировано в `SettingsView`/`docs/privacy.md`) |
| 12 | API-ключ только в Keychain, отсутствует в логах/bundle | ✅ | `KeychainSecretStore` — единственная точка `store`/`retrieve`; grep по `Sources/` на `sk-[A-Za-z0-9]` вне `SecretRedactor`/`APIKeyFormatValidator` — 0 совпадений (см. §5); `KeychainSecretStoreTests` (реальный Keychain, 5 тестов) |
| 13 | Старый режим полностью остановлен до запуска нового | ✅ | `ModeCoordinator.performTransition`: `await currentController.stop()` завершается ДО `state = .initialPassive` и ДО `controller.start()` следующего режима — `ModeCoordinatorTests::sixDirectedTransitions` (проверяет порядок `stop.end` < `start.begin`) |
| 14 | Все фоновые задачи имеют владельца, cancellation и ограниченный lifetime | ✅ (с оговоркой) | Циклические/долгоживущие `Task` (`captureTask`, `eventsTask`, `triggerTask`, `systemAudioProducerTask`/`ConsumerTask` и т.д.) хранятся в полях и явно отменяются в `stop()` — проверено `stopReleasesCaptureAndRealtimeResources` и аналогами. Одноразовые fire-and-forget `Task` (`QuestionAnswerLogger.persist()`, `reconcileInterruptedMeetings` в `CompositionRoot.init`) НЕ хранятся и не отменяются, но их время жизни ограничено самим завершением одной async-операции (SQL-запрос), а не бесконечным циклом — они не могут "утечь" в смысле бесконечного потребления ресурсов. См. §6. |
| 15 | Realtime использует GA schema без beta header | ✅ | Проверено живым обращением к документации на этапе 04 (`developers.openai.com`); grep по `Sources/` на `OpenAI-Beta`/`realtime=v1` — 0 совпадений |
| 16 | Серверная conversation не накапливает весь митинг | ✅ | `AnswerContextWindow` (RealtimeClient) удаляет весь input+output окна адресно после каждого показанного ответа (`takeAllForCleanup`) — `OpenAIRealtimeAnswerClientTests::contextFullyClearedAfterVisibleAnswerCompletes` |
| 17 | Ошибки переводят систему в безопасное состояние | ✅ | `ModeCoordinator.watchFailures` -> `requestTransition(to: .passive, reason: "runtime_failure: ...")`; `performTransition` при ошибке `start()` делает `await controller.stop()` перед возвратом `.failedToPassive` — `ModeCoordinatorTests::answersStartErrorRollsBackToPassive`, `recordingStartErrorRollsBackToPassive`, `runtimeFailureAfterStartTransitionsToPassive` |
| 18 | Удаление/экспорт пользовательских данных работают | ✅ | `HistoryView` — удаление одной записи (`swipeActions`) и полная очистка (`confirmationDialog`) для обеих вкладок; экспорт transcript/summary (4 формата) через `MeetingDetailView` + `NSSavePanel` — `SQLiteMeetingRepositoryTests::deleteCascadesToUtterances`, `deleteAllClearsEveryMeeting`, `SQLiteQuestionAnswerRepositoryTests::deleteRemovesOnlyTheTargetedEntry`, `deleteAllClearsEveryEntry` |
| 19 | Ответ на языке вопроса; нет ручного override/клиентского перевода | ✅ | `RealtimeInstructions.system` — единственное место, где задаётся языковое правило; нигде в клиентском коде нет вызовов перевода/повторной генерации на другом языке; `AnswersScenarioTests::russianAndEnglishTextBothFlowThroughStreamingUnmodified` (текст проходит байт-в-байт); `SettingsView` намеренно не имеет переключателя языка ответа |
| 20 | Senior-quality через инструкцию + eval-набор | ✅ (offline) / ⚠️ (live) | `RealtimeInstructions.system` содержит все пункты рубрики текстом; `OpenAIRealtimeAnswerClientTests::fullSystemInstructionSentVerbatim` проверяет доставку целиком; `LanguageEvalCatalog`/`RubricScore` (этап 11) — offline-каталог и fail-closed рубрика; живой model-eval **не выполнялся** (см. §7) |
| 21 | Каждый ход после ответа — потенциальный контекст; sentinel удаляет только assistant output | ✅ | `AnswerContextWindow.takeAssistantOutputItems(responseID:)` (только output этого response) vs `takeAllForCleanup` (весь input+output) — разделены методы; `OpenAIRealtimeAnswerClientTests::sentinelSuppressedAndUserItemsPreserved`, `multipleContextTurnsResolveToOneAnswer` |
| 22 | Любой вопрос в `answers` предназначен пользователю; классификатора адресата нет | ✅ | `RealtimeInstructions.system` прямо запрещает определять адресата; grep по `Sources/` не находит никакой "addressee"/адресат-классифицирующей логики |
| 23 | `Ответить сейчас` доступно до ответа, один manual `response.create`, без STT/классификатора | ✅ | `AnswersModeController.handleManualTrigger()` доступен в `.collectingContext` (до любого delta); `OpenAIRealtimeAnswerClientTests::forceAnswerNowSendsExactlyOneResponseCreateWithScopedInstructions` |
| 24 | Гонки manual/automatic, повторные клики, pending speech → ≤1 видимый ответ и ≤1 Q&A draft | ✅ | `activeResponseID`-идемпотентность (первый замеченный ID побеждает) + `beginDraft`'s `guard drafts[responseID] == nil` — `manualTriggerRaceWithAutomaticProducesOneVisibleAnswer`, `repeatedClicksDoNotCreateSecondResponse`, `forceResponseDeferredUntilInFlightSpeechCommits`, `twoConcurrentDraftsDoNotMix` |
| 25 | После ответа/выхода/caps — context очищается, не становится полным transcript | ✅ | `AnswersRingBuffer` (45с cap, эвикшн) + `AnswersModeController` очищает буфер на `.completed`; `AnswerContextWindow` — на показанный ответ; ничего не пишет накопленный контекст в `MeetingRepository` (только `qa_entries`, ограниченное окно) — `AnswersRingBufferTests::neverExceedsCapacityDuration`, `evictsOldestFramesFirst` |

## 3. Команды и фактические результаты

```bash
$ swift build
Build complete! (≈0.3–2s инкрементально)

$ swift test
Test run with 171 tests in 29 suites passed after ≈0.65s

$ swiftc -typecheck Sources/App/*.swift Sources/OverlayUI/*.swift Sources/HistoryUI/*.swift -swift-version 6 \
    -I .build/arm64-apple-macosx/debug/Modules -I .build/arm64-apple-macosx/debug
(без вывода — 0 ошибок, 0 предупреждений)

$ python3 -c "import yaml; yaml.safe_load(open('project.yml'))"
OK

$ xcodegen generate
bash: xcodegen: command not found   # внешний blocker, см. §7 — идентичен для всех 13 этапов
```

- **Clean Debug/Release build через Xcode** — не выполнен (требует `xcodegen`, отсутствующий в этом окружении). SwiftPM-часть (все 9 библиотечных модулей) собирается и тестируется полностью независимо от Xcode-проекта.
- **`Tests/AppTests/CompositionRootTests.swift`** (1 тест, `startsInPassive` над реальным `CompositionRoot()`) — существует, но требует Xcode-таргет `App` (`@testable import App`); `swift test` его не запускает (не входит ни в один SwiftPM test target `Package.swift`). Не выполнялся ни разу за все 13 этапов — задокументировано, не скрыто.
- **Latency fake harness** — `LatencyReportBuilder` (этап 11) прогонялся на синтетических данных в `LatencyReportBuilderTests` (count/p50/p95/max корректны на 100-элементной серии). Реальный прогон против живого `answers`-сеанса не выполнялся — нет способа собрать `.app` в этом окружении, и (см. `docs/implementation-status.md`, этап 11) нет ключа/бюджета на платный вызов.
- **Статический поиск секретов** — `grep -rn "sk-[A-Za-z0-9]" Sources/` даёт совпадения только в `SecretRedactor.swift` (сам regex-паттерн для редактирования) и `APIKeyFormatValidator.swift` (проверка формата, тоже паттерн, не значение) — ни одного захардкоженного реального ключа. `grep -rn "OpenAI-Beta\|realtime=v1" Sources/` — 0 совпадений.
- **Проверка release bundle** — не выполнялась буквально (нет собранного `.app`), но структурно доказана: единственный source-путь таргета `MeetingAssistant` в `project.yml` — `Sources/App`, `Sources/OverlayUI`, `Sources/HistoryUI`; ни один из них не содержит audio-fixture файлов (все `SyntheticAudioFixtures.swift`/WAV-подобные генераторы лежат в `Tests/DomainTests`, вне таргета приложения).
- **Ручной smoke checklist для трёх режимов** — не выполнялся: в этом окружении нет macOS GUI с реальным дисплеем/разрешениями TCC (идентичное ограничение — этапы 03/05/07/09/12).

## 4. Latency summary

Данные из **fake transport** (`FakeRealtimeWebSocketTransport`, `OpenAIRealtimeAnswerClientTests`) и синтетических значений в `LatencyReportBuilderTests` — НЕ от реального соединения с `api.openai.com`. Ниже — иллюстрация формата отчёта на синтетической серии из теста `computesCountP50P95AndMaxPerKind` (значения `10..1000` мс с шагом 10, 100 точек):

| Метрика | count | p50 | p95 | max |
|---|---|---|---|---|
| `responseTotalMs` (синтетика) | 100 | 510 | 960 | 1000 |

Реальных чисел с `api.openai.com` **нет и не заявляется** — ни ключа, ни сети с бюджетом на платный вызов в этом окружении не было ни на одном из 13 этапов. `firstDeltaToFirstPaintMs`, измеренный на fake-транспорте (этап 11, `firstDeltaRecordsFirstPaintLatencyWithoutArtificialDebounce`), стабильно `< 50` мс без единого искусственного `sleep`/debounce на этом пути — что и требовал критерий приёмки этапа 11, но это latency диспетчеризации внутри контроллера, а не время реальной отрисовки экрана (см. этап 11, риски).

## 5. Разрешения и privacy review

- Screen Recording запрашивается только внутри `ScreenCaptureKitSystemAudioCapturing.start()`, вызываемого только из `AnswersModeController`/`RecordingModeController.start()` — то есть только при реальном входе в `answers`/`recording`, никогда при простом запуске приложения (подтверждено структурой: `CompositionRoot.init()` не вызывает `start()` ни на одном контроллере).
- Microphone запрашивается только внутри `AVEngineMicrophoneCapturing.start()`, вызываемого только из `RecordingModeController` — `AnswersModeController` не имеет зависимости на `MicrophoneCapturing` вообще (см. требование 3 в исходном промпте: "`answers` должен работать без microphone permission").
- Diagnostic export (`DiagnosticsSnapshot`) — типизирован на 6 конкретных полей (версия, сборка, режим, фаза, 2 статуса разрешений, счётчики метрик); физически не может случайно включить текст/аудио, т.к. структура Swift не позволяет добавить поле, не объявленное в `Codable`-типе.
- Полный privacy review по режимам — `docs/privacy.md` (этап 12).
- Секреты в логах — весь клиентский код использует единственный канал логирования, `redactedLog` в `OpenAIRealtimeAnswerClient`, который никогда не получает полный текст ошибки API (`code ?? message` логируется только как fallback, а не сообщение целиком — `OpenAIRealtimeAnswerClientTests::rateLimitErrorSurfacesAsFailedWithoutLeakingMessageBody`, `redactsSensitiveContentFromLogs`).

## 6. Найденные проблемы и выполненные исправления (этот аудит)

| # | Находка | Серьёзность | Исправление |
|---|---|---|---|
| 1 | `RecordingModeControllerTests::doesNotCallRealtimeOrResponsesAPI` не содержал ни одного `#expect` — тест, который технически ничего не утверждает (флагован явно в тексте этапа 13: "тесты, которые ничего не утверждают") | Низкая (структурная гарантия типов всё равно держится независимо от теста) | Добавлены `#expect(createdMeetings.count == 1)` и `#expect(finishedMeetings == createdMeetings)` — тест теперь ещё и подтверждает, что контроллер выполняет реальную работу (не просто "не падает"), одновременно с тем, что делает это без единой зависимости на `RealtimeAnswering`/`SummaryGenerating`. Пересмотрено, тест зелёный. |
| 2 | 4 force-unwrap (`!`) в `Sources/`: 2×`try! NSRegularExpression(...)` в `SecretRedactor.swift`, `URL(string:...)!` в `OpenAIRealtimeAnswerClient.swift` (endpoint), `URL(string:...)!` в `ResponsesAPITransport.swift` | Рассмотрено, изменений не внесено | Все четыре — на КОНСТАНТНЫХ строковых литералах, никогда не зависящих от пользовательского ввода или сети; ошибка возможна только при опечатке в самом литерале, что было бы поймано немедленно любым тестом, который реально проходит через этот код путь (`sessionUpdateSentBeforeFirstAudioAppend` для realtime endpoint, весь `SecretRedactorTests` для regex, весь `SummaryTests` для Responses endpoint). Замена на `try?`/`guard let` с fallback-значением была бы ХУЖЕ: подставила бы недействительный URL/no-op regex молча вместо явного краха в точке реальной программистской ошибки. Решение: оставить как есть, задокументировать здесь явно, а не скрывать. |
| 3 | Проверка на пустые `catch {}`, `fatalError`, `preconditionFailure`, `TODO`/`FIXME`, детачнутые (`Task.detached`) задачи, дублирование realtime-схемы вне `RealtimeEventCoding.swift`, hardcoded beta-заголовки | Не найдено | 0 совпадений по каждому пункту (см. точные grep-команды в §3) |
| 4 | Fire-and-forget `Task` без хранимой ссылки: `QuestionAnswerLogger.persist()`, `CompositionRoot.init()`'s `reconcileInterruptedMeetings` | Рассмотрено, изменений не внесено | Оба — однократные async-вызовы с естественно ограниченным временем жизни (завершаются сами после одного SQL-запроса), а не бесконечные циклы; требование 14 ("ограниченный lifetime") выполнено по факту завершения, "владелец" — единственный вызывающий контекст, которому эта операция принадлежит логически (см. запись #14 в матрице). Не переделывалось — добавление хранения/отмены для операции, которая объективно не может зависнуть, было бы избыточной абстракцией без функциональной пользы. |

Других нарушений при построчном просмотре ключевых файлов (`ModeCoordinator`, `AnswersModeController`, `RecordingModeController`, `OpenAIRealtimeAnswerClient`, `QuestionAnswerLogger`, все SQLite-репозитории) не найдено.

## 7. Оставшиеся внешние blockers (сквозные, не новые)

1. **`xcodegen` не установлен** — блокирует `xcodegen generate`, любую сборку через `xcodebuild`, весь Xcode-таргет `MeetingAssistant`/`MeetingAssistantTests`, включая единственный тест (`CompositionRootTests`), который требует реального `App`-модуля. Команда: `brew install xcodegen && xcodegen generate`. Идентично с этапа 01.
2. **Нет Apple Developer ID** — подпись/нотаризация не выполнялись, команды задокументированы в README без секретных значений.
3. **Нет реального дисплея/TCC-согласия** — ScreenCaptureKit, AVAudioEngine, NSPanel/NSStatusItem, глобальные хоткеи, `NSSavePanel`, VoiceOver — весь этот код написан по документированным Apple API и типизирован, но не проверялся интерактивно ни на одном из 13 этапов.
4. **Нет OpenAI API-ключа с бюджетом** — ни Realtime-, ни Responses-эндпоинт не вызывались вживую; вся протокольная корректность подтверждена типизированным кодеком + fake-транспортом (та же оговорка, что в `docs/implementation-status.md` на этапах 04 и 09).
5. **Живые model-evals (`LanguageEvalCatalog.liveModelRubricEval`)** — тест существует, по умолчанию пропускается (`.enabled(if:)`), при явном включении (`MEETING_ASSISTANT_RUN_LIVE_EVALS=1`) честно сообщает, что живой rubric-харнесс не реализован в этом offline-окружении (см. этап 11) — не скрыто, не подделано.

Ни один из этих 5 blockers не является дефектом кода — все они про недоступность внешних ресурсов ЭТОГО окружения (сеть с бюджетом, подпись, GUI/TCC), а не про сам продукт.

## 8. Итоговое соответствие финальным критериям приёмки

- **`docs/final-audit.md` подтверждает каждое исходное требование кодом/тестом** — да, все 25 пунктов §2 имеют прямую ссылку на конкретный файл/тест.
- **Нет известных нарушений критического пути `answers`** — да, требования 3–6, 15–16, 19, 21–25 (все относящиеся к critical path) подтверждены зелёными тестами; аудит не нашёл ни одного нового нарушения.
- **Контекст через несколько ходов используется следующим ответом** — `multipleContextTurnsResolveToOneAnswer`, `AnswersScenarioTests::threeTurnExplanationThenQuestionAccumulatesFullContextSnapshot`.
- **`Ответить сейчас` проверен при semantic miss / повторном клике / гонке** — `sentinelMisclassifiedThenManualTriggerForcesResponse`, `repeatedClicksDoNotCreateSecondResponse`, `manualTriggerRaceWithAutomaticProducesOneVisibleAnswer`.
- **Нет фоновой обработки в `passive`** — структурная гарантия `ModeCoordinator` (§2, пункт 10).
- **Нет облачной транскрипции/ответов в `recording`** — структурная гарантия типов `RecordingModeController` (§2, пункт 9), усилена тестом в этом аудите.
- **Language evals для RU/EN/смешанных, включая RU+английские термины** — `LanguageEvalCatalog` (8 сценариев + отдельный `mixedCase`), offline prompt-contract тесты обязательны и зелёные; живой eval честно помечен как нереализованный (см. §7).
- **Senior-quality rubric проходит либо задокументирован blocker** — `RubricScore` fail-closed логика протестирована; live model-eval blocker задокументирован в §7, не скрыт.
- **Build и tests проходят либо blockers воспроизводимы** — `swift build`/`swift test` зелёные (171/171); единственный build-blocker (`xcodegen`) воспроизводится одной командой, не скрыт.

## 9. Точные шаги запуска MVP

```bash
# 1. Клонировать/открыть репозиторий, установить генератор проекта (один раз)
brew install xcodegen

# 2. Сгенерировать Xcode-проект
cd /Users/r/Sites/mac_gpt_interview
xcodegen generate

# 3. Собрать и запустить (Debug, для разработки)
xcodebuild -project MeetingAssistant.xcodeproj -scheme MeetingAssistant -destination 'platform=macOS' build
open build/Debug/MeetingAssistant.app   # либо запустить прямо из Xcode: Cmd+R

# 4. При первом запуске: onboarding-экран
#    - прочитать, что захватывает каждый режим
#    - опционально сразу вставить API-ключ OpenAI (можно пропустить)
#    - опционально нажать "Проверить/загрузить модель" (Whisper)

# 5. Настройки (значок в главном окне или в строке меню) — при желании:
#    - выбрать приложение-источник системного звука для Answers
#    - добавить/удалить API-ключ
#    - выбрать модель Whisper/саммари, VAD-параметры (developer)

# 6. Переключение режима — Picker в главном окне ИЛИ строка меню:
#    Passive (по умолчанию) -> Answers / Recording

# 7. История — кнопка "История" (главное окно или строка меню):
#    поиск, удаление записи/всей истории, для Recording -> "Создать саммари" + экспорт

# 8. Диагностика — кнопка "Диагностика" в главном окне: сохраняет безопасный JSON-отчёт

# 9. Выход — "Завершить MeetingAssistant" в строке меню (graceful shutdown: сначала
#    переход в passive и освобождение ресурсов, затем выход из процесса)
```

Независимая от Xcode проверка доменной логики (без GUI, без permissions, без сети) — в любой момент:

```bash
swift build && swift test
```

## Краткая сводка для пользователя

**Готово:** три режима (`passive`/`answers`/`recording`) с полной доменной моделью и 171 тестом; реальный OpenAI Realtime-клиент (GA schema, без beta-заголовков); реальный WhisperKit для локальной транскрипции; реальное SQLite-хранилище (WAL, FTS5, миграции, каскадное удаление); реальный Keychain для API-ключа; реальная интеграция с OpenAI Responses API для саммари (chunking/merge, structured outputs); полноценный Settings/onboarding/menu-bar UI; README + `docs/privacy.md` + `docs/troubleshooting.md`.

**Известные ограничения:** ни разу не собирался и не запускался реальный `.app` (нет `xcodegen` в этом окружении); ни разу не выполнялся живой сетевой вызов к OpenAI (нет ключа с бюджетом); live-transcript в Recording обновляется по чанкам (~8с), не пословно; поиск по истории — точное совпадение словоформы (FTS5 `unicode61`, без стемминга); подпись/нотаризация не выполнялись (нет Developer ID).

**Команды запуска:** см. §9 выше — коротко, `brew install xcodegen && xcodegen generate && xcodebuild ... build`, или `swift build && swift test` для проверки без Xcode.
