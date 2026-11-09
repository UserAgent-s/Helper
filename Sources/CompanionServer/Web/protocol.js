export const PROTOCOL_VERSION = 1;
export const CLIENT_VERSION = 1;

export const CLOSE_REASONS = {
  4401: { key: "unauthorized", forgetToken: true, retry: false, text: "Устройство не сопряжено или отозвано. Введите новый код." },
  4403: { key: "forbidden", forgetToken: false, retry: false, text: "Доступ запрещён: откройте панель по адресу из приложения." },
  4408: { key: "hello_timeout", forgetToken: false, retry: true, text: "Сервер не дождался приветствия." },
  4409: { key: "too_many_clients", forgetToken: false, retry: false, text: "Подключено слишком много устройств." },
  4426: { key: "unsupported_version", forgetToken: false, retry: false, text: "Версия панели устарела. Обновите страницу." },
  4429: { key: "throttled", forgetToken: false, retry: false, text: "Слишком много попыток. Подождите минуту." },
  1009: { key: "too_big", forgetToken: false, retry: true, text: "Сообщение слишком большое." }
};

export function randomId(prefix) {
  const bytes = new Uint8Array(8);
  globalThis.crypto.getRandomValues(bytes);
  let hex = "";
  for (const byte of bytes) {
    hex += byte.toString(16).padStart(2, "0");
  }
  return prefix + "-" + hex;
}

export function makeCommand(name, args) {
  const command = { v: PROTOCOL_VERSION, cmdId: randomId("c"), name };
  if (args !== undefined) {
    command.args = args;
  }
  return command;
}

export function helloCommand(token, lastSeq) {
  const args = { token, clientVersion: CLIENT_VERSION };
  if (typeof lastSeq === "number" && lastSeq >= 0) {
    args.lastSeq = lastSeq;
  }
  return makeCommand("hello", args);
}

export function pairCommand(code, deviceName) {
  return makeCommand("pair", { code: code.trim(), deviceName: deviceName.trim() });
}

export function parseEnvelope(text) {
  let value;
  try {
    value = JSON.parse(text);
  } catch (error) {
    return null;
  }
  if (!value || value.v !== PROTOCOL_VERSION || typeof value.type !== "string" || typeof value.seq !== "number") {
    return null;
  }
  return value;
}

export function socketURL(location) {
  const scheme = location.protocol === "https:" ? "wss:" : "ws:";
  return scheme + "//" + location.host + "/ws";
}

export function pairingCodeFromHash(hash) {
  if (typeof hash !== "string" || hash.indexOf("#pair=") !== 0) {
    return null;
  }
  const code = decodeURIComponent(hash.slice(6)).trim();
  return code.length > 0 ? code : null;
}

export function describeClose(code) {
  return CLOSE_REASONS[code] || { key: "closed", forgetToken: false, retry: true, text: "Соединение закрыто." };
}

export const BACKOFF_STEPS_MS = [500, 1000, 2000, 4000, 5000];
export const BACKOFF_JITTER = 0.2;
export const PING_INTERVAL_MS = 10000;
export const SILENCE_LIMIT_MS = 20000;

export function backoffDelay(attempt, random) {
  const index = Math.min(Math.max(0, attempt), BACKOFF_STEPS_MS.length - 1);
  const base = BACKOFF_STEPS_MS[index];
  const factor = 1 - BACKOFF_JITTER + 2 * BACKOFF_JITTER * random;
  return Math.round(base * factor);
}

export function pingCommand() {
  return makeCommand("ping", { nonce: randomId("n") });
}
