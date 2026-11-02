import Domain
import Foundation
import Observation

@MainActor
@Observable
final class SessionStatusViewModel {
    private let telemetry: SessionTelemetry
    private let router: ProviderRoutingAnswersController
    private let settingsStore: AppSettingsStore

    private(set) var snapshot = SessionTelemetrySnapshot()
    private(set) var activeConfiguration: AnswerSessionConfiguration?
    private(set) var hasUnappliedSettings = false

    init(telemetry: SessionTelemetry, router: ProviderRoutingAnswersController, settingsStore: AppSettingsStore) {
        self.telemetry = telemetry
        self.router = router
        self.settingsStore = settingsStore
        Task { [weak self] in
            let stream = await telemetry.updates()
            for await snapshot in stream {
                guard let self else { return }
                self.snapshot = snapshot
                await self.refreshActiveConfiguration()
            }
        }
    }

    func refreshActiveConfiguration() async {
        let provider = await router.currentProvider
        activeConfiguration = provider == nil ? nil : await router.activeConfiguration
        refreshPendingState()
    }

    func refreshPendingState() {
        guard let activeConfiguration else {
            hasUnappliedSettings = false
            return
        }
        hasUnappliedSettings = activeConfiguration != settingsStore.currentAnswerConfiguration()
    }

    var displayedSelection: AnswerModelSelection {
        activeConfiguration?.selection ?? settingsStore.currentAnswerConfiguration().selection
    }

    var providerLabel: String {
        ProviderText.providerName(displayedSelection.provider)
    }

    var modelLabel: String {
        var label = displayedSelection.modelID
        if displayedSelection.isCustom { label += " " + loc("(указан вручную, не проверен)") }
        if let served = snapshot.servedModel, served != displayedSelection.modelID {
            label += " → " + loc("фактически ответила") + " " + served
        }
        return label
    }

    var outboundDataDescription: String {
        ProviderText.outboundData(displayedSelection.provider)
    }

    var statusText: String {
        ProviderText.status(snapshot.status)
    }

    var usageText: String {
        guard snapshot.usageKnown else {
            return snapshot.responsesWithoutUsage > 0 ? loc("неизвестно (провайдер не вернул usage)") : loc("неизвестно (ответов ещё не было)")
        }
        let usage = snapshot.usage
        var parts: [String] = []
        if let input = usage.inputTokens { parts.append(loc("вход") + " \(input)") }
        if let cached = usage.cachedInputTokens, cached > 0 { parts.append(loc("из кеша") + " \(cached)") }
        if let written = usage.cacheCreationInputTokens, written > 0 { parts.append(loc("запись в кеш") + " \(written)") }
        if let audio = usage.inputAudioTokens { parts.append(loc("аудио") + " \(audio)") }
        if let output = usage.outputTokens { parts.append(loc("выход") + " \(output)") }
        if let reasoning = usage.reasoningTokens { parts.append("reasoning \(reasoning)") }
        if snapshot.responsesWithoutUsage > 0 {
            parts.append(loc("без usage:") + " \(snapshot.responsesWithoutUsage)")
        }
        return parts.joined(separator: " · ")
    }

    var costText: String {
        guard let cost = snapshot.cost else {
            return loc("неизвестно")
        }
        return String(format: "≈ $%.4f ", cost.approximateUSD) + loc("(оценка, не счёт; тариф от") + " \(cost.pricing.verifiedOn), \(cost.pricing.sourceURL))"
    }

    var spendText: String? {
        switch snapshot.spendState {
        case .noLimit, .belowLimit: return nil
        case .limitReachedWarning: return loc("Мягкий порог расходов достигнут (только предупреждение).")
        case .limitReachedStopped: return loc("Порог расходов достигнут — сессия остановлена. Запрос, уже отправленный в момент срабатывания, мог превысить порог.")
        case .unenforceableCostUnknown: return loc("Порог расходов задан, но стоимость неизвестна — остановка по порогу не может сработать.")
        }
    }

    var recognitionLatencyText: String {
        guard let median = SessionTelemetrySnapshot.median(snapshot.recognitionLatencyMs) else { return loc("нет данных") }
        let p95 = SessionTelemetrySnapshot.percentile95(snapshot.recognitionLatencyMs) ?? median
        return "p50 \(median) ms · p95 \(p95) ms"
    }

    var firstTextLatencyText: String {
        guard let median = SessionTelemetrySnapshot.median(snapshot.questionToFirstTextMs) else { return loc("нет данных") }
        let p95 = SessionTelemetrySnapshot.percentile95(snapshot.questionToFirstTextMs) ?? median
        return "p50 \(median) ms · p95 \(p95) ms"
    }

    var errorsText: String {
        let total = snapshot.errorCounts.values.reduce(0, +)
        var text = loc("ошибок:") + " \(total) · " + loc("переподключений:") + " \(snapshot.reconnects)"
        if let lastError = snapshot.lastError {
            text += " · " + ProviderText.error(lastError)
        }
        return text
    }

    var experienceText: String {
        let knowledge = settingsStore.liveContext.knowledgeContext
        let memory = settingsStore.liveContext.recentExchanges.count
        let profile = settingsStore.candidateProfile.isEmpty ? loc("профиль пуст") : loc("профиль заполнен")
        return profile + " · " + loc("заметок в подсказках:") + " \(knowledge.includedNoteCount) · " + loc("прошлых ответов в памяти:") + " \(memory)/\(settingsStore.answersMemoryCount)"
    }

    var recognitionApplies: Bool {
        displayedSelection.provider == .anthropicClaude
    }
}

@MainActor
enum ProviderText {
    static func providerName(_ provider: AnswerProvider) -> String {
        switch provider {
        case .openAIRealtime: "OpenAI Realtime"
        case .anthropicClaude: "Anthropic Claude"
        }
    }

    static func outboundData(_ provider: AnswerProvider) -> String {
        switch provider {
        case .openAIRealtime:
            loc("В Answers системный звук выбранного приложения непрерывно отправляется в OpenAI Realtime API вместе с инструкциями, профилем, включёнными заметками «Мой опыт» и памятью прошлых ответов. Микрофон не используется.")
        case .anthropicClaude:
            loc("В Answers звук распознаётся локально (WhisperKit). В Anthropic отправляется только текст: распознанная речь с момента последнего ответа, предыдущие пары вопрос-ответ, инструкции, профиль и включённые заметки «Мой опыт». Аудио не покидает Mac.")
        }
    }

    static func status(_ status: AnswerPipelineStatus) -> String {
        switch status {
        case .idle: loc("не активно")
        case .loadingRecognitionModel: loc("загрузка модели распознавания…")
        case .listening: loc("слушаю, автоответ включён")
        case .recognizing: loc("распознаю фрагмент речи…")
        case .waitingForManualTrigger: loc("накапливаю вопрос, ответ только по нажатию")
        case .generating: loc("генерирую подсказку…")
        case .providerError(let failure): loc("ошибка:") + " " + Self.error(failure)
        }
    }

    static func error(_ error: AnswerProviderError) -> String {
        switch error {
        case .missingAPIKey(let provider): loc("не задан API-ключ") + " " + providerName(provider)
        case .authentication: loc("ключ отклонён (ошибка авторизации)")
        case .billing: loc("проблема с оплатой или квотой аккаунта")
        case .permission: loc("нет доступа к этой модели/операции для ключа")
        case .modelNotFound: loc("модель не найдена или недоступна вашей организации")
        case .rateLimited(let retryAfter): loc("превышен лимит запросов") + (retryAfter.map { ", " + loc("повтор через") + " \($0) s" } ?? "")
        case .overloaded: loc("сервис временно перегружен")
        case .serverError(let status): loc("ошибка сервера") + " (\(status))"
        case .invalidRequest: loc("запрос отклонён как некорректный (проверьте модель и параметры)")
        case .network: loc("сетевая ошибка")
        case .refused: loc("модель отказалась отвечать")
        case .recognitionUnavailable: loc("локальное распознавание недоступно")
        case .spendLimitReached: loc("достигнут порог расходов")
        case .unknown: loc("неизвестная ошибка")
        }
    }
}
