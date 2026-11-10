export const TRANSCRIPT_LIMIT = 40;
export const NOTICE_LIMIT = 10;
export const CAPTURE_LIMIT = 5;
export const PER_CLIENT_TYPES = ["hello.ok", "pair.ok", "ack", "error", "pong", "export.ready", "history.page", "history.session"];

export function initialState() {
  return {
    connection: "idle",
    deviceId: null,
    replayed: false,
    lastSeq: null,
    resyncNeeded: false,
    pairedToken: null,
    mode: { mode: "passive", phase: "idle" },
    answer: null,
    selectedPoint: -1,
    showTranslation: true,
    captures: [],
    transcript: [],
    levels: {},
    notices: [],
    capabilities: [],
    overlayEnabled: true,
    session: null,
    lastSessionId: null,
    download: null,
    pending: {},
    lastError: null
  };
}

function mergePoints(points, changed) {
  if (!changed || changed.length === 0) {
    return points;
  }
  const next = points.slice();
  for (const point of changed) {
    next[point.index] = point;
  }
  return next.filter(Boolean);
}

function applyDelta(state, data) {
  const answer = state.answer;
  if (!answer || answer.answerId !== data.answerId) {
    return { ...state, resyncNeeded: true };
  }
  const text = answer.text;
  let nextText = text;
  if (data.offset === text.length) {
    nextText = text + data.text;
  } else if (data.offset < text.length) {
    const end = data.offset + data.text.length;
    if (end > text.length || text.slice(data.offset, end) !== data.text) {
      nextText = text.slice(0, data.offset) + data.text;
    }
  } else {
    return { ...state, resyncNeeded: true };
  }
  return { ...state, answer: { ...answer, text: nextText, points: mergePoints(answer.points, data.points) } };
}

function applyTranscript(transcript, line) {
  const index = transcript.findIndex((item) => item.itemId === line.itemId && item.speaker === line.speaker);
  if (index >= 0) {
    const next = transcript.slice();
    next[index] = line;
    return next;
  }
  const next = transcript.concat([line]);
  return next.length > TRANSCRIPT_LIMIT ? next.slice(next.length - TRANSCRIPT_LIMIT) : next;
}

function levelsFrom(list) {
  const levels = {};
  for (const level of list || []) {
    levels[level.source] = level;
  }
  return levels;
}

function sessionFrom(info, previous) {
  if (!info) {
    return null;
  }
  const same = previous && previous.sessionId === info.sessionId;
  return { sessionId: info.sessionId, startedAt: info.startedAt, stars: same ? previous.stars : 0, lastBookmark: same ? previous.lastBookmark : null };
}

function applyBookmark(session, data, added) {
  if (!session || session.sessionId !== data.sessionId) {
    return session;
  }
  if (!added) {
    return { ...session, stars: Math.max(0, session.stars - 1), lastBookmark: { kind: "removed", bookmarkId: data.bookmarkId } };
  }
  const stars = data.kind === "star" ? session.stars + 1 : session.stars;
  return { ...session, stars, lastBookmark: { kind: data.kind, bookmarkId: data.bookmarkId, markedAt: data.markedAt } };
}

export function sessionElapsed(startedAt, now) {
  if (typeof startedAt !== "number" || typeof now !== "number") {
    return "—";
  }
  const total = Math.max(0, Math.floor((now - startedAt) / 1000));
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const seconds = total % 60;
  const pad = (value) => String(value).padStart(2, "0");
  return hours > 0 ? hours + ":" + pad(minutes) + ":" + pad(seconds) : pad(minutes) + ":" + pad(seconds);
}

export function exportTarget(state) {
  if (state.session) {
    return state.session.sessionId;
  }
  return state.lastSessionId || null;
}

export function sessionCommand(state) {
  return state.session ? "session.stop" : "session.start";
}

function applySnapshot(state, envelope) {
  const data = envelope.data;
  const answer = data.answer
    ? { answerId: data.answer.answerId, trigger: data.answer.trigger, status: data.answer.status, text: data.answer.text, points: (data.answer.points || []).slice() }
    : null;
  const sameAnswer = answer && state.answer && state.answer.answerId === answer.answerId;
  return {
    ...state,
    lastSeq: envelope.seq,
    resyncNeeded: false,
    mode: data.mode,
    answer,
    selectedPoint: sameAnswer ? state.selectedPoint : -1,
    transcript: (data.transcript || []).slice(-TRANSCRIPT_LIMIT),
    levels: levelsFrom(data.levels),
    notices: (data.notices || []).slice(-NOTICE_LIMIT),
    capabilities: data.capabilities || [],
    overlayEnabled: data.overlayEnabled !== false,
    session: sessionFrom(data.session, state.session)
  };
}

function applyPerClient(state, envelope) {
  const data = envelope.data || {};
  switch (envelope.type) {
    case "hello.ok":
      return { ...state, connection: "online", deviceId: data.deviceId, replayed: data.replayed === true, lastError: null };
    case "pair.ok":
      return { ...state, deviceId: data.deviceId, pairedToken: data.deviceToken, lastError: null };
    case "ack": {
      const pending = { ...state.pending };
      const command = pending[data.cmdId];
      delete pending[data.cmdId];
      if (data.ok) {
        return { ...state, pending };
      }
      return { ...state, pending, lastError: { code: data.code || "rejected", message: data.message || null, command: command || null } };
    }
    case "error":
      return { ...state, lastError: { code: data.code, message: data.message || null, fatal: data.fatal === true } };
    case "export.ready":
      if (typeof data.url !== "string" || data.url.indexOf("/export/") !== 0) {
        return state;
      }
      return { ...state, download: { sessionId: data.sessionId, url: data.url, filename: data.filename || "session.md", expiresAt: data.expiresAt } };
    default:
      return state;
  }
}

export function applyEnvelope(state, envelope) {
  if (!envelope || typeof envelope.type !== "string") {
    return state;
  }
  if (PER_CLIENT_TYPES.indexOf(envelope.type) >= 0) {
    return applyPerClient(state, envelope);
  }
  if (envelope.type === "state.snapshot") {
    return applySnapshot(state, envelope);
  }
  if (state.lastSeq !== null && envelope.seq <= state.lastSeq) {
    return state;
  }
  const next = { ...state, lastSeq: envelope.seq };
  const data = envelope.data || {};
  switch (envelope.type) {
    case "mode.changed":
      return { ...next, mode: data };
    case "answer.started":
      if (next.answer && next.answer.answerId === data.answerId) {
        return next;
      }
      return { ...next, selectedPoint: -1, answer: { answerId: data.answerId, trigger: data.trigger, status: "streaming", text: "", points: [] } };
    case "answer.delta":
      return applyDelta(next, data);
    case "answer.replace":
      if (!next.answer || next.answer.answerId !== data.answerId) {
        return { ...next, resyncNeeded: true };
      }
      return { ...next, answer: { ...next.answer, text: data.text, points: (data.points || []).slice() } };
    case "answer.done": {
      if (!next.answer || next.answer.answerId !== data.answerId) {
        return next;
      }
      const answer = { ...next.answer, status: data.status, points: mergePoints(next.answer.points, data.points) };
      return { ...next, answer, resyncNeeded: next.resyncNeeded || answer.text.length !== data.length };
    }
    case "transcript.delta":
      return { ...next, transcript: applyTranscript(next.transcript, data) };
    case "level":
      return { ...next, levels: { ...next.levels, [data.source]: data } };
    case "notice": {
      const notices = next.notices.concat([data]);
      return { ...next, notices: notices.length > NOTICE_LIMIT ? notices.slice(notices.length - NOTICE_LIMIT) : notices };
    }
    case "screen.captured": {
      if (next.captures.some((item) => item.captureId === data.captureId)) {
        return next;
      }
      const captures = [data].concat(next.captures);
      return { ...next, captures: captures.slice(0, CAPTURE_LIMIT) };
    }
    case "session.started":
      return { ...next, session: sessionFrom(data, next.session) };
    case "session.stopped":
      return next.session && next.session.sessionId !== data.sessionId ? next : { ...next, session: null, lastSessionId: data.sessionId };
    case "bookmark.added":
      return { ...next, session: applyBookmark(next.session, data, true) };
    case "bookmark.removed":
      return { ...next, session: applyBookmark(next.session, data, false) };
    default:
      return next;
  }
}

export function applyLocal(state, action) {
  switch (action.type) {
    case "connection":
      return { ...state, connection: action.status };
    case "commandSent":
      return { ...state, pending: { ...state.pending, [action.cmdId]: action.name } };
    case "forgetSeq":
      return { ...state, lastSeq: null, resyncNeeded: false };
    case "tokenStored":
      return { ...state, pairedToken: null };
    case "dismissError":
      return { ...state, lastError: null };
    case "downloadStarted":
      return { ...state, download: null };
    case "toggleTranslation":
      return { ...state, showTranslation: !state.showTranslation };
    case "selectPoint": {
      const count = state.answer ? state.answer.points.length : 0;
      if (action.index < 0 || action.index >= count) {
        return state;
      }
      return { ...state, selectedPoint: action.index };
    }
    case "stepPoint": {
      const count = state.answer ? state.answer.points.length : 0;
      if (count === 0) {
        return state;
      }
      const start = state.selectedPoint < 0 ? (action.delta > 0 ? -1 : count) : state.selectedPoint;
      const index = Math.min(count - 1, Math.max(0, start + action.delta));
      return { ...state, selectedPoint: index };
    }
    default:
      return state;
  }
}

export function pointText(answer, index) {
  if (!answer || index < 0 || index >= answer.points.length) {
    return "";
  }
  const point = answer.points[index];
  return answer.text.slice(point.start, point.end);
}

export function answerSegments(answer) {
  if (!answer) {
    return [];
  }
  const segments = [];
  let cursor = 0;
  const points = answer.points.slice().sort((a, b) => a.start - b.start);
  for (const point of points) {
    const start = Math.max(cursor, Math.min(point.start, answer.text.length));
    const end = Math.max(start, Math.min(point.end, answer.text.length));
    pushText(segments, answer.text.slice(cursor, start));
    segments.push({ kind: "point", index: point.index, open: point.open, text: answer.text.slice(start, end).replace(/\s+$/, "") });
    cursor = end;
  }
  pushText(segments, answer.text.slice(cursor));
  return segments;
}

function pushText(segments, text) {
  const trimmed = text.replace(/^\s+|\s+$/g, "");
  if (trimmed.length > 0) {
    segments.push({ kind: "text", text: trimmed });
  }
}

export function expandTarget(state) {
  if (!state.answer || state.answer.points.length === 0) {
    return -1;
  }
  if (state.selectedPoint >= 0 && state.selectedPoint < state.answer.points.length) {
    return state.selectedPoint;
  }
  return state.answer.points.length - 1;
}

export function pointIdAt(answer, index) {
  if (!answer) {
    return null;
  }
  const point = answer.points.find((item) => item.index === index);
  return point ? point.pointId : null;
}

export function shouldHandleHotkey(target) {
  if (!target) {
    return true;
  }
  const tag = typeof target.tagName === "string" ? target.tagName.toUpperCase() : "";
  if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT") {
    return false;
  }
  return target.isContentEditable !== true;
}

export function hotkeyAction(key, state) {
  switch (key) {
    case "a":
    case "A":
      return { command: "answer_now" };
    case "r":
    case "R":
      return { command: "reset_context" };
    case "s":
    case "S":
      return state.session ? { command: "star_last" } : null;
    case "[":
      return { local: { type: "stepPoint", delta: -1 } };
    case "]":
      return { local: { type: "stepPoint", delta: 1 } };
    case "c":
    case "C":
      return { copy: state.selectedPoint };
    case "e":
    case "E":
      return state.capabilities.indexOf("expand") >= 0 ? { expand: expandTarget(state) } : null;
    case "Escape":
      return { deepClose: true };
    case "t":
    case "T":
      return { local: { type: "toggleTranslation" } };
    case "x":
    case "X":
      return state.capabilities.indexOf("capture_screen") >= 0 ? { command: "capture_screen" } : null;
    case "z":
    case "Z":
      return state.capabilities.indexOf("capture_screen") >= 0 ? { command: "capture_screen", args: { ask: true } } : null;
    default:
      if (key.length === 1 && key >= "1" && key <= "9") {
        return { local: { type: "selectPoint", index: Number(key) - 1 }, copy: Number(key) - 1 };
      }
      return null;
  }
}
