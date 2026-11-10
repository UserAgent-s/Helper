export const DEEP_TYPES = ["deep.started", "deep.delta", "deep.done"];
export const DEEP_LIMIT = 8;
export const DEEP_FORMATS = [["structured", "Структура"], ["short", "Коротко"], ["steps", "Шаги"], ["code", "Код"], ["star", "STAR"]];
export const DEEP_LANGUAGES = [["auto", "Язык вопроса"], ["ru", "Русский"], ["en", "English"], ["both", "RU + EN"]];

const ERROR_TEXT = {
  claude_unavailable: "Нет ключа Anthropic на Mac.",
  rate_limited: "Anthropic ограничил частоту запросов, попробуйте позже.",
  overloaded: "Anthropic перегружен, попробуйте позже.",
  auth_failed: "Ключ Anthropic не принят.",
  network: "Нет связи с Anthropic.",
  stream_broken: "Поток оборвался.",
  max_tokens: "Ответ обрезан по лимиту длины.",
  expansion_busy: "Уже идут два раскрытия, дождитесь окончания.",
  unknown_point: "Этот пункт больше недоступен.",
  unknown_expansion: "Это раскрытие нельзя уточнить (Mac перезапускался или был отказ).",
  interrupted: "Связь прервалась во время раскрытия."
};

export function initialDeep() {
  return { open: false, format: "structured", language: "auto", model: "", question: "", entries: [], activeId: null, pending: [], lastError: null };
}

export function deepKey(args) {
  if (args.parentRequestId) {
    return "followup:" + args.parentRequestId + ":" + (args.freeText || "").trim();
  }
  if (args.pointId) {
    return "point:" + args.pointId;
  }
  return "free:" + (args.freeText || "").trim();
}

function running(entry) {
  return entry.status === "thinking" || entry.status === "streaming";
}

export function canExpand(deep, args) {
  const key = deepKey(args);
  if (deep.pending.some((item) => item.key === key)) {
    return false;
  }
  if (args.pointId && !args.parentRequestId) {
    return !deep.entries.some((entry) => entry.pointId === args.pointId && running(entry));
  }
  return true;
}

export function runningEntryForPoint(deep, pointId) {
  return deep.entries.find((entry) => entry.pointId === pointId && running(entry)) || null;
}

export function activeEntry(deep) {
  return deep.entries.find((entry) => entry.requestId === deep.activeId) || null;
}

export function canFollowUp(deep) {
  const entry = activeEntry(deep);
  return !!entry && entry.status === "completed" && !entry.refused && !!entry.text;
}

export function deepCommandArgs(deep, source) {
  const args = {};
  if (source.parentRequestId) {
    args.parentRequestId = source.parentRequestId;
    args.freeText = source.freeText;
    return args;
  }
  if (source.pointId) {
    args.pointId = source.pointId;
  }
  if (source.freeText) {
    args.freeText = source.freeText;
  }
  args.format = deep.format;
  args.language = deep.language;
  if (deep.model) {
    args.model = deep.model;
  }
  return args;
}

function limitEntries(entries) {
  if (entries.length <= DEEP_LIMIT) {
    return entries;
  }
  const next = entries.slice();
  while (next.length > DEEP_LIMIT) {
    const index = next.findIndex((entry) => !running(entry));
    next.splice(index >= 0 ? index : 0, 1);
  }
  return next;
}

function updateEntry(deep, requestId, change) {
  const index = deep.entries.findIndex((entry) => entry.requestId === requestId);
  if (index < 0) {
    return deep;
  }
  const entries = deep.entries.slice();
  entries[index] = change(entries[index]);
  return { ...deep, entries };
}

export function applyDeep(deep, envelope) {
  if (!envelope || DEEP_TYPES.indexOf(envelope.type) < 0) {
    return deep;
  }
  const data = envelope.data || {};
  switch (envelope.type) {
    case "deep.started": {
      if (deep.entries.some((entry) => entry.requestId === data.requestId)) {
        return deep;
      }
      let matchIndex = -1;
      if (data.pointId) {
        matchIndex = deep.pending.findIndex((item) => item.pointId === data.pointId && !item.parentRequestId);
      } else {
        matchIndex = deep.pending.findIndex((item) => !item.pointId);
      }
      const match = matchIndex >= 0 ? deep.pending[matchIndex] : null;
      const pending = matchIndex >= 0 ? deep.pending.filter((_, index) => index !== matchIndex) : deep.pending;
      const entry = {
        requestId: data.requestId,
        pointId: data.pointId || null,
        pointNumber: match ? match.pointNumber : null,
        question: match ? match.question : null,
        parentRequestId: match ? match.parentRequestId : null,
        format: data.format,
        language: data.language,
        model: data.model,
        status: "thinking",
        text: "",
        gap: false,
        refused: false,
        errorCode: null,
        ttftMs: null,
        costUsd: null,
        modelId: null
      };
      return { ...deep, open: true, pending, activeId: data.requestId, entries: limitEntries(deep.entries.concat([entry])), lastError: null };
    }
    case "deep.delta":
      return updateEntry(deep, data.requestId, (entry) => {
        const text = entry.text;
        if (data.offset === text.length) {
          return { ...entry, status: "streaming", text: text + data.text };
        }
        if (data.offset < text.length) {
          const end = data.offset + data.text.length;
          if (end <= text.length && text.slice(data.offset, end) === data.text) {
            return entry;
          }
          return { ...entry, status: "streaming", text: text.slice(0, data.offset) + data.text };
        }
        return { ...entry, gap: true };
      });
    case "deep.done":
      return updateEntry(deep, data.requestId, (entry) => ({
        ...entry,
        status: data.status,
        errorCode: data.errorCode || null,
        refused: typeof data.errorCode === "string" && data.errorCode.indexOf("refused") === 0,
        ttftMs: typeof data.ttftMs === "number" ? data.ttftMs : null,
        costUsd: typeof data.costUsd === "number" ? data.costUsd : null,
        modelId: data.modelId || null
      }));
    default:
      return deep;
  }
}

export function deepLocal(deep, action) {
  switch (action.type) {
    case "open":
      return { ...deep, open: true };
    case "close":
      return { ...deep, open: false };
    case "toggle":
      return { ...deep, open: !deep.open };
    case "format":
      return { ...deep, format: action.value };
    case "language":
      return { ...deep, language: action.value };
    case "model":
      return { ...deep, model: action.value };
    case "question":
      return { ...deep, question: action.text };
    case "select":
      return { ...deep, activeId: action.requestId, open: true };
    case "newQuestion":
      return { ...deep, activeId: null, open: true };
    case "requested": {
      const args = action.args;
      const item = { key: deepKey(args), cmdId: action.cmdId, pointId: args.pointId || null, pointNumber: action.pointNumber === undefined ? null : action.pointNumber, question: args.freeText || null, parentRequestId: args.parentRequestId || null };
      return { ...deep, open: true, question: args.pointId ? deep.question : "", pending: deep.pending.concat([item]), lastError: null };
    }
    case "rejected": {
      const pending = deep.pending.filter((item) => item.cmdId !== action.cmdId);
      if (pending.length === deep.pending.length) {
        return deep;
      }
      return { ...deep, pending, lastError: action.code || "rejected" };
    }
    case "online":
      return { ...deep, pending: [] };
    case "snapshot": {
      const entries = deep.entries.map((entry) => (running(entry) ? { ...entry, status: "failed", errorCode: "interrupted" } : entry));
      return { ...deep, entries, pending: [] };
    }
    case "dismissError":
      return { ...deep, lastError: null };
    default:
      return deep;
  }
}

export function deepErrorText(code) {
  if (!code) {
    return "";
  }
  if (code.indexOf("refused") === 0) {
    const category = code.split("_").slice(1).join("_");
    return "Claude отказался отвечать" + (category ? " (" + category + ")" : "") + ". Переформулируйте вопрос.";
  }
  return ERROR_TEXT[code] || "Ошибка: " + code;
}

export function deepStatsText(entry) {
  const parts = [];
  if (typeof entry.ttftMs === "number") {
    parts.push("первый текст через " + (entry.ttftMs / 1000).toFixed(1) + " с");
  }
  if (typeof entry.costUsd === "number") {
    parts.push("$" + entry.costUsd.toFixed(4));
  }
  if (entry.modelId) {
    parts.push(entry.modelId);
  }
  return parts.join(" · ");
}

export function deepTitle(entry) {
  if (entry.parentRequestId) {
    return "Уточнение: " + (entry.question || "");
  }
  if (entry.pointId) {
    return "Пункт " + (entry.pointNumber !== null && entry.pointNumber !== undefined ? entry.pointNumber + 1 : "");
  }
  return "Вопрос: " + (entry.question || "");
}

function element(doc, tag, className, text) {
  const node = doc.createElement(tag);
  if (className) {
    node.className = className;
  }
  if (text !== undefined) {
    node.textContent = text;
  }
  return node;
}

export function createDeepView(doc, handlers) {
  const byId = (id) => doc.getElementById(id);
  const elements = {
    section: byId("deep"),
    status: byId("deep-status"),
    body: byId("deep-body"),
    list: byId("deep-list"),
    format: byId("deep-format"),
    language: byId("deep-language"),
    model: byId("deep-model"),
    form: byId("deep-form"),
    question: byId("deep-question"),
    submit: byId("deep-submit"),
    fresh: byId("deep-new"),
    toggle: byId("deep-toggle"),
    error: byId("deep-error")
  };
  for (const [value, label] of DEEP_FORMATS) {
    const option = element(doc, "option", null, label);
    option.value = value;
    elements.format.appendChild(option);
  }
  for (const [value, label] of DEEP_LANGUAGES) {
    const option = element(doc, "option", null, label);
    option.value = value;
    elements.language.appendChild(option);
  }
  elements.format.addEventListener("change", () => handlers.local({ type: "format", value: elements.format.value }));
  elements.language.addEventListener("change", () => handlers.local({ type: "language", value: elements.language.value }));
  elements.model.addEventListener("change", () => handlers.local({ type: "model", value: elements.model.value }));
  elements.question.addEventListener("input", () => handlers.local({ type: "question", text: elements.question.value }));
  elements.question.addEventListener("keydown", (event) => {
    if (event.key === "Enter" && (event.ctrlKey || event.metaKey)) {
      event.preventDefault();
      handlers.ask(elements.question.value);
    } else if (event.key === "Escape") {
      event.preventDefault();
      handlers.local({ type: "close" });
      elements.question.blur();
    }
  });
  elements.form.addEventListener("submit", (event) => {
    event.preventDefault();
    handlers.ask(elements.question.value);
  });
  elements.fresh.addEventListener("click", () => handlers.local({ type: "newQuestion" }));
  elements.toggle.addEventListener("click", () => handlers.local({ type: "toggle" }));
  elements.list.addEventListener("click", (event) => {
    const target = event.target.closest ? event.target.closest("[data-request]") : null;
    if (target) {
      handlers.local({ type: "select", requestId: target.dataset.request });
    }
  });

  return function render(deep, context) {
    elements.section.hidden = !context.available;
    if (!context.available) {
      return;
    }
    elements.body.hidden = !deep.open;
    elements.toggle.textContent = deep.open ? "Свернуть" : "Развернуть";
    elements.toggle.setAttribute("aria-expanded", deep.open ? "true" : "false");
    elements.format.value = deep.format;
    elements.language.value = deep.language;
    elements.model.value = deep.model;
    if (doc.activeElement !== elements.question) {
      elements.question.value = deep.question;
    }
    const followUp = canFollowUp(deep);
    elements.submit.textContent = followUp ? "Уточнить" : "Спросить";
    elements.question.placeholder = followUp ? "Уточнить текущее раскрытие (Ctrl+Enter)" : "Вопрос к Claude (Ctrl+Enter)";
    elements.fresh.hidden = !followUp;
    elements.submit.disabled = !context.online || deep.question.trim().length === 0;
    const runningCount = deep.entries.filter(running).length + deep.pending.length;
    elements.status.textContent = runningCount > 0 ? "думает…" : "";
    elements.error.textContent = deepErrorText(deep.lastError);
    elements.error.hidden = !deep.lastError;

    while (elements.list.firstChild) {
      elements.list.removeChild(elements.list.firstChild);
    }
    const entries = deep.entries.slice().reverse();
    for (const item of deep.pending) {
      const node = element(doc, "li", "deep-entry pending");
      node.appendChild(element(doc, "div", "deep-title", item.pointId ? "Пункт " + (item.pointNumber !== null ? item.pointNumber + 1 : "") : (item.parentRequestId ? "Уточнение: " : "Вопрос: ") + (item.question || "")));
      node.appendChild(element(doc, "div", "deep-text muted", "думает…"));
      elements.list.appendChild(node);
    }
    for (const entry of entries) {
      const active = entry.requestId === deep.activeId;
      const node = element(doc, "li", "deep-entry" + (active ? " active" : "") + (entry.refused ? " refused" : ""));
      node.dataset.request = entry.requestId;
      node.appendChild(element(doc, "div", "deep-title", deepTitle(entry)));
      if (active || running(entry)) {
        if (entry.status === "thinking") {
          node.appendChild(element(doc, "div", "deep-text muted", "думает…"));
        } else if (entry.text) {
          node.appendChild(element(doc, "div", "deep-text", entry.text));
        }
        if (entry.errorCode) {
          node.appendChild(element(doc, "div", entry.refused || entry.status === "failed" ? "deep-error" : "deep-warning", deepErrorText(entry.errorCode)));
        }
        const stats = deepStatsText(entry);
        if (stats) {
          node.appendChild(element(doc, "div", "deep-stats muted", stats));
        }
      }
      elements.list.appendChild(node);
    }
  };
}
