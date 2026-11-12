// Тесты модели экранов «Подключения», «AmneziaWG», «Telegram Proxy»
// (эталон — `#[cfg(test)]` в `remote-control/tui/src/nodes.rs`).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  EMPTY, nodeText, syncedNode, syncProblem, syncData, overviewNodes, overviewLines,
  connectionView, assignGroupsTitle, assignArgv, assignConnections, connSyncArgv, connListArgv, nodeCheckArgv,
  CONNECTION_ACTIONS, awgStatusArgv, awgSyncArgv, awgRemovePeerArgv, awgOrphansArgv, awgView,
  TELEGRAM_VIEW, TELEGRAM_BATCH, TELEGRAM_COMPONENTS, TELEGRAM_STATUS_ARGV, telegramArgv, telegramResults,
} from '../assets/js/screens/nodeops-model.js';

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

test('обзор подключений: строки и тоны как в TUI', () => {
  const sync = syncData(err('partial', { nodes: [
    { name: 'a', status: 'synced', discovered: ['p1', 'p2'], removed: [], groups: [], error: null },
    { name: 'b', status: 'unreachable', discovered: null, removed: [], groups: [], error: 'remote_failed' }] }));
  const list = [
    { node: 'a', groups: [{ name: 'PC', proxies: ['p1'] }, { name: 'ALL', proxies: ['p1', 'p2'] }] },
    { node: 'b', groups: [{ name: 'PC', proxies: ['x'] }] }, { node: 'c', groups: [{ name: 'X', proxies: ['p'] }] }];
  const lines = overviewLines(overviewNodes(list, sync));
  assert.deepEqual(lines.map((l) => l.tone), [null, 'warn', 'ok', 'warn', null, 'dim']);
  assert.deepEqual(lines.map((l) => l.text), ['a', '  PC: 1/2', '  ALL: 2/2', 'b  недоступна', 'c', '  X: 1/?']);
  assert.deepEqual(overviewLines(overviewNodes([], null)), [{ text: 'Нет нод', tone: 'dim' }]);
  // Ноль обнаруженных — DIM, не GREEN.
  const zero = overviewNodes([{ node: 'z', groups: [{ name: 'G', proxies: [] }] }], { nodes: [{ name: 'z', status: 'synced', discovered: [] }] });
  assert.deepEqual(zero[0].groups, [{ text: '  G: 0/0', tone: 'dim' }]);
});

test('карточка подключений ноды', () => {
  const listed = [{ node: 'n', groups: [{ name: 'old', proxies: ['p1'] }, { name: 'x', proxies: ['p1'] }] }];
  const view = connectionView(listed, { name: 'n', status: 'synced', discovered: ['p1', 'p2'] }, 'n');
  assert.deepEqual(view.proxies, ['p1', 'p2']);
  assert.deepEqual(view.assigned, [['old', 'x'], []]);
  assert.deepEqual(view.lines, [{ text: 'p1  [old, x]', tone: null }, { text: 'p2  []', tone: null }]);
  const problem = connectionView(listed, { name: 'n', status: 'unreachable', discovered: null }, 'n');
  assert.deepEqual(problem.lines, [{ text: 'Нода недоступна', tone: 'warn' }]);
  const empty = connectionView([], null, 'n');
  assert.deepEqual(empty.lines, [{ text: 'Подключения не найдены', tone: 'dim' }]);
  assert.deepEqual(CONNECTION_ACTIONS.map((a) => a.tone), ['change', 'change', 'change']);
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

/** Поддельный `ctx` назначения: `steps` — `[argv, reply]`, `answers` — ответы `toggle`. */
function assignCtx(steps, answers) {
  const record = { calls: [], toggles: [], notices: [] };
  const ctx = {
    async request(argv) {
      assert.ok(steps.length > 0, `лишний запрос ${argv.join(' ')}`);
      const [expected, reply] = steps.shift();
      assert.deepEqual(argv, expected);
      record.calls.push(argv);
      return reply;
    },
    call: (...words) => ctx.request(words),
    async toggle(props) { record.toggles.push(props); return answers.shift(); },
    notify: (level, text) => record.notices.push(text),
    failed: () => record.notices.push('failed'),
    isFailure: (reply) => !reply.ok,
  };
  return { ctx, record };
}

test('assignConnections: выбор подключений, затем групп (как assign_connections)', async () => {
  const steps = [[['group', 'list'], ok([{ name: 'g1' }, { name: 'g2' }])], [assignArgv('n', ['g2'], ['p2']), ok()]];
  const { ctx, record } = assignCtx(steps, [['p2'], ['g2']]);
  await assignConnections(ctx, 'n', ['p1', 'p2'], [['g1'], []]);
  assert.deepEqual(record.toggles.map((t) => [t.title, t.selected]), [['Подключения для групп', ['p1']], ['Группы для подключений', []]]);
  assert.equal(steps.length, 0);
});

test('assignConnections: без подключений сразу выбор групп и снятие назначения', async () => {
  const steps = [[['group', 'list'], ok([{ name: 'old' }])], [['conn', 'set', '--name', 'n', '--group', 'old'], ok()]];
  const { ctx, record } = assignCtx(steps, [['old']]);
  await assignConnections(ctx, 'n', [], []);
  assert.deepEqual(record.toggles.map((t) => t.title), ['Группы: снять назначение подключений']);
  assert.equal(steps.length, 0);
});

test('assignConnections: отмена выбора и пустой выбор групп ничего не меняют', async () => {
  let { ctx, record } = assignCtx([], [null]);
  await assignConnections(ctx, 'n', ['p1'], [[]]);
  assert.deepEqual(record.calls, []);
  ({ ctx, record } = assignCtx([[['group', 'list'], ok([{ name: 'g' }])]], [[]]));
  await assignConnections(ctx, 'n', [], []);
  assert.deepEqual(record.notices, ['Ничего не выбрано.']);
});

test('AmneziaWG: строки, удаляемые и действия', () => {
  assert.deepEqual(awgStatusArgv('n'), ['awg', 'status', '--name', 'n']);
  assert.deepEqual(awgSyncArgv('n'), ['awg', 'sync', '--name', 'n']);
  assert.deepEqual(awgRemovePeerArgv('n', 'orphan'), ['awg', 'remove', '--name', 'n', '--peer', 'orphan']);
  assert.deepEqual(awgOrphansArgv('n'), ['awg', 'remove', '--name', 'n', '--orphans']);
  const view = awgView({ installed: true, peers: [{ name: 'used', status: 'used' }, { name: 'orphan', status: 'orphan' }, { name: 'missing', status: 'missing' }] });
  assert.deepEqual(view.lines.map((l) => l.tone), ['ok', 'warn', 'dim']);
  assert.deepEqual(view.lines.map((l) => l.text), ['used', 'orphan  не используется', 'missing  не создан']);
  assert.deepEqual(view.removable, ['used', 'orphan']);
  assert.deepEqual(view.actions.map((a) => [a.id, a.tone]), [['refresh', 'view'], ['sync', 'create'], ['remove', 'danger'], ['orphans', 'danger']]);
  const absent = awgView({ installed: false, peers: [] });
  assert.deepEqual(absent.lines, [{ text: 'AmneziaWG на ноде не установлен', tone: 'dim' }]);
  assert.deepEqual(absent.actions.map((a) => a.id), ['refresh']);
  assert.deepEqual(awgView({ installed: true, peers: [] }).lines, [{ text: 'Нет клиентов', tone: 'dim' }]);
});

test('Telegram: порядок, тоны и argv пакетов', () => {
  assert.deepEqual(TELEGRAM_VIEW.map((a) => a.tone), ['view', 'view']);
  assert.deepEqual(TELEGRAM_BATCH.map((a) => a.tone), ['create', 'change', 'change', 'change', 'change', 'danger', 'danger']);
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
