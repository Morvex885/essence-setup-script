// Тесты модели обзора подключений, вкладки ноды «Подключения» и
// экрана «Telegram Proxy» (эталон — `#[cfg(test)]` в `remote-control/tui/src/nodes.rs`).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  EMPTY, nodeText, syncedNode, syncProblem, syncData, overviewNodes, syncAll,
  connectionView, assignmentChanges, assignArgv, assignConnections, connSyncArgv, connListArgv, nodeCheckArgv, syncConnections,
  TELEGRAM_STATUS_ARGV, telegramSetArgv, telegramRemoveArgv, telegramLinkArgv, telegramRotateArgv, telegramTagArgv,
  telegramTagClearArgv, telegramRestartArgv, telegramDiagnosticsArgv, tagError, telegramRows, telegramCandidates,
  telegramResults, telegramStatus, enableTelegram, telegramDomainFlow, rotateTelegramSecret, removeTelegram,
  telegramTagFlow, clearTelegramTag, telegramLink, restartTelegram, telegramDiagnostics, statusAfter,
} from '../assets/js/screens/nodeops-model.js';
import { isFailure } from '../assets/js/flows.js';

const ok = (data) => ({ ok: true, data, error: null });
const err = (code, extra = {}) => ({ ok: false, data: null, error: { code, ...extra } });

test('nodeText как nodes.rs::text', () => {
  assert.equal(nodeText('a'), 'a');
  assert.equal(nodeText(null), '');
  assert.equal(nodeText(undefined), '');
  assert.equal(nodeText(22), '22');
  assert.equal(EMPTY, 'Нет объектов для выбора');
});

test('syncProblem и syncedNode', () => {
  assert.equal(syncProblem('unreachable'), 'недоступна');
  assert.equal(syncProblem('load_failed'), 'не загружена');
  assert.equal(syncProblem('save_failed'), 'не сохранена');
  assert.equal(syncProblem('skipped'), 'пропущена');
  assert.equal(syncProblem('synced'), null);
  assert.equal(syncProblem(undefined), null);
  const sync = { nodes: [{ name: 'a', status: 'synced' }, { name: 'b' }] };
  assert.equal(syncedNode(sync, 'b').name, 'b');
  assert.equal(syncedNode(sync, 'c'), null);
  assert.equal(syncedNode(null, 'a'), null);
});

test('syncData: data, partial → error, иначе null', () => {
  assert.deepEqual(syncData(ok({ nodes: [] })), { nodes: [] });
  assert.equal(syncData(err('partial', { nodes: [1] })).nodes.length, 1);
  assert.equal(syncData(err('locked')), null);
});

test('обзор подключений (Connections::run): назначено/всего и тоны как в TUI', () => {
  const sync = syncData(err('partial', { nodes: [
    { name: 'a', status: 'synced', discovered: ['p1', 'p2'], removed: [], groups: [], error: null },
    { name: 'b', status: 'unreachable', discovered: null, removed: [], groups: [], error: 'remote_failed' }] }));
  const list = [
    { node: 'a', groups: [{ name: 'PC', proxies: ['p1'] }, { name: 'ALL', proxies: ['p1', 'p2'] }] },
    { node: 'b', groups: [{ name: 'PC', proxies: ['x'] }] }, { node: 'c', groups: [{ name: 'X', proxies: ['p'] }] }];
  assert.deepEqual(overviewNodes(list, sync), [
    { name: 'a', problem: null, groups: [{ name: 'PC', count: '1/2', tone: 'warn' }, { name: 'ALL', count: '2/2', tone: 'ok' }] },
    { name: 'b', problem: 'недоступна', groups: [] },
    { name: 'c', problem: null, groups: [{ name: 'X', count: '1/?', tone: 'neutral' }] },
  ]);
  assert.deepEqual(overviewNodes([], null), []);
  // Ноль обнаруженных — нейтральный тон, не «все назначены».
  const zero = overviewNodes([{ node: 'z', groups: [{ name: 'G', proxies: [] }] }], { nodes: [{ name: 'z', status: 'synced', discovered: [] }] });
  assert.deepEqual(zero[0].groups, [{ name: 'G', count: '0/0', tone: 'neutral' }]);
});

/** `ctx` с ответами по порядку (`call`) и счётчиком `failed`. */
function syncCtx(replies) {
  const calls = [];
  const state = { failed: 0 };
  const ctx = {
    call: async (...words) => { calls.push(words); return replies.shift(); },
    failed: () => { state.failed += 1; },
    isFailure,
  };
  return { ctx, calls, state };
}

test('«Синхронизировать все»: conn sync по всем нодам, затем conn list; сбой — null и итог сбоя', async () => {
  let s = syncCtx([err('partial', { nodes: [{ name: 'a', status: 'synced', discovered: ['p'] }] }), ok([{ node: 'a', groups: [{ name: 'G', proxies: ['p'] }] }])]);
  assert.deepEqual(await syncAll(s.ctx), [{ name: 'a', problem: null, groups: [{ name: 'G', count: '1/1', tone: 'ok' }] }]);
  assert.deepEqual(s.calls, [['conn', 'sync'], ['conn', 'list']]);
  s = syncCtx([err('locked')]);
  assert.equal(await syncAll(s.ctx), null);
  assert.deepEqual([s.calls, s.state.failed], [[['conn', 'sync']], 1]);
  s = syncCtx([ok({ nodes: [] }), err('locked')]);
  assert.equal(await syncAll(s.ctx), null);
  assert.equal(s.state.failed, 1);
});

test('вкладка «Подключения»: conn sync --name; partial с кодом ноды — один node check и повтор', async () => {
  const flow = (replies, checks = []) => {
    const calls = [];
    const state = { failed: 0 };
    const ctx = {
      request: async (argv, options) => { calls.push(['request', argv, options.expect]); return replies.shift(); },
      nodeRequest: async (node, argv) => { calls.push(['node', node, argv]); return checks.shift(); },
      failed: () => { state.failed += 1; },
    };
    return { ctx, calls, state };
  };
  const row = (extra = {}) => ({ nodes: [{ name: 'n', status: 'synced', discovered: ['p'], ...extra }] });
  let s = flow([ok(row())]);
  assert.deepEqual(await syncConnections(s.ctx, 'n'), { synced: row().nodes[0] });
  assert.deepEqual(s.calls, [['request', ['conn', 'sync', '--name', 'n'], 'not_found']]);
  // Ключ хоста неизвестен: node check решает вопрос, синхронизация повторяется один раз.
  const locked = err('partial', row({ status: 'unreachable', error: 'host_key_unknown' }));
  s = flow([locked, ok(row())], [ok({})]);
  assert.deepEqual(await syncConnections(s.ctx, 'n'), { synced: row().nodes[0] });
  assert.deepEqual(s.calls.map((call) => call[0]), ['request', 'node', 'request']);
  assert.deepEqual(s.calls[1], ['node', 'n', ['node', 'check', '--name', 'n']]);
  // Повторный код после проверки — без второго node check, итог сбоя.
  s = flow([locked, locked], [ok({})]);
  assert.equal((await syncConnections(s.ctx, 'n')).synced.error, 'host_key_unknown');
  assert.deepEqual([s.calls.length, s.state.failed], [3, 1]);
  // Проверка не удалась — строка partial без повторов (сбой сообщил nodeRequest).
  s = flow([locked], [err('cancelled')]);
  assert.equal((await syncConnections(s.ctx, 'n')).synced.error, 'host_key_unknown');
  assert.deepEqual([s.calls.length, s.state.failed], [2, 0]);
  // partial без кода ноды — итог сбоя; прочие ошибки — сбой чтения экрану.
  s = flow([err('partial', row({ status: 'unreachable', error: 'unreachable' }))]);
  assert.equal((await syncConnections(s.ctx, 'n')).synced.status, 'unreachable');
  assert.equal(s.state.failed, 1);
  const gone = err('not_found');
  s = flow([gone]);
  assert.deepEqual(await syncConnections(s.ctx, 'n'), { failed: gone });
  assert.equal(s.state.failed, 0);
});

test('подключения ноды: группы подключений и проблема синхронизации', () => {
  const listed = [{ node: 'n', groups: [{ name: 'old', proxies: ['p1'] }, { name: 'x', proxies: ['p1'] }] }];
  const view = connectionView(listed, { name: 'n', status: 'synced', discovered: ['p1', 'p2'] }, 'n');
  assert.deepEqual(view.proxies, ['p1', 'p2']);
  assert.deepEqual(view.assigned, [['old', 'x'], []]);
  assert.deepEqual(view.table.map((row) => [row.proxy, row.groups, row.stale]), [['p1', ['old', 'x'], false], ['p2', [], false]]);
  assert.equal(view.problem, null);
  assert.equal(view.checked, true);
  // Нода недоступна: назначенные подключения остаются в списке — их можно
  // снять, — но не отмечены «не найдено»: нода не прочитана.
  const problem = connectionView(listed, { name: 'n', status: 'unreachable', discovered: null }, 'n');
  assert.equal(problem.problem, 'недоступна');
  assert.deepEqual([problem.proxies, problem.stale, problem.assigned, problem.checked], [['p1'], [], [['old', 'x']], false]);
  // Синхронизация не удалась целиком (строки ноды нет): то же, без проблемы.
  const unsynced = connectionView(listed, null, 'n');
  assert.deepEqual([unsynced.problem, unsynced.proxies, unsynced.stale, unsynced.checked], [null, ['p1'], [], false]);
  // Клиент AmneziaWG при найденном AWG — не «не найдено», но в списке и отмечен: смена p1 его сохраняет.
  const awg = connectionView([{ node: 'n', groups: [{ name: 'PC', proxies: ['AWG', 'awg-alice'] }] }],
    { status: 'synced', discovered: ['AWG', 'p1'] }, 'n');
  assert.deepEqual([awg.proxies, awg.stale, awg.assigned], [['AWG', 'p1', 'awg-alice'], [], [['PC'], [], ['PC']]]);
  const values = { 'proxy-0': ['PC'], 'proxy-1': ['PC'], 'proxy-2': ['PC'] };
  assert.deepEqual(assignmentChanges(awg.proxies, awg.assigned, values), [['PC', ['AWG', 'p1', 'awg-alice']]]);
  // Несколько записей одной группы: группы подключения без повторов.
  const twice = connectionView([{ node: 'n', groups: [{ name: 'G', proxies: ['p1'] }, { name: 'G', proxies: ['p1', 'p2'] }] }],
    { status: 'synced', discovered: ['p1', 'p2'] }, 'n');
  assert.deepEqual(twice.assigned, [['G'], ['G']]);
  const empty = connectionView([], null, 'n');
  assert.deepEqual([empty.problem, empty.table], [null, []]);
});

test('argv подключений', () => {
  assert.deepEqual(connSyncArgv(), ['conn', 'sync']);
  assert.deepEqual(connSyncArgv('a'), ['conn', 'sync', '--name', 'a']);
  assert.deepEqual(connListArgv(), ['conn', 'list']);
  assert.deepEqual(connListArgv('n'), ['conn', 'list', '--name', 'n']);
  assert.deepEqual(nodeCheckArgv('n'), ['node', 'check', '--name', 'n']);
  assert.deepEqual(assignArgv('n', [['g2', ['p1', 'p2']], ['old', []]]),
    ['conn', 'set', '--name', 'n', '--assign', 'g2=p1', '--assign', 'g2=p2', '--assign', 'old=']);
  // Имя подключения с запятой — одно значение флага.
  assert.deepEqual(assignArgv('n', [['PC', ['a,b']]]), ['conn', 'set', '--name', 'n', '--assign', 'PC=a,b']);
  // Снятая отметка одной группы из десяти — меняется только она.
  const groups = Array.from({ length: 10 }, (_, i) => `g${i}`);
  assert.deepEqual(assignmentChanges(['p1'], [groups], { 'proxy-0': groups.slice(1) }), [['g0', []]]);
  // Без изменений — пусто (порядок отметок не важен).
  assert.deepEqual(assignmentChanges(['p1', 'p2'], [['a'], ['a', 'b']], { 'proxy-0': ['a'], 'proxy-1': ['b', 'a'] }), []);
  // Разные наборы групп не смешиваются: PC=[p1], TV=[p2], добавлен p2 в PC — TV не трогается.
  assert.deepEqual(assignmentChanges(['p1', 'p2'], [['PC'], ['TV']], { 'proxy-0': ['PC'], 'proxy-1': ['TV', 'PC'] }), [['PC', ['p1', 'p2']]]);
});

/**
 * Поддельный `ctx` назначения: `steps` — `[argv, reply]`, `answers` — ответы `form`.
 * Фоновое чтение `node list` предложения применить отвечает `nodes` и пишется в `offers`.
 */
function assignCtx(steps, answers, nodes = []) {
  const record = { calls: [], forms: [], notices: [], offers: [] };
  const ctx = {
    async request(argv, options = {}) {
      if (options.quiet && argv.join(' ') === 'node list') { record.offers.push(argv); return ok(nodes); }
      assert.ok(steps.length > 0, `лишний запрос ${argv.join(' ')}`);
      const [expected, reply] = steps.shift();
      assert.deepEqual(argv, expected);
      record.calls.push(argv);
      return reply;
    },
    call: (...words) => ctx.request(words),
    async form(props) { record.forms.push(props); return answers.shift(); },
    notify: (level, text) => record.notices.push(text),
    failed: () => record.notices.push('failed'),
    isFailure,
  };
  return { ctx, record };
}

const field = (form, name) => form.fields.find((item) => item.name === name);

test('assignConnections: поле на подключение, текущие группы отмечены, одна команда только с изменёнными', async () => {
  const steps = [[['group', 'list'], ok([{ name: 'g1' }, { name: 'g2' }])], [assignArgv('n', [['g2', ['p2']]]), ok()]];
  const { ctx, record } = assignCtx(steps, [{ 'proxy-0': ['g1'], 'proxy-1': ['g2'] }]);
  await assignConnections(ctx, 'n', ['p1', 'p2'], [['g1'], []]);
  assert.equal(record.forms.length, 1);
  const [form] = record.forms;
  assert.deepEqual(form.fields.map((f) => [f.label, f.type, f.value]), [['p1', 'multi', ['g1']], ['p2', 'multi', []]]);
  assert.deepEqual(field(form, 'proxy-0').options.map((o) => o.value), ['g1', 'g2']);
  assert.equal(steps.length, 0);
  assert.deepEqual(record.notices, []);
  // После conn set — чтение node list предложения применить (ожидающих нод нет — без node apply).
  assert.deepEqual(record.offers, [['node', 'list']]);
});

test('assignConnections: без подключений формы нет', async () => {
  const { ctx, record } = assignCtx([], []);
  await assignConnections(ctx, 'n', [], []);
  assert.deepEqual([record.calls, record.forms.length, record.notices.length], [[], 0, 1]);
});

test('assignConnections: отмена и форма без изменений ничего не меняют, сбои — failed', async () => {
  let { ctx, record } = assignCtx([[['group', 'list'], ok([{ name: 'g' }])]], [null]);
  await assignConnections(ctx, 'n', ['p1'], [[]]);
  assert.deepEqual(record.calls, [['group', 'list']]);
  assert.deepEqual(record.notices, []);
  ({ ctx, record } = assignCtx([[['group', 'list'], ok([{ name: 'g' }])]], [{ 'proxy-0': ['g'] }]));
  await assignConnections(ctx, 'n', ['p1'], [['g']]);
  assert.deepEqual(record.calls, [['group', 'list']]);
  ({ ctx, record } = assignCtx([[['group', 'list'], err('locked')]], []));
  await assignConnections(ctx, 'n', ['p1'], [[]]);
  assert.deepEqual([record.forms.length, record.notices], [0, ['failed']]);
  // Сбой записи (`locked`) открывает форму снова с отмеченным, сравнение — с исходным.
  const set = assignArgv('n', [['g', []]]);
  const steps = [[['group', 'list'], ok([{ name: 'g' }])], [set, err('locked')], [set, ok()]];
  ({ ctx, record } = assignCtx(steps, [{ 'proxy-0': [] }, { 'proxy-0': [] }]));
  await assignConnections(ctx, 'n', ['p1'], [['g']]);
  assert.deepEqual(record.notices, ['failed']);
  assert.deepEqual(record.forms.map((form) => field(form, 'proxy-0').value), [['g'], []]);
  assert.equal(steps.length, 0);
});

test('assignConnections: группа, удалённая после чтения подключений, не снимается и не роняет запрос', async () => {
  // p1 назначен gone и g1; gone уже нет в `group list` — форма без неё, в команде её нет.
  const steps = [[['group', 'list'], ok([{ name: 'g1' }, { name: 'g2' }])], [assignArgv('n', [['g2', ['p1']]]), ok()]];
  let { ctx, record } = assignCtx(steps, [{ 'proxy-0': ['g1', 'g2'] }]);
  await assignConnections(ctx, 'n', ['p1'], [['gone', 'g1']]);
  assert.deepEqual(field(record.forms[0], 'proxy-0').value, ['g1']);
  assert.equal(steps.length, 0);
  assert.deepEqual(record.notices, []);
  // Без изменений в форме — команды нет.
  ({ ctx, record } = assignCtx([[['group', 'list'], ok([{ name: 'g1' }])]], [{ 'proxy-0': ['g1'] }]));
  await assignConnections(ctx, 'n', ['p1'], [['gone', 'g1']]);
  assert.deepEqual(record.calls, [['group', 'list']]);
});

// ─── Telegram ────────────────────────────────────────────────────────────────

/**
 * Поддельный `ctx` Telegram: `steps` — `[argv, reply]` по порядку, `answers` —
 * ответы `form`, `apply` — ответ на предложение применить.
 */
function telegramCtx(steps, answers = [], apply = false) {
  const record = { calls: [], options: [], forms: [], offers: [], planned: [], nodes: [], reviews: [], notices: [], shown: 0 };
  const ctx = {
    async request(argv, options = {}) {
      assert.ok(steps.length > 0, `лишний запрос ${argv.join(' ')}`);
      const [expected, reply] = steps.shift();
      assert.deepEqual(argv, expected);
      record.calls.push(argv);
      record.options.push(options);
      return reply;
    },
    call: (...words) => ctx.request(words),
    async form(props) { record.forms.push(props); return answers.shift(); },
    async confirm(props) { record.offers.push(props.question); return apply; },
    async show() { record.shown += 1; },
    async runConfirmed(title, question, argv) { record.planned.push(argv); return ctx.request(argv); },
    async nodeRequest(name, argv, review, options = {}) {
      record.nodes.push([name, options.operation ? 'operation' : null]);
      record.reviews.push(review ? review.title : null);
      return ctx.request(argv, options);
    },
    notify: (level, text) => record.notices.push(level),
    failed: () => record.notices.push('failed'),
    isFailure,
  };
  return { ctx, record, done: () => assert.equal(steps.length, 0, 'не все запросы выполнены') };
}

const NODES = [
  { name: 'de', ip: '1.1.1.1', port: 22, profile: 'edge', status: 'applied', telegram: { hostname: 'tg.de.example', tag: true } },
  { name: 'nl', ip: '2.2.2.2', port: 22, profile: 'edge', status: 'pending', telegram: null },
  { name: 'raw', ip: '3.3.3.3', port: 22, profile: null, status: 'none', telegram: null },
];

test('telegram: argv команд роли, секрет тега не в argv', () => {
  assert.deepEqual(TELEGRAM_STATUS_ARGV, ['telegram', 'status']);
  assert.deepEqual(telegramSetArgv('de', 'tg.example'), ['telegram', 'set', '--name', 'de', '--domain', 'tg.example']);
  assert.deepEqual(telegramRemoveArgv('de'), ['telegram', 'remove', '--name', 'de']);
  assert.deepEqual(telegramLinkArgv('de'), ['telegram', 'link', '--name', 'de']);
  assert.deepEqual(telegramRotateArgv('de'), ['telegram', 'rotate-secret', '--name', 'de']);
  assert.deepEqual(telegramTagArgv('de'), ['telegram', 'tag', '--name', 'de']);
  assert.deepEqual(telegramTagClearArgv('de'), ['telegram', 'tag', '--name', 'de', '--clear']);
  assert.deepEqual(telegramRestartArgv('de'), ['telegram', 'restart', '--name', 'de']);
  assert.deepEqual(telegramDiagnosticsArgv('de'), ['telegram', 'diagnostics', '--name', 'de']);
});

test('telegram: тег — ровно 32 шестнадцатеричных символа', () => {
  assert.equal(tagError('0123456789abcdefABCDEF0123456789'), null);
  assert.equal(tagError(' 0123456789abcdef0123456789abcdef '), null);
  for (const bad of ['', '0123', '0123456789abcdef0123456789abcdeg', '0123456789abcdef0123456789abcdef0']) {
    assert.notEqual(tagError(bad), null, bad);
  }
});

test('telegram: список — ноды с ролью, варианты включения — ноды с профилем без роли', () => {
  const rows = telegramRows(NODES);
  assert.deepEqual(rows.map((row) => [row.name, row.hostname, row.tag, row.state.tone]), [['de', 'tg.de.example', true, 'ok']]);
  assert.deepEqual(telegramCandidates(NODES).map((option) => option.value), ['nl']);
  assert.deepEqual(telegramRows(null), []);
});

test('telegram status: строки с доменом и сводкой, ошибка с results — таблица, без results — failed', async () => {
  const row = { node: 'de', hostname: 'tg.de.example', code: 0, status: 'ok', reason: '', summary: ['MTProxy: active', 7] };
  const bad = { node: 'nl', hostname: 'tg.nl.example', code: 1, status: 'error', reason: 'ssh', summary: [] };
  let s = telegramCtx([[TELEGRAM_STATUS_ARGV, ok({ results: [row] })]]);
  const table = await telegramStatus(s.ctx);
  assert.deepEqual(table.map((item) => [item.node, item.hostname, item.tone, item.summary]), [['de', 'tg.de.example', 'ok', ['MTProxy: active']]]);
  s = telegramCtx([[TELEGRAM_STATUS_ARGV, err('remote_failed', { results: [row, bad] })]]);
  assert.deepEqual((await telegramStatus(s.ctx)).map((item) => item.tone), ['ok', 'error']);
  assert.deepEqual(s.record.notices, []);
  const partial = telegramResults(err('partial', { results: [{ ...row, status: 'partial' }, { ...row, status: 'not_installed' }] }));
  assert.deepEqual(partial.map((item) => item.tone), ['warn', 'warn']);
  assert.notEqual(partial[0].status, partial[1].status);
  s = telegramCtx([[TELEGRAM_STATUS_ARGV, err('invalid')]]);
  assert.equal(await telegramStatus(s.ctx), null);
  assert.deepEqual(s.record.notices, ['failed']);
});

test('telegram status: изменённая роль сбрасывает результат проверки, прочие действия — нет', () => {
  const table = [{ node: 'de', hostname: 'tg.de.example', status: 'готово' }];
  assert.equal(statusAfter(table, true), null);
  assert.equal(statusAfter(table, false), table);
  assert.equal(statusAfter(null, true), null);
});

// После изменения роли — сразу `node apply --name N` под планом ядра (его
// подтверждение — единственный вопрос); здесь план отклонён.
const applyDeclined = (name) => [['node', 'apply', '--name', name], err('confirmation_required')];

test('telegram: «Включить на ноде» — форма из нод без роли, set, затем node apply --name', async () => {
  let s = telegramCtx([[telegramSetArgv('nl', 'tg.nl.example'), ok({ node: 'nl', hostname: 'tg.nl.example', tag: false })], applyDeclined('nl')],
    [{ node: 'nl', domain: ' tg.nl.example ' }]);
  assert.equal(await enableTelegram(s.ctx, NODES), true);
  assert.deepEqual(s.record.forms[0].fields.find((f) => f.name === 'node').options.map((o) => o.value), ['nl']);
  assert.deepEqual(s.record.nodes, [['nl', 'operation']]);
  s.done();
  // Применено — итог в окне.
  s = telegramCtx([
    [telegramSetArgv('nl', 'tg.nl.example'), ok({ node: 'nl', hostname: 'tg.nl.example', tag: false })],
    [['node', 'apply', '--name', 'nl'], ok({ applied: ['nl'] })],
  ], [{ node: 'nl', domain: 'tg.nl.example' }]);
  await enableTelegram(s.ctx, NODES);
  assert.equal(s.record.shown, 1);
  s.done();
  // Отмена формы и сбой set — без применения.
  s = telegramCtx([], [null]);
  assert.equal(await enableTelegram(s.ctx, NODES), false);
  s = telegramCtx([[telegramSetArgv('nl', 'x'), err('invalid')]], [{ node: 'nl', domain: 'x' }]);
  assert.equal(await enableTelegram(s.ctx, NODES), false);
  assert.deepEqual([s.record.nodes, s.record.notices], [[], ['failed']]);
  // Формат домена — проверкой поля, как `domain_valid` ядра.
  const domain = s.record.forms[0].fields.find((f) => f.name === 'domain');
  assert.deepEqual([domain.required, domain.validate('x') !== null, domain.validate('tg.example.com')], [true, true, null]);
  s.done();
  // Нет нод без роли — без формы.
  s = telegramCtx([], []);
  assert.equal(await enableTelegram(s.ctx, NODES.slice(0, 1)), false);
  assert.deepEqual([s.record.forms.length, s.record.notices], [0, ['warn']]);
});

test('telegram: «Сменить домен» — текущий домен в форме, без изменений команды нет', async () => {
  let s = telegramCtx([], [{ domain: 'tg.de.example' }]);
  assert.equal(await telegramDomainFlow(s.ctx, 'de', 'tg.de.example'), false);
  assert.equal(s.record.forms[0].fields[0].value, 'tg.de.example');
  assert.deepEqual([s.record.forms[0].fields[0].validate('bad domain') !== null, s.record.forms[0].fields[0].validate('new.example')], [true, null]);
  s = telegramCtx([[telegramSetArgv('de', 'new.example'), ok({ node: 'de', hostname: 'new.example', tag: true })], applyDeclined('de')],
    [{ domain: 'new.example' }]);
  assert.equal(await telegramDomainFlow(s.ctx, 'de', 'tg.de.example'), true);
  s.done();
});

test('telegram: секрет и удаление — по плану, после успеха node apply, отказ — без сбоя', async () => {
  for (const [flow, argv] of [[rotateTelegramSecret, telegramRotateArgv('de')], [removeTelegram, telegramRemoveArgv('de')]]) {
    let s = telegramCtx([[argv, ok({ node: 'de' })], applyDeclined('de')]);
    assert.equal(await flow(s.ctx, 'de'), true);
    assert.deepEqual(s.record.planned, [argv]);
    s.done();
    s = telegramCtx([[argv, err('confirmation_required')]]);
    assert.equal(await flow(s.ctx, 'de'), false);
    assert.deepEqual([s.record.nodes, s.record.notices], [[], []]);
    s.done();
  }
});

test('telegram: тег — скрытое поле с проверкой, секрет password; «Убрать тег» — --clear', async () => {
  const tag = 'ab'.repeat(16);
  let s = telegramCtx([[telegramTagArgv('de'), ok({ node: 'de', tag: true })], applyDeclined('de')], [{ password: tag }]);
  assert.equal(await telegramTagFlow(s.ctx, 'de'), true);
  const [field] = s.record.forms[0].fields;
  assert.deepEqual([field.name, field.type, field.validate('short') !== null, field.validate(tag)], ['password', 'secret', true, null]);
  assert.deepEqual(s.record.options[0].secrets, { password: tag });
  s.done();
  s = telegramCtx([], [null]);
  assert.equal(await telegramTagFlow(s.ctx, 'de'), false);
  s = telegramCtx([[telegramTagClearArgv('de'), ok({ node: 'de', tag: false })], applyDeclined('de')]);
  assert.equal(await clearTelegramTag(s.ctx, 'de'), true);
  s.done();
});

test('telegram: ссылка, перезапуск и диагностика (окно операции через nodeRequest)', async () => {
  const link = 'tg://webproxy?server=tg.de.example&port=443&secret=ee00';
  let s = telegramCtx([[telegramLinkArgv('de'), ok({ link })]]);
  assert.equal(await telegramLink(s.ctx, 'de'), link);
  s = telegramCtx([[telegramLinkArgv('de'), err('not_found')]]);
  assert.equal(await telegramLink(s.ctx, 'de'), null);
  assert.deepEqual(s.record.notices, ['failed']);
  s = telegramCtx([[telegramRestartArgv('de'), ok({ node: 'de' })], [telegramDiagnosticsArgv('de'), ok({ node: 'de' })]]);
  assert.equal(await restartTelegram(s.ctx, 'de'), true);
  assert.equal(await telegramDiagnostics(s.ctx, 'de'), true);
  assert.deepEqual(s.record.nodes, [['de', 'operation'], ['de', 'operation']]);
  assert.deepEqual(s.record.reviews, ['Перезапуск Telegram Proxy', null], 'перезапуск — по плану ядра, диагностика только читает');
  assert.deepEqual(s.record.offers, []);
  s.done();
});
