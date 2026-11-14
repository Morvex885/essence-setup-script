// Тесты модели обзора подключений, вкладок ноды «Подключения», «AmneziaWG» и
// экрана «Telegram Proxy» (эталон — `#[cfg(test)]` в `remote-control/tui/src/nodes.rs`).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  EMPTY, nodeText, syncedNode, syncProblem, syncData, overviewNodes, syncAll,
  connectionView, assignmentChanges, assignArgv, assignConnections, connSyncArgv, connListArgv, nodeCheckArgv, syncConnections,
  awgStatusArgv, awgSyncArgv, awgRemovePeerArgv, awgOrphansArgv, awgView,
  TELEGRAM_BATCH, TELEGRAM_COMPONENTS, TELEGRAM_STATUS_ARGV, telegramArgv, telegramResults,
  telegramMenu, telegramBatch, telegramStatus,
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

test('telegramBatch: сбой без таблицы открывает форму снова с выбранными нодами', async () => {
  const action = TELEGRAM_BATCH.find((item) => item.id === 'install');
  const argv = telegramArgv(action.argv, ['de'], null);
  const results = ok({ results: [{ node: 'de', code: 0, status: 'ok', reason: null }] });
  const steps = [[['node', 'list'], ok([{ name: 'de' }, { name: 'nl' }])], [argv, err('locked')], [argv, results]];
  const { ctx, record } = assignCtx(steps, [{ nodes: ['de'] }, { nodes: ['de'] }]);
  ctx.runConfirmed = (_title, _question, words) => ctx.request(words);
  const shown = [];
  assert.equal(await telegramBatch(ctx, action, async (table) => shown.push(table)), true);
  assert.deepEqual(record.forms.map((form) => field(form, 'nodes').value ?? null), [null, ['de']]);
  assert.deepEqual([record.notices, shown.length, steps.length], [['failed'], 1, 0]);
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

test('telegramMenu: после открытого сеанса — after() (и при сбое терминала), отмена — без него', async () => {
  const listed = () => [[['node', 'list'], ok([{ name: 'de' }])]];
  const run = async (answer, terminal) => {
    const { ctx } = assignCtx(listed(), [answer]);
    const opened = [];
    ctx.terminal = async (argv) => { opened.push(argv); return terminal(); };
    let after = 0;
    let thrown = null;
    try { await telegramMenu(ctx, async () => { after += 1; }); } catch (error) { thrown = error; }
    return { opened, after, thrown };
  };
  let result = await run({ node: 'de' }, () => ok());
  assert.deepEqual([result.opened.length, result.after, result.thrown], [1, 1, null]);
  result = await run({ node: 'de' }, () => { throw new Error('обрыв'); });
  assert.deepEqual([result.opened.length, result.after, result.thrown.message], [1, 1, 'обрыв']);
  result = await run(null, () => ok());
  assert.deepEqual([result.opened.length, result.after], [0, 0]);
});
