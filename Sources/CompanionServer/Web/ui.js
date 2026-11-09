import { answerSegments, exportTarget, sessionCommand, sessionElapsed } from "./store.js";

const MODE_LABELS = { passive: "Пассивный", answers: "Ответы", recording: "Запись" };
const PHASE_LABELS = { idle: "ожидание", starting: "запуск", active: "активен", stopping: "остановка", failed: "ошибка" };
const CONNECTION_LABELS = { idle: "не подключено", connecting: "подключение", pairing: "сопряжение", online: "на связи", offline: "нет связи", closed: "отключено" };
const STATUS_LABELS = { streaming: "печатается", completed: "готово", cancelled: "прерван", failed: "ошибка" };
const SPEAKER_LABELS = { them: "Они", me: "Я" };
const SILENCE_TEXT = "Нет связи с Mac больше 20 секунд. Переподключаемся…";
const ERROR_TEXT = {
  pair_invalid_code: "Код неверный или истёк. Получите новый в приложении на Mac.",
  not_in_answers_mode: "Команда доступна только в режиме «Ответы».",
  answer_in_progress: "Дождитесь окончания ответа и повторите сброс.",
  not_available: "Эта функция пока недоступна.",
  mode_transition_failed: "Не удалось переключить режим.",
  session_start_failed: "Не удалось начать сессию.",
  unknown_session: "Сессия не найдена.",
  no_active_session: "Сессия не запущена.",
  no_completed_answer: "Пока нет готового ответа для отметки.",
  bookmark_failed: "Не удалось сохранить отметку.",
  export_failed: "Не удалось подготовить экспорт.",
  unauthorized: "Устройство не сопряжено.",
  throttled: "Слишком много попыток. Подождите минуту.",
  too_many_clients: "Подключено слишком много устройств."
};
const NOTICE_TEXT = {
  capture_fell_back_whole_system: "Приложение не найдено, захватывается весь системный звук.",
  capture_restarted: "Захват звука перезапущен.",
  microphone_fell_back: "Микрофон переключён на запасной.",
  output_route_changed: "Изменился вывод звука.",
  me_channel_unavailable: "Канал «Я» недоступен: ответы работают без ваших реплик."
};

function levelPercent(level) {
  if (!level || typeof level.rmsDBFS !== "number") {
    return 0;
  }
  const clamped = Math.max(-60, Math.min(0, level.rmsDBFS));
  return Math.round(((clamped + 60) / 60) * 100);
}

function clear(element) {
  while (element.firstChild) {
    element.removeChild(element.firstChild);
  }
}

function make(doc, tag, className, text) {
  const element = doc.createElement(tag);
  if (className) {
    element.className = className;
  }
  if (text !== undefined) {
    element.textContent = text;
  }
  return element;
}

export function errorText(error) {
  const base = ERROR_TEXT[error.code] || error.code;
  return error.message && !ERROR_TEXT[error.code] ? base + ": " + error.message : base;
}

export function bookmarkText(bookmark) {
  if (!bookmark) {
    return "";
  }
  switch (bookmark.kind) {
    case "star":
      return "★ ответ отмечен";
    case "moment":
      return "Момент отмечен";
    case "removed":
      return "Отметка снята";
    default:
      return "";
  }
}

export function noticeText(notice) {
  return NOTICE_TEXT[notice.code] || notice.message || notice.code;
}

export function createView(doc, handlers) {
  const byId = (id) => doc.getElementById(id);
  const elements = {
    connection: byId("connection"),
    connectionLabel: byId("connection-label"),
    modeLabel: byId("mode-label"),
    levelSystem: byId("level-system"),
    levelMe: byId("level-me"),
    answerNow: byId("answer-now"),
    reset: byId("reset"),
    session: byId("session-toggle").parentNode,
    sessionToggle: byId("session-toggle"),
    sessionStar: byId("session-star"),
    sessionTimer: byId("session-timer"),
    sessionExport: byId("session-export"),
    sessionFeedback: byId("session-feedback"),
    modeButtons: Array.prototype.slice.call(doc.querySelectorAll("[data-mode]")),
    pairing: byId("pairing"),
    pairingForm: byId("pairing-form"),
    pairingCode: byId("pairing-code"),
    pairingName: byId("pairing-name"),
    banner: byId("banner"),
    bannerText: byId("banner-text"),
    bannerClose: byId("banner-close"),
    transcript: byId("transcript"),
    answer: byId("answer"),
    answerStatus: byId("answer-status"),
    notices: byId("notices")
  };

  elements.answerNow.addEventListener("click", () => handlers.command("answer_now"));
  elements.reset.addEventListener("click", () => handlers.command("reset_context"));
  elements.sessionToggle.addEventListener("click", () => handlers.command(elements.sessionToggle.dataset.command || "session.start"));
  elements.sessionStar.addEventListener("click", () => handlers.command("star_last"));
  elements.sessionExport.addEventListener("click", () => {
    const target = elements.sessionExport.dataset.session;
    if (target) {
      handlers.command("export.request", { sessionId: target });
    }
  });
  for (const button of elements.modeButtons) {
    button.addEventListener("click", () => handlers.command("set_mode", { mode: button.dataset.mode }));
  }
  elements.pairingForm.addEventListener("submit", (event) => {
    event.preventDefault();
    handlers.pair(elements.pairingCode.value, elements.pairingName.value);
  });
  elements.bannerClose.addEventListener("click", () => handlers.dismissError());
  elements.answer.addEventListener("click", (event) => {
    const target = event.target.closest ? event.target.closest("[data-point]") : null;
    if (target) {
      handlers.selectPoint(Number(target.dataset.point), true);
    }
  });

  let renderedAnswerKey = null;

  function renderAnswer(state) {
    const answer = state.answer;
    const key = answer ? [answer.answerId, answer.text.length, answer.points.length, answer.status, state.selectedPoint, answer.text].join("|") : "none";
    if (key === renderedAnswerKey) {
      return;
    }
    renderedAnswerKey = key;
    clear(elements.answer);
    if (!answer) {
      elements.answer.appendChild(make(doc, "p", "placeholder", "Ответ появится здесь."));
      elements.answerStatus.textContent = "";
      return;
    }
    elements.answerStatus.textContent = STATUS_LABELS[answer.status] || answer.status;
    for (const segment of answerSegments(answer)) {
      if (segment.kind === "text") {
        elements.answer.appendChild(make(doc, "span", "answer-text", segment.text));
        continue;
      }
      const point = make(doc, "div", "point" + (segment.index === state.selectedPoint ? " selected" : "") + (segment.open ? " open" : ""));
      point.dataset.point = String(segment.index);
      point.tabIndex = 0;
      point.appendChild(make(doc, "span", "point-number", String(segment.index + 1)));
      point.appendChild(make(doc, "span", "point-text", segment.text));
      elements.answer.appendChild(point);
    }
  }

  function renderTranscript(state) {
    clear(elements.transcript);
    for (const line of state.transcript) {
      const item = make(doc, "li", "line " + line.speaker + (line.isFinal ? "" : " partial"));
      item.appendChild(make(doc, "span", "speaker", SPEAKER_LABELS[line.speaker] || line.speaker));
      item.appendChild(make(doc, "span", "utterance", line.text));
      elements.transcript.appendChild(item);
    }
    elements.transcript.scrollTop = elements.transcript.scrollHeight;
  }

  function renderNotices(state) {
    clear(elements.notices);
    for (const notice of state.notices.slice().reverse()) {
      elements.notices.appendChild(make(doc, "li", "notice " + notice.severity, noticeText(notice)));
    }
  }

  function renderLevel(container, level) {
    const fill = container.querySelector(".fill");
    fill.style.width = levelPercent(level) + "%";
  }

  return function render(state, view) {
    const online = state.connection === "online";
    elements.connection.dataset.status = state.connection;
    elements.connectionLabel.textContent = CONNECTION_LABELS[state.connection] || state.connection;
    const mode = state.mode || { mode: "passive", phase: "idle" };
    elements.modeLabel.textContent = (MODE_LABELS[mode.mode] || mode.mode) + " · " + (PHASE_LABELS[mode.phase] || mode.phase);
    renderLevel(elements.levelSystem, state.levels.system);
    renderLevel(elements.levelMe, state.levels.me);
    const can = (name) => online && state.capabilities.indexOf(name) >= 0;
    const inAnswers = mode.mode === "answers";
    elements.answerNow.disabled = !can("answer_now") || !inAnswers;
    elements.reset.disabled = !can("reset_context") || !inAnswers;
    for (const button of elements.modeButtons) {
      button.disabled = !can("set_mode");
      button.setAttribute("aria-pressed", button.dataset.mode === mode.mode ? "true" : "false");
    }
    const session = state.session;
    const command = sessionCommand(state);
    elements.session.dataset.active = session ? "true" : "false";
    elements.sessionToggle.dataset.command = command;
    elements.sessionToggle.textContent = session ? "Остановить" : "Начать сессию";
    elements.sessionToggle.disabled = !can(command);
    elements.sessionStar.disabled = !session || !can("star_last");
    elements.sessionTimer.textContent = session ? sessionElapsed(session.startedAt, view.now || Date.now()) : "—";
    elements.sessionFeedback.textContent = session ? bookmarkText(session.lastBookmark) : "";
    const target = exportTarget(state);
    elements.sessionExport.dataset.session = target || "";
    elements.sessionExport.disabled = !target || !can("export.request");
    elements.pairing.hidden = !view.showPairing;
    if (view.pairingCode && !elements.pairingCode.value) {
      elements.pairingCode.value = view.pairingCode;
    }
    const message = (view.silent ? SILENCE_TEXT : null) || view.bannerText || (state.lastError ? errorText(state.lastError) : null);
    elements.banner.hidden = !message;
    elements.banner.dataset.kind = view.silent ? "silence" : "info";
    elements.bannerText.textContent = message || "";
    renderAnswer(state);
    renderTranscript(state);
    renderNotices(state);
  };
}

export function startDownload(doc, download) {
  if (!download || typeof download.url !== "string" || download.url.indexOf("/export/") !== 0) {
    return false;
  }
  const link = doc.createElement("a");
  link.href = download.url;
  link.setAttribute("download", download.filename || "session.md");
  link.rel = "noopener";
  link.className = "clipboard-buffer";
  doc.body.appendChild(link);
  link.click();
  doc.body.removeChild(link);
  return true;
}

export function copyText(doc, text) {
  if (!text) {
    return false;
  }
  const area = doc.createElement("textarea");
  area.value = text;
  area.setAttribute("readonly", "");
  area.className = "clipboard-buffer";
  doc.body.appendChild(area);
  area.select();
  let copied = false;
  try {
    copied = doc.execCommand("copy");
  } catch (error) {
    copied = false;
  }
  doc.body.removeChild(area);
  return copied;
}
