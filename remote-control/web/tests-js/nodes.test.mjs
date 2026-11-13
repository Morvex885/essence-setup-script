import test from 'node:test';
import assert from 'node:assert/strict';
import * as model from '../assets/js/screens/nodes-model.js';
import { isFailure } from '../assets/js/flows.js';

// Фикстура `nodes.rs::tests::node`.
const node = () => ({
  name: 'n', ip: '192.0.2.1', port: 22, user: 'root', auth: 'password', tag: 'tag', identity: null,
  password: 'ok', issues: [], aliases: {}, groups: ['g'], clients: 1, delete_options: [
    { scope: 'local', revoke_key: false, label: 'local' }, { scope: 'server', revoke_key: false, label: 'server' },
    { scope: 'server', revoke_key: true, label: 'server+key' },
  ],
});

test('nodeLabel и состояние нод в списке (frames_keep_list_sections_colours)', () => {
  const problem = { name: 'problem', ip: '192.0.2.2', port: 22, auth: 'password', password: 'missing', issues: ['missing_identity'] };
  const deferred = { name: 'deferred', ip: '192.0.2.3', port: 22, auth: 'key', password: null, issues: ['missing_identity', 'missing_host_key'] };
  assert.equal(model.nodeLabel(node()), 'n  192.0.2.1:22');
  assert.equal(model.nodeStatus(node()).tone, 'ok');
  assert.equal(model.nodeStatus(problem).tone, 'warn');
  assert.equal(model.nodeStatus(deferred).tone, 'warn');
});

test('карточка: способ входа и пароль SSH только при входе по паролю', () => {
  assert.equal(model.authLabel(node()), 'по паролю');
  assert.equal(model.authLabel({ ...node(), auth: 'key' }), 'по ключу');
  assert.equal(model.passwordStatus(node()).tone, 'ok');
  assert.equal(model.passwordStatus({ ...node(), password: 'missing' }).tone, 'warn');
  assert.equal(model.passwordStatus({ ...node(), password: 'error' }).tone, 'warn');
  assert.equal(model.passwordStatus({ ...node(), auth: 'key', password: null }), null);
});

test('терминальные команды', () => {
  assert.deepEqual(model.interactiveArgv('n', false), ['node', 'shell', '--name', 'n']);
  assert.deepEqual(model.interactiveArgv('n', true), ['telegram', 'menu', '--name', 'n']);
});

test('предложение загрузки скриптов по состоянию', () => {
  for (const [state, condition] of [['missing', 'скрипты отсутствуют'], ['outdated', 'скрипты устарели']]) {
    const offer = model.uploadOffer('n', state);
    assert.equal(offer.force, false);
    assert.equal(offer.condition, `Состояние: ${condition}`);
    assert.equal(offer.label, 'Загрузить скрипты');
    assert.deepEqual(offer.argv, ['node', 'upload-scripts', '--name', 'n']);
  }
  for (const [state, condition] of [['broken', 'установка повреждена'], ['unknown', 'версия скриптов неизвестна']]) {
    const offer = model.uploadOffer('n', state);
    assert.equal(offer.condition, `Состояние: ${condition}`);
    assert.equal(offer.label, 'Загрузить скрипты принудительно');
    assert.deepEqual(offer.argv, ['node', 'upload-scripts', '--name', 'n', '--force']);
  }
  assert.equal(model.uploadOffer('n', 'missing').title, 'Скрипты на ноде: n');
});

test('удаление: варианты из delete_options и --revoke-key', () => {
  const options = model.deleteOptions(node());
  assert.deepEqual(options.map((o) => o.value), [0, 1, 2]);
  assert.deepEqual(model.deleteArgv('n', node().delete_options[2]), ['node', 'delete', '--name', 'n', '--scope', 'server', '--revoke-key']);
  assert.deepEqual(model.deleteArgv('n', node().delete_options[0]), ['node', 'delete', '--name', 'n', '--scope', 'local']);
  assert.deepEqual(model.deleteOptions({ delete_options: [] }), []);
});

test('усиление SSH: порт и повторный вопрос', () => {
  assert.deepEqual(model.hardenArgv('n', ''), ['node', 'harden', '--name', 'n']);
  assert.deepEqual(model.hardenArgv('n', '2222'), ['node', 'harden', '--name', 'n', '--port', '2222']);
  const fail = (c) => ({ ok: false, error: { code: c } });
  assert.ok(model.hardenAsksPort(model.hardenArgv('n', '2222'), fail('port_in_use')));
  assert.ok(model.hardenAsksPort(model.hardenArgv('n', 'abc'), fail('invalid')));
  assert.ok(model.hardenAsksPort(model.hardenArgv('n', ''), fail('port_in_use')));
  // Без явного порта `invalid` — вердикт ядра, а не вопрос порта.
  assert.ok(!model.hardenAsksPort(model.hardenArgv('n', ''), fail('invalid')));
  assert.ok(!model.hardenAsksPort(model.hardenArgv('n', ''), { ok: true, data: {} }));
});

const addWords = (auth, extra = []) => ['node', 'add', '--name', 'vps-1', '--ip', '192.0.2.1', '--port', '22', '--user', 'root', '--auth', auth, '--tag', 'tag', ...extra];

test('добавление: умолчания v1, пароль только в secrets', () => {
  const key = model.addNodeArgv({ name: '', ip: '192.0.2.1', port: '', user: '', auth: 'key', password: '', tag: 'tag' });
  assert.deepEqual(key, { argv: addWords('key'), password: null });
  const pw = model.addNodeArgv({ name: '', ip: '192.0.2.1', port: '', user: '', auth: 'password', password: 'top-secret', tag: 'tag' });
  assert.deepEqual(pw.argv, addWords('password'));
  assert.equal(pw.password, 'top-secret');
  assert.ok(!pw.argv.includes('top-secret'));
});

test('добавление: проверки IP, порта, пароля и тега', () => {
  const base = { name: '', ip: '192.0.2.1', port: '', user: '', auth: 'key', password: '', tag: 'tag' };
  assert.ok(model.addNodeArgv({ ...base, ip: '' }).warning);
  for (const port of ['0', '70000', 'x', '-1', '1.5']) {
    assert.ok(model.addNodeArgv({ ...base, port }).warning, port);
    assert.equal(model.portError(port), model.PORT_INVALID, port);
  }
  assert.equal(model.portError(''), null);
  assert.equal(model.portError('22'), null);
  assert.deepEqual(model.addNodeArgv({ ...base, port: '65535' }).argv[7], '65535');
  assert.ok(model.addNodeArgv({ ...base, auth: 'password' }).warning);
  assert.ok(model.addNodeArgv({ ...base, tag: '' }).warning);
});

test('форма добавления: порт проверяется полем, пароль — только при входе по паролю, прежний ввод без пароля', () => {
  const fields = model.addFields({ ip: '192.0.2.1', port: '99999', auth: 'password', password: 'x' });
  const byName = Object.fromEntries(fields.map((field) => [field.name, field]));
  assert.equal(byName.port.validate('99999'), model.PORT_INVALID);
  assert.equal(byName.ip.value, '192.0.2.1');
  assert.equal(byName.password.value, undefined);
  assert.equal(byName.password.when({ auth: 'key' }), false);
  assert.equal(byName.password.when({ auth: 'password' }), true);
});

/**
 * Поддельный `ctx`: `steps` — `[argv, reply]` по порядку (запросы и планы),
 * `answers` — ответы диалогов по порядку. Записывает диалоги, секреты,
 * уведомления и итоги сбоев.
 */
function scripted(steps, answers) {
  const queue = [...steps];
  const replies = [...answers];
  const record = { dialogs: [], secrets: [], notices: [], failed: 0 };
  const dialog = (kind) => async (props) => {
    record.dialogs.push({ kind, ...props });
    assert.ok(replies.length > 0, `нет ответа для ${kind}: ${props.title}`);
    return replies.shift();
  };
  const ctx = {
    async request(argv, options = {}) {
      assert.ok(queue.length > 0, `лишний запрос ${argv.join(' ')}`);
      const [expected, reply] = queue.shift();
      assert.deepEqual(argv, expected);
      record.secrets.push(options.secrets ? { ...options.secrets } : null);
      return reply;
    },
    call: (...words) => ctx.request(words),
    runConfirmed: (_title, _question, argv, options) => ctx.request(argv, options),
    form: dialog('form'), confirm: dialog('confirm'), choose: dialog('choose'), askSecret: dialog('secret'),
    notify: (level, text) => record.notices.push([level, text]),
    failed: () => { record.failed += 1; },
    isFailure,
  };
  return { ctx, record, done: () => assert.equal(queue.length + replies.length, 0, 'не все шаги сценария пройдены') };
}

const ok = (data = null) => ({ ok: true, data });
const fail = (code, extra = {}) => ({ ok: false, error: { code, message: '', ...extra } });
const keyForm = { name: '', ip: '192.0.2.1', port: '', user: '', tag: 'tag', auth: 'key' };
const keyAttempt = addWords('key', ['--accept-new-host-key']);

test('добавление: успех открывает ноду под именем из ответа ядра', async () => {
  const s = scripted([[keyAttempt, ok({ name: 'vps-1', needs_setup: false })]], [keyForm]);
  const opened = [];
  assert.equal(await model.addNodeFlow(s.ctx, (name) => opened.push(name)), true);
  assert.deepEqual(opened, ['vps-1']);
  s.done();
});

test('добавление: сбой возвращает форму с прежним вводом, пароль не сохраняется', async () => {
  const pwForm = { ...keyForm, auth: 'password', password: 'top-secret' };
  const s = scripted([[addWords('password', ['--accept-new-host-key']), fail('remote_failed')]], [pwForm, false, null]);
  const opened = [];
  assert.equal(await model.addNodeFlow(s.ctx, (name) => opened.push(name)), false);
  assert.deepEqual(s.record.dialogs.map((d) => d.kind), ['form', 'confirm', 'form']);
  const again = Object.fromEntries(s.record.dialogs[2].fields.map((field) => [field.name, field.value]));
  assert.equal(again.ip, '192.0.2.1');
  assert.equal(again.auth, 'password');
  assert.equal(again.password, undefined);
  assert.deepEqual(s.record.secrets, [{ password: 'top-secret' }]);
  assert.deepEqual(opened, []);
  s.done();
});

test('добавление: сбой ядра — итог сбоя и форма снова; отмена выбора — выход без формы', async () => {
  let s = scripted([[keyAttempt, fail('locked')]], [keyForm, null]);
  assert.equal(await model.addNodeFlow(s.ctx, () => assert.fail('переход')), false);
  assert.equal(s.record.failed, 1);
  assert.deepEqual(s.record.dialogs.map((d) => d.kind), ['form', 'form']);
  s.done();
  s = scripted([[keyAttempt, fail('onboarding_failed')]], [keyForm, null]);
  assert.equal(await model.addNodeFlow(s.ctx, () => assert.fail('переход')), false);
  assert.deepEqual(s.record.dialogs.map((d) => d.kind), ['form', 'choose']);
  s.done();
});

test('добавление: изменённый ключ — повтор под планом с --replace-host-key, отложенная настройка', async () => {
  const s = scripted([
    [keyAttempt, fail('host_key_changed', { fingerprints: ['SHA256:new'] })],
    [addWords('key', ['--replace-host-key', 'SHA256:new']), fail('onboarding_failed')],
    [addWords('key', ['--defer-ssh-setup']), ok({ name: 'vps-1', needs_setup: true })],
  ], [keyForm, 'defer']);
  const opened = [];
  assert.equal(await model.addNodeFlow(s.ctx, (name) => opened.push(name)), true);
  assert.deepEqual(opened, ['vps-1']);
  assert.equal(s.record.notices[0][0], 'warn');
  s.done();
});

test('изменение ноды: rename, затем tag под новым именем; сбой rename останавливает', async () => {
  let s = scripted([
    [['node', 'rename', '--name', 'n', '--new-name', 'm'], ok({ name: 'm' })],
    [['node', 'tag', '--name', 'm', '--tag', 'new'], ok()],
  ], [{ name: 'm', tag: 'new' }]);
  assert.equal(await model.editNode(s.ctx, node()), 'm');
  s.done();
  s = scripted([[['node', 'rename', '--name', 'n', '--new-name', 'm'], fail('conflict')]], [{ name: 'm', tag: 'new' }]);
  assert.equal(await model.editNode(s.ctx, node()), null);
  assert.equal(s.record.failed, 1);
  s.done();
  s = scripted([[['node', 'tag', '--name', 'n', '--tag', 'x'], ok()]], [{ name: 'n', tag: 'x' }]);
  assert.equal(await model.editNode(s.ctx, node()), 'n');
  s.done();
  s = scripted([], [null]);
  assert.equal(await model.editNode(s.ctx, node()), null);
  s.done();
});

test('добавление: флаги ключа сервера и отложенная настройка', () => {
  const base = addWords('key');
  assert.deepEqual(model.addAttemptArgv(base, model.ACCEPT_HOST_KEY, false), addWords('key', ['--accept-new-host-key']));
  assert.deepEqual(model.addAttemptArgv(base, ['--replace-host-key', 'SHA256:new'], false), addWords('key', ['--replace-host-key', 'SHA256:new']));
  assert.deepEqual(model.addAttemptArgv(base, ['--replace-host-key', 'SHA256:new'], true), addWords('key', ['--defer-ssh-setup']));
  assert.deepEqual(base, addWords('key'));
});

test('псевдонимы: --set, --unset и «Изменений нет»', () => {
  const entries = [{ proxy: 'p1', alias: 'old' }, { proxy: 'p2', alias: null }, { proxy: 'p3', alias: 'gone' }];
  assert.deepEqual(model.aliasArgv('n', entries, ['new', '', '-']), ['node', 'aliases', '--name', 'n', '--set', 'p1=new', '--unset', 'p3']);
  const two = entries.slice(0, 2);
  assert.equal(model.aliasArgv('n', two, ['old', '-']), null);
  assert.deepEqual(model.aliasArgv('n', two, ['', 'Fast']), ['node', 'aliases', '--name', 'n', '--set', 'p2=Fast']);
});

test('псевдонимы из формы: без изменений → пусто, очищенный → -, иначе новое значение', () => {
  const entries = [{ proxy: 'p1', alias: 'old' }, { proxy: 'p2', alias: null }, { proxy: 'p3', alias: 'gone' }, { proxy: 'p4', alias: 'x' }];
  const values = model.aliasValues(entries, { a0: 'old', a1: '', a2: '', a3: 'y' });
  assert.deepEqual(values, ['', '', '-', 'y']);
  assert.deepEqual(model.aliasArgv('n', entries, values), ['node', 'aliases', '--name', 'n', '--set', 'p4=y', '--unset', 'p3']);
  assert.deepEqual(model.aliasValues(entries.slice(0, 2), { a0: 'old', a1: 'Fast' }), ['', 'Fast']);
  assert.equal(model.aliasArgv('n', entries, model.aliasValues(entries, { a0: 'old', a1: '', a2: 'gone', a3: 'x' })), null);
});

test('усиление SSH: порт проверяется полем формы, пусто — подобрать свободный', async () => {
  const s = scripted([], [null]);
  await model.harden(s.ctx, 'n');
  const [form] = s.record.dialogs;
  const port = form.fields.find((f) => f.name === 'port');
  for (const bad of ['abc', '0', '70000']) assert.ok(port.validate(bad), bad);
  for (const good of ['', '2222']) assert.equal(port.validate(good), null, good);
  s.done();
});

test('псевдонимы: чтение через nodeRequest, запись только изменённых, отмена — без записи', async () => {
  const entries = [{ proxy: 'p1', alias: 'old' }, { proxy: 'p2', alias: '' }];
  const read = [['node', 'aliases', '--name', 'n'], ok(entries)];
  const nodeCtx = (s) => ({ ...s.ctx, nodeRequest: (_name, argv) => s.ctx.request(argv) });

  const saved = scripted([read, [['node', 'aliases', '--name', 'n', '--set', 'p2=fast', '--unset', 'p1'], ok()]], [{ a0: '', a1: 'fast' }]);
  await model.editAliases(nodeCtx(saved), 'n');
  assert.deepEqual(saved.record.dialogs[0].fields.map((f) => f.value), ['old', '']);
  assert.equal(saved.record.failed, 0);
  saved.done();

  const cancelled = scripted([read], [null]);
  await model.editAliases(nodeCtx(cancelled), 'n');
  cancelled.done();

  const unchanged = scripted([read], [{ a0: 'old', a1: '' }]);
  await model.editAliases(nodeCtx(unchanged), 'n');
  assert.equal(unchanged.record.notices.length, 1);
  unchanged.done();

  const empty = scripted([[read[0], ok([])]], []);
  await model.editAliases(nodeCtx(empty), 'n');
  assert.equal(empty.record.dialogs.length, 0);
  empty.done();

  const refused = scripted([read, [['node', 'aliases', '--name', 'n', '--set', 'p2=x'], fail('remote_failed')]], [{ a0: 'old', a1: 'x' }]);
  await model.editAliases(nodeCtx(refused), 'n');
  assert.equal(refused.record.failed, 1);
  refused.done();
});
