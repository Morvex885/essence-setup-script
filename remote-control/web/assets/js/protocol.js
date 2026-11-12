// Протокол v3 поверх WebSocket: запросы с `id`, события журнала, терминалы,
// наблюдение за активностью и переподключение с токеном возобновления.
// Модуль не трогает `window`/`document`: `WebSocket`, `location` и таймеры
// передаются в `connect` параметрами (тесты подставляют поддельный сокет).

export const PROTOCOL = 3;
/** Шаги паузы перед повторным подключением, мс; последний повторяется. */
export const RECONNECT_DELAYS = [1000, 2000, 5000];
/** Ключ токена возобновления в `sessionStorage`. */
export const RESUME_KEY = 'essence-rc-resume';
export const DISCONNECTED_MESSAGE = 'Соединение с демоном потеряно. Повторите действие.';

const OPEN = 1;

/** Адрес WebSocket демона на том же хосте, что и страница. */
export function socketUrl(location) {
  const scheme = location.protocol === 'https:' ? 'wss:' : 'ws:';
  return `${scheme}//${location.host}/ws`;
}

/** Байты → base64 (`Uint8Array` либо строка, кодируется в UTF-8). */
export function toBase64(data) {
  const bytes = typeof data === 'string' ? new TextEncoder().encode(data) : data;
  let binary = '';
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
}

/** base64 → `Uint8Array`. */
export function fromBase64(text) {
  const binary = atob(text);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function disconnected() {
  return { ok: false, data: null, error: { code: 'disconnected', message: DISCONNECTED_MESSAGE }, sync: null, exit: 1 };
}

function replyOf(message) {
  return {
    ok: message.ok === true,
    data: message.data === undefined ? null : message.data,
    error: message.error === undefined ? null : message.error,
    sync: message.sync === undefined ? null : message.sync,
    exit: message.exit === undefined ? null : message.exit,
  };
}

function loadToken(storage) {
  if (!storage) return null;
  try { return storage.getItem(RESUME_KEY) || null; } catch { return null; }
}

function storeToken(storage, token) {
  if (!storage) return;
  try {
    if (token) storage.setItem(RESUME_KEY, token);
    else storage.removeItem(RESUME_KEY);
  } catch { /* хранилище недоступно — вход без возобновления */ }
}

function hasKeys(value) {
  return Boolean(value) && Object.keys(value).length > 0;
}

/**
 * Подключение к демону. Возвращает объект соединения:
 * - `ready` — `Promise` первого `hello`; `hello` — последнее приветствие;
 * - `request(argv, { secrets, input, onLog })` → `Promise<{ok,data,error,sync,exit}>`;
 * - `terminal(argv, { term, cols, rows, onOpen, onOutput, onLog })` → `{ id, write, resize, close, done }`;
 * - `watch(onActivity)` → функция отписки;
 * - `on(event, handler)` — события `hello`, `state`, `access`, `log`, `resumed`;
 * - `resume` — текущий токен возобновления, `forget()` — стереть его;
 * - `inFlight()` — есть ли у соединения запросы без ответа;
 * - `runs(label, exceptId)` — выполняется ли у этого соединения другой запрос
 *   с командой `label` («noun verb»);
 * - `close()` — закрыть без переподключения.
 *
 * `storage` (`sessionStorage`) хранит токен возобновления под `RESUME_KEY`:
 * начальное значение берётся оттуда, событие `access` записывает новый токен,
 * отказ при возобновлении и `forget()` стирают. `resume` — начальный токен
 * вместо хранилища.
 */
export function connect({ WebSocket, location, storage = null, setTimeout: later = globalThis.setTimeout, resume = null } = {}) {
  const url = socketUrl(location);
  const pending = new Map();
  const listeners = new Map();
  const watchers = new Set();
  let outbox = [];
  let nextId = 1;
  let socket = null;
  let live = false;
  let closed = false;
  let attempt = 0;
  let greeted = false;
  let readyResolve;
  let readyReject;

  const connection = {
    hello: null,
    resume: resume || loadToken(storage),
    state: 'connecting',
    ready: new Promise((resolve, reject) => { readyResolve = resolve; readyReject = reject; }),
    request,
    terminal,
    watch,
    on,
    close,
    forget,
    inFlight: () => pending.size > 0,
    runs,
  };
  // Отказ первого подключения не должен падать необработанным.
  connection.ready.catch(() => {});

  function emit(event, value) {
    for (const handler of listeners.get(event) || []) handler(value);
  }

  function on(event, handler) {
    if (!listeners.has(event)) listeners.set(event, new Set());
    listeners.get(event).add(handler);
    return () => listeners.get(event).delete(handler);
  }

  function setState(state) {
    connection.state = state;
    emit('state', state);
  }

  function transmit(message) {
    socket.send(JSON.stringify(message));
  }

  function send(message) {
    if (live && socket && socket.readyState === OPEN) transmit(message);
    else outbox.push(message);
  }

  function flush() {
    const queued = outbox;
    outbox = [];
    for (const message of queued) transmit(message);
  }

  function allocate() {
    const id = nextId;
    nextId += 1;
    return id;
  }

  function requestMessage(id, argv, { secrets, input } = {}) {
    const message = { id, argv: [...argv] };
    if (hasKeys(secrets)) message.secrets = { ...secrets };
    if (hasKeys(input)) message.input = { ...input };
    return message;
  }

  function request(argv, options = {}) {
    const id = allocate();
    return new Promise((resolve) => {
      pending.set(id, { resolve, onLog: options.onLog, argv: [...argv] });
      send(requestMessage(id, argv, options));
    });
  }

  function terminal(argv, options = {}) {
    const id = allocate();
    const message = requestMessage(id, argv, options);
    message.terminal = { term: options.term || 'xterm-256color', cols: options.cols || 80, rows: options.rows || 24 };
    let finished = false;
    const done = new Promise((resolve) => {
      pending.set(id, {
        resolve: (reply) => { finished = true; resolve(reply); },
        onLog: options.onLog,
        onOpen: options.onOpen,
        onOutput: options.onOutput,
        argv: [...argv],
      });
    });
    send(message);
    return {
      id,
      done,
      write(data) { if (!finished) send({ id, stdin: toBase64(data) }); },
      resize(cols, rows) { if (!finished) send({ id, resize: { cols, rows } }); },
      close() { if (!finished) send({ id, close: true }); },
    };
  }

  function watch(onActivity) {
    watchers.add(onActivity);
    // Не в очередь: каждое новое `hello` само повторяет `watch:true`.
    if (watchers.size === 1 && live) transmit({ watch: true });
    return () => {
      if (!watchers.delete(onActivity)) return;
      if (watchers.size === 0 && live) transmit({ watch: false });
    };
  }

  function settle(id, reply) {
    const entry = pending.get(id);
    if (!entry) return;
    pending.delete(id);
    entry.resolve(reply);
  }

  function handle(raw) {
    let message;
    try { message = JSON.parse(raw); } catch { return; }
    if (!message || typeof message !== 'object') return;
    if (message.event === 'hello') { onHello(message); return; }
    if (message.event === 'activity') {
      for (const watcher of watchers) watcher(message);
      return;
    }
    const entry = pending.get(message.id);
    if (message.event !== undefined) {
      if (!entry) return;
      switch (message.event) {
        case 'log': {
          const log = { id: message.id, level: message.level, text: message.text, argv: entry.argv };
          if (entry.onLog) entry.onLog(log);
          emit('log', log);
          break;
        }
        case 'terminal':
          if (message.state === 'open' && entry.onOpen) entry.onOpen();
          break;
        case 'output':
          if (entry.onOutput && typeof message.data === 'string') entry.onOutput(fromBase64(message.data));
          break;
        case 'access':
          if (typeof message.resume === 'string' && message.resume) {
            connection.resume = message.resume;
            storeToken(storage, message.resume);
            emit('access', message.resume);
          }
          break;
        default:
          break;
      }
      return;
    }
    if (typeof message.ok === 'boolean') settle(message.id, replyOf(message));
  }

  async function onHello(message) {
    connection.hello = message;
    emit('hello', message);
    if (message.protocol !== PROTOCOL) {
      closed = true;
      setState('incompatible');
      readyReject(new Error(`Несовместимый протокол демона: ${message.protocol}.`));
      socket.close();
      return;
    }
    attempt = 0;
    const reconnect = greeted;
    greeted = true;
    const current = socket;
    if (watchers.size > 0) transmit({ watch: true });
    if (reconnect && connection.resume) {
      // Повторный `session open` по токену до отправки отложенных запросов.
      const id = allocate();
      const opened = new Promise((resolve) => pending.set(id, { resolve, argv: ['session', 'open'] }));
      transmit(requestMessage(id, ['session', 'open'], { secrets: { 'access-token': connection.resume } }));
      const reply = await opened;
      // Обрыв во время возобновления: ответ — `disconnected`, ждём следующего `hello`.
      if (socket !== current || closed || (reply.error && reply.error.code === 'disconnected')) return;
      if (!reply.ok && reply.error && reply.error.secret === 'access-token') forget();
      live = true;
      setState('open');
      flush();
      emit('resumed', reply);
      return;
    }
    live = true;
    setState('open');
    flush();
    if (reconnect) emit('resumed', null);
    else readyResolve(message);
  }

  function onClose() {
    live = false;
    for (const [id, entry] of pending) {
      pending.delete(id);
      entry.resolve(disconnected());
    }
    // Всё, что лежало в очереди, принадлежит запросам, уже получившим
    // `disconnected`: повторная отправка выполнила бы их дважды и удержала бы секреты.
    outbox = [];
    if (closed) { if (connection.state !== 'incompatible') setState('closed'); return; }
    setState('reconnecting');
    const delay = RECONNECT_DELAYS[Math.min(attempt, RECONNECT_DELAYS.length - 1)];
    attempt += 1;
    later(open, delay);
  }

  function open() {
    if (closed) return;
    socket = new WebSocket(url);
    socket.onmessage = (event) => handle(event.data);
    socket.onclose = () => onClose();
    socket.onerror = () => {};
  }

  function runs(label, exceptId = null) {
    for (const [id, entry] of pending) {
      if (id !== exceptId && entry.argv.slice(0, 2).join(' ') === label) return true;
    }
    return false;
  }

  function forget() {
    connection.resume = null;
    storeToken(storage, null);
  }

  function close() {
    closed = true;
    if (socket) socket.close();
  }

  open();
  return connection;
}
