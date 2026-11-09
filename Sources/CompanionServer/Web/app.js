import { describeClose, helloCommand, makeCommand, pairCommand, pairingCodeFromHash, parseEnvelope, socketURL } from "./protocol.js";
import { applyEnvelope, applyLocal, hotkeyAction, initialState, pointText, shouldHandleHotkey } from "./store.js";
import { copyText, createView } from "./ui.js";

const TOKEN_KEY = "ua057.deviceToken";
const RETRY_DELAY_MS = 2000;

const storage = {
  get(key) {
    try {
      return globalThis.localStorage.getItem(key);
    } catch (error) {
      return null;
    }
  },
  set(key, value) {
    try {
      globalThis.localStorage.setItem(key, value);
    } catch (error) {
      return;
    }
  },
  remove(key) {
    try {
      globalThis.localStorage.removeItem(key);
    } catch (error) {
      return;
    }
  }
};

let state = initialState();
let socket = null;
let retryTimer = null;
let renderQueued = false;
let pendingPair = null;
let memoryToken = null;
const view = { showPairing: false, pairingCode: pairingCodeFromHash(globalThis.location.hash), bannerText: null };

if (view.pairingCode) {
  globalThis.history.replaceState(null, "", globalThis.location.pathname);
}

function currentToken() {
  return storage.get(TOKEN_KEY) || memoryToken;
}

const render = createView(document, {
  command: sendCommand,
  pair: startPairing,
  dismissError() {
    view.bannerText = null;
    update(applyLocal(state, { type: "dismissError" }));
  },
  selectPoint(index, copy) {
    update(applyLocal(state, { type: "selectPoint", index }));
    if (copy) {
      copyText(document, pointText(state.answer, index));
    }
  }
});

function scheduleRender() {
  if (renderQueued) {
    return;
  }
  renderQueued = true;
  globalThis.requestAnimationFrame(() => {
    renderQueued = false;
    view.showPairing = !currentToken() && state.connection !== "online";
    render(state, view);
  });
}

function update(next) {
  state = next;
  scheduleRender();
}

function send(command) {
  if (!socket || socket.readyState !== WebSocket.OPEN) {
    return false;
  }
  socket.send(JSON.stringify(command));
  return true;
}

function sendCommand(name, args) {
  if (state.connection !== "online") {
    return;
  }
  const command = makeCommand(name, args);
  if (send(command)) {
    update(applyLocal(state, { type: "commandSent", cmdId: command.cmdId, name }));
  }
}

function handleEnvelope(envelope) {
  let next = applyEnvelope(state, envelope);
  if (next.pairedToken) {
    memoryToken = next.pairedToken;
    storage.set(TOKEN_KEY, next.pairedToken);
    next = applyLocal(next, { type: "tokenStored" });
    view.bannerText = null;
    send(helloCommand(memoryToken, null));
  }
  if (next.lastError && next.lastError.command === "pair" && !currentToken()) {
    const previous = socket;
    socket = null;
    if (previous) {
      previous.close(1000, "pair_failed");
    }
    update(applyLocal(next, { type: "connection", status: "pairing" }));
    return;
  }
  if (next.resyncNeeded) {
    next = applyLocal(next, { type: "forgetSeq" });
    update(next);
    restart();
    return;
  }
  update(next);
}

function clearRetry() {
  if (retryTimer !== null) {
    globalThis.clearTimeout(retryTimer);
    retryTimer = null;
  }
}

function scheduleRetry() {
  clearRetry();
  retryTimer = globalThis.setTimeout(() => {
    retryTimer = null;
    connect();
  }, RETRY_DELAY_MS);
}

function connect() {
  clearRetry();
  const token = currentToken();
  if (!token && !pendingPair) {
    update(applyLocal(state, { type: "connection", status: "pairing" }));
    return;
  }
  const ws = new WebSocket(socketURL(globalThis.location));
  socket = ws;
  update(applyLocal(state, { type: "connection", status: "connecting" }));
  ws.addEventListener("open", () => {
    if (socket !== ws) {
      return;
    }
    if (pendingPair) {
      const command = pairCommand(pendingPair.code, pendingPair.name);
      pendingPair = null;
      if (send(command)) {
        update(applyLocal(state, { type: "commandSent", cmdId: command.cmdId, name: "pair" }));
      }
    } else {
      send(helloCommand(token, state.lastSeq));
    }
  });
  ws.addEventListener("message", (event) => {
    if (socket !== ws || typeof event.data !== "string") {
      return;
    }
    const envelope = parseEnvelope(event.data);
    if (envelope) {
      handleEnvelope(envelope);
    }
  });
  ws.addEventListener("close", (event) => {
    if (socket !== ws) {
      return;
    }
    socket = null;
    const reason = describeClose(event.code);
    if (reason.forgetToken) {
      storage.remove(TOKEN_KEY);
      memoryToken = null;
      update(applyLocal(applyLocal(state, { type: "forgetSeq" }), { type: "connection", status: "pairing" }));
      view.bannerText = reason.text;
      scheduleRender();
      return;
    }
    if (event.code >= 4000) {
      view.bannerText = reason.text;
    }
    const canRetry = reason.retry && currentToken();
    update(applyLocal(state, { type: "connection", status: canRetry ? "offline" : "closed" }));
    if (canRetry) {
      scheduleRetry();
    }
  });
}

function restart() {
  const previous = socket;
  socket = null;
  if (previous) {
    previous.close(1000, "resync");
  }
  connect();
}

function startPairing(code, name) {
  const trimmed = code.trim();
  if (!trimmed) {
    view.bannerText = "Введите код сопряжения.";
    scheduleRender();
    return;
  }
  pendingPair = { code: trimmed, name: name.trim() || "Браузер" };
  view.bannerText = null;
  restart();
}

document.addEventListener("keydown", (event) => {
  if (event.metaKey || event.ctrlKey || event.altKey || !shouldHandleHotkey(event.target)) {
    return;
  }
  const action = hotkeyAction(event.key, state);
  if (!action) {
    return;
  }
  event.preventDefault();
  if (action.command) {
    sendCommand(action.command);
  }
  if (action.local) {
    update(applyLocal(state, action.local));
  }
  if (action.copy !== undefined) {
    copyText(document, pointText(state.answer, action.copy));
  }
});

connect();
scheduleRender();
