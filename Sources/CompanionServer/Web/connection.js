import { PING_INTERVAL_MS, SILENCE_LIMIT_MS, backoffDelay } from "./protocol.js";

export function createSupervisor(options) {
  const timers = options.timers;
  const random = options.random;
  let attempt = 0;
  let reconnectTimer = null;
  let pingTimer = null;
  let silenceTimer = null;
  let silent = false;
  let running = false;
  let live = false;

  function cancel(timer) {
    if (timer !== null) {
      timers.clearTimeout(timer);
    }
    return null;
  }

  function setSilent(value) {
    if (silent !== value) {
      silent = value;
      options.onSilence(value);
    }
  }

  function armSilence() {
    silenceTimer = cancel(silenceTimer);
    silenceTimer = timers.setTimeout(() => {
      silenceTimer = null;
      setSilent(true);
      if (live) {
        live = false;
        pingTimer = cancel(pingTimer);
        options.drop();
      }
    }, SILENCE_LIMIT_MS);
  }

  function armPing() {
    pingTimer = cancel(pingTimer);
    pingTimer = timers.setTimeout(() => {
      pingTimer = null;
      if (live) {
        options.ping();
        armPing();
      }
    }, PING_INTERVAL_MS);
  }

  function connectNow() {
    reconnectTimer = cancel(reconnectTimer);
    if (running) {
      options.connect();
    }
  }

  return {
    start() {
      running = true;
      attempt = 0;
      connectNow();
    },
    authenticated() {
      attempt = 0;
      live = true;
      setSilent(false);
      armSilence();
      armPing();
    },
    heard() {
      if (!live) {
        return;
      }
      setSilent(false);
      armSilence();
    },
    closed(retry) {
      live = false;
      pingTimer = cancel(pingTimer);
      if (!running || !retry) {
        return null;
      }
      if (silenceTimer === null && !silent) {
        armSilence();
      }
      const delay = backoffDelay(attempt, random());
      attempt += 1;
      reconnectTimer = cancel(reconnectTimer);
      reconnectTimer = timers.setTimeout(() => {
        reconnectTimer = null;
        connectNow();
      }, delay);
      return delay;
    },
    wake() {
      if (running && !live && reconnectTimer !== null) {
        attempt = 0;
        connectNow();
      }
    },
    stop() {
      running = false;
      live = false;
      reconnectTimer = cancel(reconnectTimer);
      pingTimer = cancel(pingTimer);
      silenceTimer = cancel(silenceTimer);
      setSilent(false);
    },
    get attempt() {
      return attempt;
    },
    get silent() {
      return silent;
    }
  };
}
