// Модель «Каскады» (`screens/cascades-model.js`): argv `cascade add|delete`,
// варианты входа и выхода из `node list`, форма и потоки поверх поддельного `ctx`.
import test from 'node:test';
import assert from 'node:assert/strict';
import * as model from '../assets/js/screens/cascades-model.js';
import { initialValues, result, validate } from '../assets/js/form-model.js';
import { isFailure } from '../assets/js/flows.js';

const NODES = [
  { name: 'ru', profile: 'edge', proxies: ['VLESS TCP', 'Hysteria2', 'AWG', 'old-cascade'] },
  { name: 'de', profile: 'edge', proxies: ['VLESS gRPC', 'VLESS xHTTP'] },
  { name: 'awg', profile: 'wg', proxies: ['AWG'] },
  { name: 'bare', profile: null, proxies: [] },
];

/** Значения формы как после отправки: умолчания полей + `patch`. */
function submitted(fields, patch) {
  const values = { ...initialValues(fields), ...patch };
  assert.deepEqual(validate(fields, values), {});
  return result(fields, values);
}

/**
 * Поддельный `ctx`: `steps` — `[argv, reply]` по порядку, `answers` — ответы
 * диалогов по порядку. Записывает диалоги, входы запросов и сбои.
 */
function scripted(steps, answers) {
  const queue = [...steps];
  const replies = [...answers];
  const record = { dialogs: [], inputs: [], notices: [], failed: 0 };
  const dialog = (kind) => async (props) => {
    record.dialogs.push({ kind, ...props });
    assert.ok(replies.length > 0, `нет ответа для ${kind}`);
    return replies.shift();
  };
  const ctx = {
    async request(argv, options = {}) {
      assert.ok(queue.length > 0, `лишний запрос ${argv.join(' ')}`);
      const [expected, reply] = queue.shift();
      assert.deepEqual(argv, expected);
      record.inputs.push(options.input || null);
      return reply;
    },
    runConfirmed: (_title, _question, argv, options) => ctx.request(argv, options),
    nodeRequest: (_name, argv, _review, options) => ctx.request(argv, options),
    form: dialog('form'), confirm: dialog('confirm'), show: dialog('show'),
    notify: (level, text) => record.notices.push([level, text]),
    failed: () => { record.failed += 1; },
    isFailure,
  };
  return { ctx, record, done: () => assert.equal(queue.length + replies.length, 0, 'не все шаги сценария пройдены') };
}

const ok = (data = null) => ({ ok: true, data });
const fail = (code) => ({ ok: false, error: { code, message: '' } });
const APPLIED = ok({ applied: [], failed: [], unchanged: [] });

test('argv: выход на ноду с флагами, выход URI — без флагов, ссылка входом file', () => {
  assert.deepEqual(model.CASCADE_LIST, ['cascade', 'list']);
  assert.deepEqual(model.cascadeDeleteArgv('c'), ['cascade', 'delete', '--name', 'c']);
  assert.deepEqual(model.cascadeAddArgv({ name: 'c', entry: 'ru', listener: 'vless-tcp', exitNode: 'de', exitProxy: 'VLESS gRPC', uri: null }),
    ['cascade', 'add', '--name', 'c', '--entry', 'ru', '--listener', 'vless-tcp', '--exit-node', 'de', '--exit-proxy', 'VLESS gRPC']);
  assert.deepEqual(model.cascadeAddArgv({ name: 'c', entry: 'ru', listener: 'hysteria2', exitNode: null, exitProxy: null, uri: 'vless://x' }),
    ['cascade', 'add', '--name', 'c', '--entry', 'ru', '--listener', 'hysteria2']);
  assert.deepEqual(model.cascadeInput('vless://x'), { file: 'vless://x' });
});

test('варианты: входы — ноды с профилем и включёнными слушателями, только их слушатели', () => {
  assert.deepEqual(model.entryNodes(NODES).map((n) => n.name), ['ru', 'de']);
  assert.deepEqual(model.exitNodes(NODES).map((n) => n.name), ['ru', 'de']);
  assert.deepEqual(model.listenerOptions(NODES[0]).map((o) => o.value), ['vless-tcp', 'hysteria2']);
  assert.deepEqual(model.listenerOptions(NODES[1]).map((o) => o.value), ['vless-xhttp', 'vless-grpc']);
  assert.deepEqual(model.exitProxyOptions(NODES[1]).map((o) => o.value), ['VLESS xHTTP', 'VLESS gRPC']);
  assert.deepEqual(model.exitProxyOptions(NODES[2]), []);
  for (const listener of model.LISTENERS) assert.equal(model.listenerLabel(listener.value), listener.proxy);
});

test('список и ноды каскада: вход и управляемый выход, URI — только вход', () => {
  const rows = model.cascadeRows({ cascades: [
    { name: 'a', entry: 'ru', listener: 'vless-tcp', exit: { node: 'de', proxy: 'VLESS gRPC' } },
    { name: 'b', entry: 'de', listener: 'vless-grpc', exit: { uri: true } },
    null,
  ] });
  assert.deepEqual(rows.map((row) => row.name), ['a', 'b']);
  assert.deepEqual(model.cascadeNodes(rows[0]), ['ru', 'de']);
  assert.deepEqual(model.cascadeNodes(rows[1]), ['de']);
  assert.ok(model.exitLabel(rows[0].exit).includes('de'));
  assert.notEqual(model.exitLabel(rows[0].exit), model.exitLabel(rows[1].exit));
  assert.deepEqual(model.cascadeRows(null), []);
});

test('форма: слушатель и подключение выхода — по выбранным нодам, выход на ту же ноду и чужой URI отклоняются', () => {
  const fields = model.cascadeFields(NODES);
  const toDe = submitted(fields, { name: ' c ', entry: 'ru', listener_0: 'hysteria2', exit: model.EXIT_NODE, exit_node: 'de', exit_proxy_1: 'VLESS xHTTP' });
  assert.deepEqual(Object.keys(toDe).sort(), ['entry', 'exit', 'exit_node', 'exit_proxy_1', 'listener_0', 'name']);
  assert.deepEqual(model.cascadeChoice(toDe, NODES),
    { name: 'c', entry: 'ru', listener: 'hysteria2', exitNode: 'de', exitProxy: 'VLESS xHTTP', uri: null });

  const uri = submitted(fields, { name: 'c', entry: 'de', exit: model.EXIT_URI, uri: ' hysteria2://pw@host:443 ' });
  assert.equal('exit_node' in uri, false);
  assert.deepEqual(model.cascadeChoice(uri, NODES),
    { name: 'c', entry: 'de', listener: 'vless-xhttp', exitNode: null, exitProxy: null, uri: 'hysteria2://pw@host:443' });

  const same = { ...initialValues(fields), name: 'c', entry: 'ru', exit: model.EXIT_NODE, exit_node: 'ru' };
  assert.deepEqual(Object.keys(validate(fields, same)), ['exit_node']);
  const bad = { ...initialValues(fields), name: 'c', entry: 'ru', exit: model.EXIT_URI, uri: 'ss://x' };
  assert.deepEqual(Object.keys(validate(fields, bad)), ['uri']);
  assert.equal(model.uriError('vless://uuid@host:443?security=reality'), null);

  // Единственная нода выхода — сама нода входа: сразу URI.
  const only = model.cascadeFields([NODES[0], { name: 'x', profile: 'p', proxies: ['AWG'] }]);
  assert.equal(initialValues(only).exit, model.EXIT_URI);
});

test('добавление: выход на ноду, затем сразу node apply на входной и выходной ноде под планом ядра', async () => {
  const added = { name: 'c', entry: 'ru', listener: 'vless-tcp', exit: { node: 'de', proxy: 'VLESS gRPC' } };
  const s = scripted([
    [['node', 'list'], ok(NODES)],
    [['cascade', 'add', '--name', 'c', '--entry', 'ru', '--listener', 'vless-tcp', '--exit-node', 'de', '--exit-proxy', 'VLESS gRPC'], ok(added)],
    [['node', 'apply', '--name', 'ru', '--name', 'de'], APPLIED],
  ], [{ name: 'c', entry: 'ru', listener_0: 'vless-tcp', exit: 'node', exit_node: 'de', exit_proxy_1: 'VLESS gRPC' }, undefined]);
  assert.equal(await model.addCascadeFlow(s.ctx), true);
  // Своего вопроса перед node apply нет: единственное подтверждение — план ядра.
  assert.deepEqual(s.record.dialogs.map((d) => d.kind), ['form', 'show']);
  assert.deepEqual(s.record.inputs, [null, null, null]);
  s.done();
});

test('добавление: URI входом file, сбой ядра — форма с прежним вводом, отказ от плана применения', async () => {
  const argv = ['cascade', 'add', '--name', 'c', '--entry', 'de', '--listener', 'vless-grpc'];
  const values = { name: 'c', entry: 'de', listener_1: 'vless-grpc', exit: 'uri', uri: 'vless://u@h:443' };
  const s = scripted([
    [['node', 'list'], ok(NODES)],
    [argv, fail('invalid')],
    [argv, ok({ name: 'c', entry: 'de', listener: 'vless-grpc', exit: { uri: true } })],
    [['node', 'apply', '--name', 'de'], fail('confirmation_required')],
  ], [values, values]);
  assert.equal(await model.addCascadeFlow(s.ctx), true);
  assert.equal(s.record.failed, 1);
  assert.deepEqual(s.record.inputs.slice(1, 3), [{ file: 'vless://u@h:443' }, { file: 'vless://u@h:443' }]);
  const retry = s.record.dialogs[1];
  assert.equal(retry.fields.find((f) => f.name === 'name').value, 'c');
  assert.equal(retry.fields.find((f) => f.name === 'exit').value, 'uri');
  assert.deepEqual(s.record.dialogs.map((d) => d.kind), ['form', 'form']);
  s.done();
});

test('добавление: без нод входа — предупреждение без формы, отмена формы — без команды', async () => {
  const none = scripted([[['node', 'list'], ok([NODES[2], NODES[3]])]], []);
  assert.equal(await model.addCascadeFlow(none.ctx), false);
  assert.equal(none.record.notices[0][0], 'warn');
  none.done();
  const cancelled = scripted([[['node', 'list'], ok(NODES)]], [null]);
  assert.equal(await model.addCascadeFlow(cancelled.ctx), false);
  cancelled.done();
  const unread = scripted([[['node', 'list'], fail('locked')]], []);
  assert.equal(await model.addCascadeFlow(unread.ctx), false);
  assert.equal(unread.record.failed, 1);
  unread.done();
});

test('удаление: по плану, затем node apply на нодах удалённого каскада из ответа; отказ от плана — не сбой', async () => {
  const row = { name: 'c', entry: 'ru', listener: 'vless-tcp', exit: { node: 'de', proxy: 'VLESS gRPC' } };
  // Каскад пересоздан после чтения списка: ноды — из ответа удаления, не из строки списка.
  const deleted = { name: 'c', entry: 'fr', listener: 'vless-tcp', exit: { node: 'nl', proxy: 'VLESS gRPC' } };
  let s = scripted([
    [['cascade', 'delete', '--name', 'c'], ok(deleted)],
    [['node', 'apply', '--name', 'fr', '--name', 'nl'], APPLIED],
  ], [undefined]);
  assert.equal(await model.deleteCascade(s.ctx, row), true);
  assert.deepEqual(s.record.dialogs.map((d) => d.kind), ['show']);
  s.done();
  s = scripted([
    [['cascade', 'delete', '--name', 'c'], ok({ ...row, exit: { uri: true } })],
    [['node', 'apply', '--name', 'ru'], fail('confirmation_required')],
  ], []);
  assert.equal(await model.deleteCascade(s.ctx, row), true);
  assert.equal(s.record.failed, 0);
  s.done();
  s = scripted([[['cascade', 'delete', '--name', 'c'], fail('confirmation_required')]], []);
  assert.equal(await model.deleteCascade(s.ctx, row), false);
  assert.equal(s.record.failed, 0);
  s.done();
  s = scripted([[['cascade', 'delete', '--name', 'c'], fail('not_found')]], []);
  assert.equal(await model.deleteCascade(s.ctx, row), false);
  assert.equal(s.record.failed, 1);
  s.done();
});
