export const HISTORY_TYPES = ["history.page", "history.session"];
export const HISTORY_PAGE_SIZE = 50;

const SOURCE_LABELS = { utterance: "реплика", question_answer: "Q&A", screen_text: "экран", expansion: "раскрытие", bookmark: "отметка" };
const SPEAKER_LABELS = { me: "Я", them: "Собеседник" };

export function initialHistory() {
  return { open: false, query: "", requestedQuery: null, pendingCursor: null, items: [], nextCursor: null, loading: false, selected: null, detail: null, loadingDetail: false };
}

function sameQuery(history, q) {
  return (history.requestedQuery || "") === (q || "");
}

export function applyHistory(history, envelope) {
  if (!envelope || HISTORY_TYPES.indexOf(envelope.type) < 0) {
    return history;
  }
  const data = envelope.data || {};
  if (envelope.type === "history.page") {
    if (!history.loading || !sameQuery(history, data.q) || (data.cursor || null) !== history.pendingCursor) {
      return history;
    }
    const incoming = Array.isArray(data.items) ? data.items : [];
    let items = incoming;
    if (data.cursor) {
      const known = {};
      for (const item of history.items) {
        known[item.sessionId] = true;
      }
      items = history.items.concat(incoming.filter((item) => !known[item.sessionId]));
    }
    return { ...history, items, nextCursor: data.nextCursor || null, loading: false, pendingCursor: null };
  }
  if (history.selected !== data.sessionId) {
    return history;
  }
  return { ...history, detail: data, loadingDetail: false };
}

export function historyLocal(history, action) {
  switch (action.type) {
    case "open":
      return { ...history, open: true };
    case "close":
      return { ...history, open: false, selected: null, detail: null, loadingDetail: false };
    case "query":
      return { ...history, query: action.text };
    case "requestList": {
      const q = history.query.trim();
      const cursor = action.more && !q ? history.nextCursor : null;
      return { ...history, loading: true, requestedQuery: q, pendingCursor: cursor };
    }
    case "select":
      return { ...history, selected: action.sessionId, detail: null, loadingDetail: true };
    case "back":
      return { ...history, selected: null, detail: null, loadingDetail: false };
    case "failed":
      return action.command === "history.get" ? { ...history, loadingDetail: false } : { ...history, loading: false, pendingCursor: null };
    default:
      return history;
  }
}

export function historyListArgs(history) {
  const args = { limit: HISTORY_PAGE_SIZE };
  if (history.requestedQuery) {
    args.q = history.requestedQuery;
  }
  if (history.pendingCursor) {
    args.cursor = history.pendingCursor;
  }
  return args;
}

export function formatOffset(startedAt, at) {
  if (typeof startedAt !== "number" || typeof at !== "number") {
    return "";
  }
  const total = Math.max(0, Math.floor((at - startedAt) / 1000));
  const pad = (value) => String(value).padStart(2, "0");
  return "+" + pad(Math.floor(total / 60)) + ":" + pad(total % 60);
}

export function formatDate(ms) {
  if (typeof ms !== "number") {
    return "";
  }
  const date = new Date(ms);
  const pad = (value) => String(value).padStart(2, "0");
  return pad(date.getDate()) + "." + pad(date.getMonth() + 1) + "." + date.getFullYear() + " " + pad(date.getHours()) + ":" + pad(date.getMinutes());
}

export function itemTitle(item) {
  return item.title || "Сессия " + formatDate(item.startedAt);
}

export function itemMeta(item) {
  const parts = [formatDate(item.startedAt)];
  if (typeof item.qaCount === "number") {
    parts.push("Q&A " + item.qaCount);
  }
  if (typeof item.starCount === "number" && item.starCount > 0) {
    parts.push("★ " + item.starCount);
  }
  return parts.join(" · ");
}

export function hitLabel(hit) {
  return SOURCE_LABELS[hit.source] || hit.source;
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

function section(doc, title) {
  const wrapper = make(doc, "section", "history-section");
  wrapper.appendChild(make(doc, "h3", null, title));
  return wrapper;
}

function renderDetail(doc, container, detail) {
  clear(container);
  container.appendChild(make(doc, "h2", null, itemTitle(detail)));
  container.appendChild(make(doc, "p", "muted", formatDate(detail.startedAt)));
  if (detail.summary) {
    const summary = section(doc, "Саммари");
    summary.appendChild(make(doc, "pre", "history-text", detail.summary));
    container.appendChild(summary);
  }
  if (detail.moments && detail.moments.length > 0) {
    const moments = section(doc, "Отмеченное");
    const list = make(doc, "ul", "history-list");
    for (const moment of detail.moments) {
      list.appendChild(make(doc, "li", null, (moment.kind === "star" ? "★ " : "⚑ ") + formatOffset(detail.startedAt, moment.markedAt) + (moment.note ? " " + moment.note : "")));
    }
    moments.appendChild(list);
    container.appendChild(moments);
  }
  if (detail.qa && detail.qa.length > 0) {
    const qa = section(doc, "Вопросы и ответы");
    for (const entry of detail.qa) {
      const card = make(doc, "article", "history-qa");
      card.appendChild(make(doc, "p", "muted", (entry.starred ? "★ " : "") + formatOffset(detail.startedAt, entry.askedAt)));
      card.appendChild(make(doc, "p", "history-question", entry.question || "Вопрос не распознан"));
      card.appendChild(make(doc, "pre", "history-text", entry.answer));
      for (const expansion of entry.expansions || []) {
        const nested = make(doc, "div", "history-expansion");
        nested.appendChild(make(doc, "p", "muted", "Раскрытие · " + expansion.model));
        nested.appendChild(make(doc, "pre", "history-text", expansion.text));
        card.appendChild(nested);
      }
      qa.appendChild(card);
    }
    container.appendChild(qa);
  }
  if (detail.expansions && detail.expansions.length > 0) {
    const loose = section(doc, "Раскрытия");
    for (const expansion of detail.expansions) {
      loose.appendChild(make(doc, "pre", "history-text", expansion.text));
    }
    container.appendChild(loose);
  }
  if (detail.transcript && detail.transcript.length > 0) {
    const transcript = section(doc, "Транскрипт");
    const list = make(doc, "ol", "history-list");
    for (const line of detail.transcript) {
      const item = make(doc, "li", "line " + line.speaker);
      item.appendChild(make(doc, "span", "speaker", formatOffset(detail.startedAt, line.at) + " " + (SPEAKER_LABELS[line.speaker] || line.speaker)));
      item.appendChild(make(doc, "span", "utterance", line.text));
      if (line.translation) {
        item.appendChild(make(doc, "span", "muted translation", line.translation));
      }
      list.appendChild(item);
    }
    transcript.appendChild(list);
    if (detail.truncated) {
      transcript.appendChild(make(doc, "p", "muted", "Транскрипт сокращён. Полная версия — в экспорте .md."));
    }
    container.appendChild(transcript);
  }
  if (detail.screens && detail.screens.length > 0) {
    const screens = section(doc, "Тексты экрана");
    for (const screen of detail.screens) {
      screens.appendChild(make(doc, "p", "muted", formatOffset(detail.startedAt, screen.capturedAt) + " " + (screen.application || "")));
      screens.appendChild(make(doc, "pre", "history-text", screen.text));
    }
    container.appendChild(screens);
  }
}

export function createHistoryView(doc, handlers) {
  const byId = (id) => doc.getElementById(id);
  const elements = {
    toggle: byId("history-open"),
    drawer: byId("history"),
    close: byId("history-close"),
    search: byId("history-search"),
    list: byId("history-items"),
    more: byId("history-more"),
    status: byId("history-status"),
    card: byId("history-card"),
    detail: byId("history-detail"),
    back: byId("history-back"),
    exportButton: byId("history-export")
  };

  elements.toggle.addEventListener("click", () => handlers.open());
  elements.close.addEventListener("click", () => handlers.close());
  elements.search.addEventListener("input", () => handlers.query(elements.search.value));
  elements.more.addEventListener("click", () => handlers.more());
  elements.back.addEventListener("click", () => handlers.back());
  elements.exportButton.addEventListener("click", () => {
    if (elements.exportButton.dataset.session) {
      handlers.exportSession(elements.exportButton.dataset.session);
    }
  });
  elements.list.addEventListener("click", (event) => {
    const target = event.target.closest ? event.target.closest("[data-session]") : null;
    if (target) {
      handlers.select(target.dataset.session);
    }
  });

  let renderedItems = null;
  let renderedDetail = null;

  return function render(history, flags) {
    elements.toggle.disabled = !flags.canList;
    elements.drawer.hidden = !history.open;
    if (!history.open) {
      return;
    }
    const showingCard = history.selected !== null;
    elements.card.hidden = !showingCard;
    elements.list.hidden = showingCard;
    elements.more.hidden = showingCard || !history.nextCursor;
    elements.more.disabled = history.loading;
    elements.search.disabled = !flags.canList;
    elements.status.textContent = history.loading || history.loadingDetail ? "Загрузка…" : (!showingCard && history.items.length === 0 ? "Ничего не найдено." : "");
    if (renderedItems !== history.items) {
      renderedItems = history.items;
      clear(elements.list);
      for (const item of history.items) {
        const row = make(doc, "li", "history-row");
        row.dataset.session = item.sessionId;
        row.tabIndex = 0;
        row.appendChild(make(doc, "span", "history-title", itemTitle(item)));
        row.appendChild(make(doc, "span", "muted", itemMeta(item)));
        for (const hit of item.hits || []) {
          row.appendChild(make(doc, "span", "history-hit", hitLabel(hit) + ": " + hit.snippet));
        }
        elements.list.appendChild(row);
      }
    }
    elements.exportButton.dataset.session = history.selected || "";
    elements.exportButton.disabled = !history.selected || !flags.canExport;
    if (renderedDetail !== history.detail) {
      renderedDetail = history.detail;
      if (history.detail) {
        renderDetail(doc, elements.detail, history.detail);
      } else {
        clear(elements.detail);
      }
    }
  };
}
