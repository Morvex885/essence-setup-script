// Тесты protocol.js с поддельным сокетом: идентификаторы, журнал, терминал,
// событие access и переподключение с токеном возобновления.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { connect, socketUrl, toBase64, fromBase64, RECONNECT_DELAYS, RESUME_KEY } from '../assets/js/protocol.js';

const location = { protocol: 'http:', host: '127.0.0.1:8377' };

/** Поддельный WebSocket: сервер управляет им вручную. */
class FakeSocket {
  static instances = [];
  constructor(url) {
    this.url = url;
    this.readyState = 1; // OPEN
    this.sent = [];
    this.onmessage = null;
    this.onclose = null;
    this.onerror = null;
    FakeSocket.instances.push(this);
  }
  send(data) { this.sent.push(JSON.parse(data)); }
  /** Демон → клиент. */
  receive(message) { this.onmessage({ data: JSON.stringify(message) }); }
  ok(id, data = {}) { this.receive({ id, ok: true, data, sync: null }); }
  closeFromServer() { this.onclose(); }
  close() { this.readyState = 3; if (this.onclose) this.onclose(); }
}


/** Поддельный setTimeout: задержки выполняются вручную. */
function manualTimers() {
  const queue = [];
  return {
    setTimeout: (fn, delay) => { queue.push({ fn, delay }); return queue.length; },
    run() { const item = queue.shift(); assert.ok(item, 'нет запланированного таймера'); item.fn(); return item.delay; },
    get pending() { return queue.length; },
  };
}

function harness({ resume = null, timers = manualTimers() } = {}) {
  FakeSocket.instances = [];
  const connection = connect({ WebSocket: FakeSocket, location, setTimeout: timers.setTimeout, resume });
  return { connection, timers };
}

const hello = (socket, extra = {}) => socket.receive({ event: 'hello', protocol: 3, version: '1.0.0', origin: 'network', ...extra });

function echoServer(socket) {
  // Отвечает `{"ok":true,"data":{"argv":…}}` на каждый запрос.
  const original = socket.send.bind(socket);
  socket.send = (data) => {
    original(data);
    const message = socket.sent[socket.sent.length - 1];
    if (Array.isArray(message.argv)) socket.receive({ id: message.id, ok: true, data: { echoed: message.argv }, sync: null });
  };
}

test('socketUrl и base64', () => {
  assert.equal(socketUrl(location), 'ws://127.0.0.1:8377/ws');
  assert.equal(socketUrl({ protocol: 'https:', host: 'example.test:8443' }), 'wss://example.test:8443/ws');
  assert.deepEqual([...fromBase64(toBase64('привет, node'))], [...new TextEncoder().encode('привет, node')]);
  assert.equal(toBase64(new Uint8Array([0, 1, 2])), 'AAEC');
});

test('hello и запрос: уникальные id и ответ по id', async () => {
  const { connection } = harness();
  const socket = FakeSocket.instances[0];
  hello(socket);
  await connection.ready;
  assert.equal(connection.hello.version, '1.0.0');
  assert.equal(connection.state, 'open');

  const first = connection.request(['session', 'status'], {});
  const second = connection.request(['status'], {});
  assert.deepEqual(socket.sent.map((m) => m.id), [1, 2]);
  socket.ok(2, { version: '1.0.0' });
  socket.ok(1, { open: true });
  assert.deepEqual((await first).data, { open: true });
  assert.deepEqual((await second).data, { version: '1.0.0' });
});

test('секреты и input уходят в запросе', async () => {
  const { connection } = harness();
  const socket = FakeSocket.instances[0];
  hello(socket);
  await connection.ready;
  const reply = connection.request(['session', 'open'], { secrets: { 'script-password': 'pw' }, input: { file: 'x' } });
  socket.ok(1);
  assert.deepEqual(socket.sent[0].secrets, { 'script-password': 'pw' });
  assert.deepEqual(socket.sent[0].input, { file: 'x' });
  assert.equal((await reply).ok, true);
});

test('журнал: событие log идёт в onLog запроса', async () => {
  const { connection } = harness();
  const socket = FakeSocket.instances[0];
  hello(socket);
  await connection.ready;
  const logs = [];
  const reply = connection.request(['group', 'list'], { onLog: (entry) => logs.push(entry) });
  socket.receive({ id: 1, event: 'log', level: 'info', text: 'Чтение групп' });
  socket.receive({ id: 1, event: 'log', level: 'success', text: 'Готово' });
  socket.ok(1, { groups: [] });
  const result = await reply;
  assert.equal(result.ok, true);
  assert.deepEqual(logs, [
    { id: 1, level: 'info', text: 'Чтение групп', argv: ['group', 'list'] },
    { id: 1, level: 'success', text: 'Готово', argv: ['group', 'list'] },
  ]);
});

test('терминал: open, output, stdin, resize, close, ответ', async () => {
  const { connection } = harness();
  const socket = FakeSocket.instances[0];
  hello(socket);
  await connection.ready;
  const outputs = [];
  let opened = 0;
  const term = connection.terminal(['node', 'shell', '--name', 'de'], {
    term: 'xterm-256color',
    cols: 120,
    rows: 30,
    onOpen: () => { opened += 1; },
    onOutput: (bytes) => outputs.push(new TextDecoder().decode(bytes)),
  });
  assert.deepEqual(socket.sent[0].terminal, { term: 'xterm-256color', cols: 120, rows: 30 });
  socket.receive({ id: 1, event: 'terminal', state: 'open' });
  socket.receive({ id: 1, event: 'output', data: toBase64('меню сервера') });
  term.write('q\n');
  term.resize(100, 25);
  term.close();
  assert.deepEqual(socket.sent.slice(1), [
    { id: 1, stdin: toBase64('q\n') },
    { id: 1, resize: { cols: 100, rows: 25 } },
    { id: 1, close: true },
  ]);
  socket.receive({ id: 1, ok: true, data: {}, sync: null });
  assert.equal((await term.done).ok, true);
  assert.equal(opened, 1);
  assert.deepEqual(outputs, ['меню сервера']);
  // После ответа управляющие сообщения не отправляются.
  term.write('x');
  term.close();
  assert.equal(socket.sent.length, 4);
});

test('access: токен возобновления сохраняется в соединении', async () => {
  const { connection } = harness();
  const socket = FakeSocket.instances[0];
  hello(socket);
  await connection.ready;
  const tokens = [];
  connection.on('access', (token) => tokens.push(token));
  const reply = connection.request(['session', 'open'], {});
  socket.receive({ id: 1, event: 'access', resume: 'a'.repeat(64) });
  socket.ok(1, {});
  await reply;
  assert.equal(connection.resume, 'a'.repeat(64));
  assert.deepEqual(tokens, ['a'.repeat(64)]);
});

test('наблюдение: watch:true и события activity', async () => {
  const { connection } = harness();
  const socket = FakeSocket.instances[0];
  hello(socket);
  await connection.ready;
  const events = [];
  const unwatch = connection.watch((event) => events.push(event));
  assert.deepEqual(socket.sent.at(-1), { watch: true });
  socket.receive({ event: 'activity', state: 'start', command: 'group add', origin: 'local' });
  socket.receive({ event: 'activity', state: 'log', level: 'info', text: 'Ожидание' });
  unwatch();
  assert.deepEqual(socket.sent.at(-1), { watch: false });
  assert.deepEqual(events, [
    { event: 'activity', state: 'start', command: 'group add', origin: 'local' },
    { event: 'activity', state: 'log', level: 'info', text: 'Ожидание' },
  ]);
});

test('обрыв: выполняющиеся запросы получают disconnected, переподключение по расписанию', async () => {
  const timers = manualTimers();
  const { connection } = harness({ timers });
  const first = FakeSocket.instances[0];
  hello(first);
  await connection.ready;
  const states = [];
  connection.on('state', (state) => states.push(state));
  const reply = connection.request(['group', 'list'], {});
  first.closeFromServer();
  assert.deepEqual(states, ['reconnecting']);
  const result = await reply;
  assert.equal(result.ok, false);
  assert.equal(result.error.code, 'disconnected');

  assert.equal(timers.run(), RECONNECT_DELAYS[0]);
  const second = FakeSocket.instances[1];
  hello(second);
  await connection.ready;
  assert.equal(connection.state, 'open');
});

test('переподключение с токеном возобновления повторяет session open', async () => {
  const timers = manualTimers();
  const { connection } = harness({ timers, resume: 'f'.repeat(64) });
  const first = FakeSocket.instances[0];
  hello(first);
  await connection.ready;
  echoServer(first);
  first.closeFromServer();
  timers.run();
  const second = FakeSocket.instances[1];
  echoServer(second);
  hello(second);
  const resumed = new Promise((resolve) => connection.on('resumed', resolve));
  const reply = await resumed;
  assert.equal(reply.ok, true);
  // Возобновление отправлено до всех остальных сообщений соединения.
  const resumeMessage = second.sent.find((m) => Array.isArray(m.argv));
  assert.deepEqual(resumeMessage.argv, ['session', 'open']);
  assert.equal(resumeMessage.secrets['access-token'], 'f'.repeat(64));
  assert.equal(connection.state, 'open');
});

/** Поддельный `sessionStorage`. */
function memoryStorage(initial = {}) {
  const values = new Map(Object.entries(initial));
  return {
    values,
    getItem: (key) => (values.has(key) ? values.get(key) : null),
    setItem: (key, value) => values.set(key, String(value)),
    removeItem: (key) => values.delete(key),
  };
}

test('access: токен записывается в переданное хранилище', async () => {
  const storage = memoryStorage();
  FakeSocket.instances = [];
  const connection = connect({ WebSocket: FakeSocket, location, storage, setTimeout: manualTimers().setTimeout });
  const socket = FakeSocket.instances[0];
  hello(socket);
  await connection.ready;
  const reply = connection.request(['session', 'open'], {});
  socket.receive({ id: 1, event: 'access', resume: 'b'.repeat(64) });
  socket.ok(1, {});
  await reply;
  assert.equal(storage.values.get(RESUME_KEY), 'b'.repeat(64));
  assert.equal(RESUME_KEY, 'essence-rc-resume');
});

test('начальный токен возобновления: из хранилища, явный `resume` приоритетнее', () => {
  // Одноразовый код из ссылки сюда не передаётся: его отправляет только первый
  // `session open` (session.js), а не переподключение.
  const storage = memoryStorage({ [RESUME_KEY]: 'c'.repeat(64) });
  FakeSocket.instances = [];
  const stored = connect({ WebSocket: FakeSocket, location, storage, setTimeout: manualTimers().setTimeout });
  assert.equal(stored.resume, 'c'.repeat(64));
  const explicit = connect({ WebSocket: FakeSocket, location, storage, resume: 'd'.repeat(64), setTimeout: manualTimers().setTimeout });
  assert.equal(explicit.resume, 'd'.repeat(64));
  const empty = connect({ WebSocket: FakeSocket, location, storage: memoryStorage(), setTimeout: manualTimers().setTimeout });
  assert.equal(empty.resume, null);
});

test('обрыв: очередь прерванных запросов не отправляется после переподключения', async () => {
  const timers = manualTimers();
  const { connection } = harness({ timers });
  const first = FakeSocket.instances[0];
  hello(first);
  await connection.ready;
  first.closeFromServer();
  // Запрос, ушедший в очередь до обрыва второго сокета, получает `disconnected`.
  timers.run();
  const second = FakeSocket.instances[1];
  const lost = connection.request(['node', 'delete', '--name', 'x'], { secrets: { password: 'p' } });
  assert.equal(connection.inFlight(), true);
  second.closeFromServer();
  assert.equal((await lost).error.code, 'disconnected');
  assert.equal(connection.inFlight(), false);
  timers.run();
  const third = FakeSocket.instances[2];
  hello(third);
  await new Promise((resolve) => setImmediate(resolve));
  assert.deepEqual(third.sent.filter((m) => Array.isArray(m.argv)), []);
});

test('обрыв во время возобновления: соединение не помечается открытым', async () => {
  const timers = manualTimers();
  const { connection } = harness({ timers, resume: 'f'.repeat(64) });
  hello(FakeSocket.instances[0]);
  await connection.ready;
  FakeSocket.instances[0].closeFromServer();
  timers.run();
  const second = FakeSocket.instances[1];
  hello(second);
  second.closeFromServer();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(connection.state, 'reconnecting');
  assert.equal(connection.resume, 'f'.repeat(64));
  timers.run();
  const third = FakeSocket.instances[2];
  echoServer(third);
  const resumed = new Promise((resolve) => connection.on('resumed', resolve));
  hello(third);
  assert.equal((await resumed).ok, true);
  assert.equal(connection.state, 'open');
});

test('переподключение: паузы 1, 2, 5, 5 с, после hello счёт сначала', async () => {
  const timers = manualTimers();
  const { connection } = harness({ timers });
  hello(FakeSocket.instances[0]);
  await connection.ready;
  FakeSocket.instances[0].closeFromServer();
  const delays = [];
  for (let i = 1; i <= 4; i += 1) {
    delays.push(timers.run());
    FakeSocket.instances[i].closeFromServer();
  }
  assert.deepEqual(delays, [1000, 2000, 5000, 5000]);
  delays.length = 0;
  delays.push(timers.run());
  hello(FakeSocket.instances[5]);
  FakeSocket.instances[5].closeFromServer();
  delays.push(timers.run());
  assert.deepEqual(delays, [5000, 1000]);
});

test('возобновление отклонено: токен стирается из хранилища', async () => {
  const timers = manualTimers();
  const storage = memoryStorage({ [RESUME_KEY]: 'e'.repeat(64) });
  FakeSocket.instances = [];
  const connection = connect({ WebSocket: FakeSocket, location, storage, setTimeout: timers.setTimeout });
  hello(FakeSocket.instances[0]);
  await connection.ready;
  FakeSocket.instances[0].closeFromServer();
  timers.run();
  const second = FakeSocket.instances[1];
  const resumed = new Promise((resolve) => connection.on('resumed', resolve));
  hello(second);
  const open = second.sent.find((m) => Array.isArray(m.argv));
  assert.equal(open.secrets['access-token'], 'e'.repeat(64));
  second.receive({ id: open.id, ok: false, error: { code: 'auth_failed', message: 'Неверный или просроченный код доступа.', secret: 'access-token' }, exit: 1 });
  const reply = await resumed;
  assert.equal(reply.error.code, 'auth_failed');
  assert.equal(connection.resume, null);
  assert.equal(storage.values.has(RESUME_KEY), false);
});

test('запрос до подключения буферизуется и уходит после hello', async () => {
  const { connection } = harness();
  const socket = FakeSocket.instances[0];
  const reply = connection.request(['session', 'status'], {});
  hello(socket);
  await connection.ready;
  assert.deepEqual(socket.sent[0].argv, ['session', 'status']);
  socket.ok(1, { open: false });
  assert.equal((await reply).data.open, false);
});

test('несовместимый протокол: без переподключения', async () => {
  const timers = manualTimers();
  const { connection } = harness({ timers });
  const socket = FakeSocket.instances[0];
  socket.receive({ event: 'hello', protocol: 2, version: '0.1.0', origin: 'local' });
  await assert.rejects(connection.ready, /Несовместимый протокол демона: 2/);
  assert.equal(connection.state, 'incompatible');
  assert.equal(timers.pending, 0);
});

test('close(): без переподключения, буфер очищен', async () => {
  const timers = manualTimers();
  const { connection } = harness({ timers });
  const socket = FakeSocket.instances[0];
  hello(socket);
  await connection.ready;
  connection.close();
  socket.closeFromServer();
  assert.equal(connection.state, 'closed');
  assert.equal(timers.pending, 0);
});

test('runs: другой выполняющийся запрос этого соединения с той же командой', async () => {
  const { connection } = harness();
  const socket = FakeSocket.instances[0];
  hello(socket);
  await connection.ready;
  const first = connection.request(['status'], {});
  const second = connection.request(['status', '--json'], {});
  assert.equal(connection.runs('status', 2), true, 'первый запрос ещё выполняется');
  assert.equal(connection.runs('group list', 2), false);
  socket.ok(1, {});
  await first;
  assert.equal(connection.runs('status', 2), false, 'остался только сам запрос');
  socket.ok(2, {});
  await second;
});
