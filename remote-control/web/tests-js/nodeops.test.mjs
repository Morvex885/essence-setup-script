// Тесты модели обзора подключений, вкладок ноды «Подключения», «AmneziaWG» и
// экрана «Telegram Proxy» (эталон — `#[cfg(test)]` в `remote-control/tui/src/nodes.rs`).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  EMPTY, nodeText, syncedNode, syncProblem, syncData, overviewNodes, syncAll,
  connectionView, assignGroupsTitle, assignArgv, assignConnections, connSyncArgv, connListArgv, nodeCheckArgv,
  awgStatusArgv, awgSyncArgv, awgRemovePeerArgv, awgOrphansArgv, awgView,
  TELEGRAM_BATCH, TELEGRAM_COMPONENTS, TELEGRAM_STATUS_ARGV, telegramArgv, telegramResults,
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

test('подключения ноды: группы подключений и проблема синхронизации', () => {
  const listed = [{ node: 'n', groups: [{ name: 'old', proxies: ['p1'] }, { name: 'x', proxies: ['p1'] }] }];
  const view = connectionView(listed, { name: 'n', status: 'synced', discovered: ['p1', 'p2'] }, 'n');
  assert.deepEqual(view.proxies, ['p1', 'p2']);
  assert.deepEqual(view.assigned, [['old', 'x'], []]);
  assert.deepEqual(view.table, [{ proxy: 'p1', groups: ['old', 'x'] }, { proxy: 'p2', groups: [] }]);
  assert.equal(view.problem, null);
  const problem = connectionView(listed, { name: 'n', status: 'unreachable', discovered: null }, 'n');
  assert.equal(problem.problem, 'недоступна');
  assert.deepEqual(problem.table, []);
  const empty = connectionView([], null, 'n');
  assert.deepEqual([empty.problem, empty.table], [null, []]);
});

test('argv подключений', () => {
  assert.deepEqual(connSyncArgv(), ['conn', 'sync']);
  assert.deepEqual(connSyncArgv('a'), ['conn', 'sync', '--name', 'a']);
  assert.deepEqual(connListArgv(), ['conn', 'list']);
  assert.deepEqual(connListArgv('n'), ['conn', 'list', '--name', 'n']);
  assert.deepEqual(nodeCheckArgv('n'), ['node', 'check', '--name', 'n']);
  assert.deepEqual(assignArgv('n', ['g2'], ['p2']), ['conn', 'set', '--name', 'n', '--group', 'g2', '--proxy', 'p2']);
  assert.deepEqual(assignArgv('n', ['old'], []), ['conn', 'set', '--name', 'n', '--group', 'old']);
  assert.equal(assignGroupsTitle([]), 'Группы: снять назначение подключений');
  assert.equal(assignGroupsTitle(['p1']), 'Группы для подключений');
});

/** Поддельный `ctx` назначения: `steps` — `[argv, reply]`, `answers` — ответы `form`. */
function assignCtx(steps, answers) {
  const record = { calls: [], forms: [], notices: [] };
  const ctx = {
    async request(argv) {
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

test('assignConnections: одна форма — подключения (назначенные отмечены) и группы', async () => {
  const steps = [[['group', 'list'], ok([{ name: 'g1' }, { name: 'g2' }])], [assignArgv('n', ['g2'], ['p2']), ok()]];
  const { ctx, record } = assignCtx(steps, [{ proxies: ['p2'], groups: ['g2'] }]);
  await assignConnections(ctx, 'n', ['p1', 'p2'], [['g1'], []]);
  assert.equal(record.forms.length, 1);
  const [form] = record.forms;
  assert.deepEqual(field(form, 'proxies').options.map((o) => o.value), ['p1', 'p2']);
  assert.deepEqual(field(form, 'proxies').value, ['p1']);
  assert.equal(field(form, 'groups').type, 'multi');
  assert.ok(field(form, 'groups').required);
  assert.deepEqual(field(form, 'groups').options.map((o) => o.value), ['g1', 'g2']);
  assert.ok(!field(form, 'groups').value || field(form, 'groups').value.length === 0);
  assert.equal(steps.length, 0);
  assert.deepEqual(record.notices, []);
});

test('assignConnections: без подключений поля подключений нет, назначение снимается', async () => {
  const steps = [[['group', 'list'], ok([{ name: 'old' }])], [['conn', 'set', '--name', 'n', '--group', 'old'], ok()]];
  const { ctx, record } = assignCtx(steps, [{ groups: ['old'] }]);
  await assignConnections(ctx, 'n', [], []);
  assert.equal(field(record.forms[0], 'proxies'), undefined);
  assert.equal(steps.length, 0);
});

test('assignConnections: отмена ничего не меняет, сбои — failed', async () => {
  let { ctx, record } = assignCtx([[['group', 'list'], ok([{ name: 'g' }])]], [null]);
  await assignConnections(ctx, 'n', ['p1'], [[]]);
  assert.deepEqual(record.calls, [['group', 'list']]);
  assert.deepEqual(record.notices, []);
  ({ ctx, record } = assignCtx([[['group', 'list'], err('locked')]], []));
  await assignConnections(ctx, 'n', ['p1'], [[]]);
  assert.deepEqual([record.forms.length, record.notices], [0, ['failed']]);
  ({ ctx, record } = assignCtx([[['group', 'list'], ok([{ name: 'g' }])], [assignArgv('n', ['g'], []), err('locked')]], [{ proxies: [], groups: ['g'] }]));
  await assignConnections(ctx, 'n', ['p1'], [['g']]);
  assert.deepEqual(record.notices, ['failed']);
});

test('AmneziaWG: argv, состояния клиентов и признаки действий', () => {
  assert.deepEqual(awgStatusArgv('n'), ['awg', 'status', '--name', 'n']);
  assert.deepEqual(awgSyncArgv('n'), ['awg', 'sync', '--name', 'n']);
  assert.deepEqual(awgRemovePeerArgv('n', 'orphan'), ['awg', 'remove', '--name', 'n', '--peer', 'orphan']);
  assert.deepEqual(awgOrphansArgv('n'), ['awg', 'remove', '--name', 'n', '--orphans']);
  const view = awgView({ installed: true, peers: [{ name: 'used', status: 'used' }, { name: 'orphan', status: 'orphan' }, { name: 'missing', status: 'missing' }] });
  assert.deepEqual(view.table.map((r) => [r.name, r.tone, r.removable]), [['used', 'ok', true], ['orphan', 'warn', true], ['missing', 'neutral', false]]);
  assert.deepEqual([view.installed, view.missing, view.orphans], [true, true, true]);
  const clean = awgView({ installed: true, peers: [{ name: 'used', status: 'used' }] });
  assert.deepEqual([clean.missing, clean.orphans], [false, false]);
  const absent = awgView({ installed: false, peers: [{ name: 'x', status: 'orphan' }] });
  assert.deepEqual([absent.installed, absent.table, absent.orphans], [false, [], false]);
  assert.deepEqual(awgView({ installed: true, peers: [] }).table, []);
});

test('Telegram: порядок, опасные действия и argv пакетов', () => {
  assert.ok(TELEGRAM_BATCH.every((a) => a.title && Array.isArray(a.argv)));
  assert.deepEqual(TELEGRAM_BATCH.filter((a) => a.danger).map((a) => a.id), ['remove', 'remove-all']);
  const verbs = TELEGRAM_BATCH.map((a) => a.argv[1]);
  assert.deepEqual(verbs, ['install', 'refresh-ip', 'web-update', 'web-restart', 'backend-restart', 'remove', 'remove-all']);
  for (const action of TELEGRAM_BATCH.filter((a) => !a.component)) {
    assert.deepEqual(telegramArgv(action.argv, ['n1', 'n3']), ['telegram', action.argv[1], '--name', 'n1', '--name', 'n3']);
  }
  assert.deepEqual(TELEGRAM_COMPONENTS.map((c) => c.value), ['web', 'mtproto']);
  assert.deepEqual(telegramArgv(['telegram', 'remove'], ['n2'], 'mtproto'), ['telegram', 'remove', '--component', 'mtproto', '--name', 'n2']);
  assert.deepEqual(TELEGRAM_STATUS_ARGV, ['telegram', 'status', '--all']);
});

test('Telegram: таблица результатов', () => {
  const results = { results: [
    { node: 'a', code: 0, status: 'ok', reason: null }, { node: 'b', code: 3, status: 'not_installed', reason: 'не установлен' },
    { node: 'c', code: 4, status: 'partial', reason: 'x' }, { node: 'd', code: 1, status: 'error', reason: 'offline' }] };
  const table = telegramResults(err('partial', results));
  assert.deepEqual(table.map((r) => r.tone), ['ok', 'warn', 'warn', 'error']);
  assert.deepEqual(table.map((r) => `${r.node}  ${r.status}  ${r.reason}`),
    ['a  готово  ', 'b  не установлено  не установлен', 'c  частично  x', 'd  ошибка  offline']);
  assert.equal(telegramResults(ok(results)).length, 4);
  assert.equal(telegramResults(ok({ results: [] })), null);
  assert.equal(telegramResults(err('invalid')), null);
});
