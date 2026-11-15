import test from 'node:test';
import assert from 'node:assert/strict';
import * as model from '../assets/js/screens/nodes-model.js';
import { isFailure } from '../assets/js/flows.js';
import * as apply from '../assets/js/screens/apply-model.js';
import * as profiles from '../assets/js/screens/profiles-model.js';

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
  const unread = model.nodeStatus({ ...problem, password: 'error' });
  assert.equal(unread.tone, 'error');
  assert.notEqual(unread.label, model.nodeStatus(problem).label);
});

test('карточка: способ входа и пароль SSH только при входе по паролю', () => {
  assert.equal(model.authLabel(node()), 'по паролю');
  assert.equal(model.authLabel({ ...node(), auth: 'key' }), 'по ключу');
  assert.equal(model.passwordStatus(node()).tone, 'ok');
  assert.equal(model.passwordStatus({ ...node(), password: 'missing' }).tone, 'warn');
  const unread = model.passwordStatus({ ...node(), password: 'error' });
  assert.equal(unread.tone, 'error');
  assert.notEqual(unread.label, model.passwordStatus({ ...node(), password: 'missing' }).label);
  assert.equal(model.passwordStatus({ ...node(), auth: 'key', password: null }), null);
});

test('терминальная команда — только node shell', () => {
  assert.deepEqual(model.interactiveArgv('n'), ['node', 'shell', '--name', 'n']);
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
function scripted(steps, answers, { profiles = [] } = {}) {
  const queue = [...steps];
  const replies = [...answers];
  const record = { dialogs: [], secrets: [], notices: [], failed: 0, options: [] };
  const dialog = (kind) => async (props) => {
    record.dialogs.push({ kind, ...props });
    assert.ok(replies.length > 0, `нет ответа для ${kind}: ${props.title}`);
    return replies.shift();
  };
  const ctx = {
    async request(argv, options = {}) {
      // Фоновое чтение профилей формы добавления — вне сценария.
      if (options.quiet && argv.join(' ') === 'profile list') return { ok: true, data: { profiles } };
      assert.ok(queue.length > 0, `лишний запрос ${argv.join(' ')}`);
      const [expected, reply] = queue.shift();
      assert.deepEqual(argv, expected);
      record.secrets.push(options.secrets ? { ...options.secrets } : null);
      record.options.push(options);
      return reply;
    },
    call: (...words) => ctx.request(words),
    runConfirmed: (_title, _question, argv, options) => ctx.request(argv, options),
    nodeRequest: (_name, argv, _review, options) => ctx.request(argv, options),
    form: dialog('form'), confirm: dialog('confirm'), choose: dialog('choose'), askSecret: dialog('secret'),
    ask: dialog('text'), show: dialog('show'),
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

test('усиление SSH: порт, занятый между планом и подтверждением, спрашивается снова', async () => {
  const chosen = ['node', 'harden', '--name', 'n', '--port', '2222'];
  const auto = ['node', 'harden', '--name', 'n'];
  const planned = (token) => fail('confirmation_required', { plan: ['x'], plan_token: token });
  const s = scripted([
    [chosen, planned('one')], [[...chosen, '--yes', '--plan-token', 'one'], fail('port_in_use', { port: 2222 })],
    [auto, planned('two')],
  ], [{ port: '2222' }, true, { port: '' }, false]);
  await model.harden(s.ctx, 'n');
  assert.deepEqual(s.record.dialogs.map((d) => d.kind), ['form', 'confirm', 'form', 'confirm']);
  assert.equal(s.record.failed, 0);
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

// ─── Профиль, домен, порты и применение ─────────────────────────────────────

const edge = { name: 'edge', reality_mode: 'self-steal', vless_tcp: true, vless_xhttp: { topology: 'nginx', port: null },
  vless_grpc: { port: 20000 }, hysteria2: { port: 30000, obfs: true }, amneziawg: { port: 40000, dns: '1.1.1.1' }, nodes: [] };
const sni = { name: 'sni', reality_mode: 'sni', sni_domain: 'www.example.com', vless_tcp: true, vless_xhttp: null,
  vless_grpc: null, hysteria2: null, amneziawg: null, nodes: [] };

test('добавление с профилем: --profile/--domain, затем node apply --name под планом с окном операции', async () => {
  const words = addWords('key', ['--profile', 'edge', '--domain', 'de.example.com', '--accept-new-host-key']);
  const applied = ok({ applied: ['vps-1'], failed: [], unchanged: [] });
  const s = scripted([[words, ok({ name: 'vps-1' })], [['node', 'apply', '--name', 'vps-1'], applied]],
    [{ ...keyForm, profile: 'edge', domain: 'de.example.com' }, undefined], { profiles: [edge] });
  const opened = [];
  assert.equal(await model.addNodeFlow(s.ctx, (name) => opened.push(name)), true);
  assert.deepEqual(opened, ['vps-1']);
  assert.equal(s.record.options[1].operation !== undefined, true);
  assert.deepEqual(s.record.dialogs.map((d) => d.kind), ['form', 'show']);
  s.done();
  // Без профиля — без применения.
  const plain = scripted([[keyAttempt, ok({ name: 'vps-1' })]], [{ ...keyForm, profile: '' }], { profiles: [edge] });
  assert.equal(await model.addNodeFlow(plain.ctx, () => {}), true);
  plain.done();
});

test('форма добавления: профиль только при наличии профилей, домен — когда профиль его требует', () => {
  assert.equal(model.addFields({}, []).some((f) => f.name === 'profile'), false);
  const fields = Object.fromEntries(model.addFields({}, [edge, sni]).map((f) => [f.name, f]));
  assert.deepEqual(fields.profile.options.map((o) => o.value), ['', 'edge', 'sni']);
  assert.equal(fields.domain.when({ profile: 'edge' }), true);
  assert.equal(fields.domain.when({ profile: 'sni' }), false);
  assert.equal(fields.domain.when({ profile: '' }), false);
  assert.ok(fields.domain.validate('bad_domain'));
  assert.equal(fields.domain.validate('de.example.com'), null);
});

test('argv профиля, домена и портов ноды', () => {
  assert.deepEqual(model.nodeProfileArgv('n', 'edge'), ['node', 'profile', '--name', 'n', '--profile', 'edge']);
  assert.deepEqual(model.nodeProfileArgv('n', ''), ['node', 'profile', '--name', 'n', '--profile', '']);
  assert.deepEqual(model.nodeDomainArgv('n', 'a.example.com'), ['node', 'domain', '--name', 'n', '--domain', 'a.example.com']);
  // xHTTP через nginx порта не имеет.
  assert.deepEqual(model.portProtocols(edge).map((p) => [p.key, p.port]), [['vless-grpc', '20000'], ['hysteria2', '30000'], ['amneziawg', '40000']]);
  assert.deepEqual(model.portProtocols({ ...sni, vless_xhttp: { topology: 'reality', port: 18888 } }).map((p) => p.key), ['vless-xhttp']);
  const node = { ports: { hysteria2: 31000 } };
  const changes = model.portChanges('n', node, model.portProtocols(edge), { 'vless-grpc': '', hysteria2: '', amneziawg: '41000' });
  assert.deepEqual(changes, [
    ['node', 'port', '--name', 'n', '--protocol', 'hysteria2', '--port', ''],
    ['node', 'port', '--name', 'n', '--protocol', 'amneziawg', '--port', '41000'],
  ]);
});

test('WARP ноды: строка и действие по node.warp (правило ядра), argv перерегистрации', () => {
  // Не зарегистрирован, но WARP в профиле включён — строка и перерегистрация есть;
  // у `none|free|plus` подписи есть и различаются (тексты — дело модели).
  const labels = ['none', 'free', 'plus'].map((warp) => model.warpLabel({ warp }));
  assert.ok(labels.every((label) => typeof label === 'string' && label !== ''));
  assert.equal(new Set(labels).size, labels.length);
  // WARP в профиле выключен — ни строки, ни действия.
  assert.equal(model.warpLabel({ warp: 'off' }), null);
  assert.equal(model.warpLabel({}), null);
  assert.equal(model.warpLabel(null), null);
  // Действие в меню карточки — по тому же правилу: при `off` его нет.
  assert.deepEqual(['off', 'none', 'free', 'plus'].map((warp) => model.warpReregisterOffered({ warp })), [false, true, true, true]);
  assert.equal(model.warpReregisterOffered({}), false);
  assert.deepEqual(model.warpReregisterArgv('n'), ['node', 'warp-reregister', '--name', 'n']);
});

test('перерегистрация WARP: под планом, затем сразу node apply --name под планом; отказ — без отчёта, сбой — без применения', async () => {
  let s = scripted([
    [['node', 'warp-reregister', '--name', 'n'], ok({ name: 'n' })],
    [['node', 'apply', '--name', 'n'], ok({ applied: ['n'], failed: [], unchanged: [] })],
  ], [undefined]);
  assert.equal(await model.warpReregister(s.ctx, 'n'), true);
  // Своего вопроса перед node apply нет: единственное подтверждение — план ядра.
  assert.deepEqual(s.record.dialogs.map((d) => d.kind), ['show']);
  s.done();
  s = scripted([
    [['node', 'warp-reregister', '--name', 'n'], ok({ name: 'n' })],
    [['node', 'apply', '--name', 'n'], fail('confirmation_required')],
  ], []);
  assert.equal(await model.warpReregister(s.ctx, 'n'), true);
  assert.deepEqual(s.record.dialogs, []);
  s.done();
  s = scripted([[['node', 'warp-reregister', '--name', 'n'], fail('confirmation_required')]], []);
  assert.equal(await model.warpReregister(s.ctx, 'n'), false);
  assert.deepEqual(s.record.dialogs, []);
  s.done();
});

test('порты ноды: форма по протоколам профиля, команды только для изменённых', async () => {
  const node = { name: 'n', profile: 'edge', ports: {} };
  const s = scripted([
    [['profile', 'show', '--name', 'edge'], ok(edge)],
    [['node', 'port', '--name', 'n', '--protocol', 'vless-grpc', '--port', '20001'], ok({})],
  ], [{ 'vless-grpc': '20001', hysteria2: '', amneziawg: '' }]);
  assert.equal(await model.nodePortsFlow(s.ctx, 'n', node), true);
  assert.deepEqual(s.record.dialogs[0].fields.map((f) => f.name), ['vless-grpc', 'hysteria2', 'amneziawg']);
  s.done();
  const none = scripted([], []);
  assert.equal(await model.nodePortsFlow(none.ctx, 'n', { name: 'n', profile: null }), false);
});

test('профиль и домен ноды: без изменений команды нет, после изменения — node apply --name под планом', async () => {
  const node = { name: 'n', profile: 'edge', domain: 'a.example.com' };
  const declined = [['node', 'apply', '--name', 'n'], fail('confirmation_required')];
  let s = scripted([[['profile', 'list'], ok({ profiles: [edge, sni] })], [['node', 'profile', '--name', 'n', '--profile', 'sni'], ok({})], declined],
    [{ profile: 'sni' }]);
  assert.equal(await model.nodeProfileFlow(s.ctx, 'n', node), true);
  s.done();
  s = scripted([[['profile', 'list'], ok({ profiles: [edge] })]], [{ profile: 'edge' }]);
  assert.equal(await model.nodeProfileFlow(s.ctx, 'n', node), false);
  s.done();
  s = scripted([[['node', 'domain', '--name', 'n', '--domain', ''], ok({})], declined], [{ domain: '' }]);
  assert.equal(await model.nodeDomainFlow(s.ctx, 'n', node), true);
  s.done();
  s = scripted([], [{ domain: 'a.example.com' }]);
  assert.equal(await model.nodeDomainFlow(s.ctx, 'n', node), false);
  s.done();
});

test('«Указать профиль» без профилей: предложение создать профиль, затем node profile', async () => {
  const versions = { latest: 'v1.19.20', versions: ['v1.19.20', 'v1.19.19'] };
  const form = { name: 'edge', reality: 'sni', sni_domain: 'www.example.com', protocols: ['vless-tcp'], ipv6: 'default', acme_email: '', mihomo_choice: 'v1.19.20' };
  const s = scripted([
    [['profile', 'list'], ok({ profiles: [] })], [['profile', 'mihomo-versions'], ok(versions)],
    [profiles.profileAddArgv(form), ok({ name: 'edge' })], [['node', 'profile', '--name', 'n', '--profile', 'edge'], ok({})],
  ], [true, form]);
  // Затем сразу `node apply --name n`; план здесь отклонён.
  s.ctx.nodeRequest = async (_n, argv) => { assert.deepEqual(argv, ['node', 'apply', '--name', 'n']); return fail('confirmation_required'); };
  assert.equal(await model.nodeProfileFlow(s.ctx, 'n', { name: 'n', profile: null }), true);
  assert.deepEqual(s.record.dialogs.map((d) => d.kind), ['confirm', 'form']);
  assert.equal(s.record.dialogs[1].fields.find((f) => f.name === 'mihomo_choice').options[0].label, 'Последняя (v1.19.20)');
  s.done();
  // Отказ — ничего не создаётся.
  const refused = scripted([[['profile', 'list'], ok({ profiles: [] })]], [false]);
  assert.equal(await model.nodeProfileFlow(refused.ctx, 'n', { name: 'n' }), false);
  refused.done();
});

test('роли и домены: строки карточки, argv ролей и занятые домены', () => {
  const bare = model.nodeRoles({ name: 'n' });
  assert.deepEqual(bare.map((r) => [r.key, r.value]), [['domain', null], ['telegram', null], ['subscription', null]]);
  assert.ok(bare.every((r) => r.hint && r.unset));
  const full = model.nodeRoles({ domain: 'de.example.com', telegram: { hostname: 'tg.example.com' }, subscription: { hostname: 'sub.example.com', port: 8443 } });
  assert.deepEqual(full.map((r) => r.value), ['de.example.com', 'tg.example.com', 'sub.example.com:8443']);
  assert.equal(model.nodeRoles({ subscription: { hostname: 'sub.example.com', port: 443 } })[2].value, 'sub.example.com');
  assert.deepEqual(model.roleArgvs('n', { telegram_domain: ' tg.example.com ', subscription_domain: 'sub.example.com' }), {
    telegram: ['telegram', 'set', '--name', 'n', '--domain', 'tg.example.com'],
    subscription: ['subscription', 'host', '--name', 'n', '--domain', 'sub.example.com'],
  });
  assert.deepEqual(model.roleArgvs('n', {}), { telegram: null, subscription: null });
  assert.equal(model.roleDomainError('de.example.com', ['de.example.com', '']), model.DOMAIN_TAKEN);
  // Как в ядре: имена DNS без учёта регистра.
  assert.equal(model.roleDomainError('DE.Example.COM', ['de.example.com']), model.DOMAIN_TAKEN);
  assert.equal(model.roleDomainError('', ['']), null);
  // Форма добавления: домены ролей — только с профилем, проверяются по мере ввода и не повторяют домен ноды.
  const fields = Object.fromEntries(model.addFields({}, [edge]).map((f) => [f.name, f]));
  for (const name of ['telegram_domain', 'subscription_domain']) {
    assert.equal(fields[name].live, true);
    assert.equal(fields[name].when({ profile: '' }), false);
    assert.equal(fields[name].when({ profile: 'edge' }), true);
  }
  assert.equal(fields.telegram_domain.validate('de.example.com', { domain: 'de.example.com' }), model.DOMAIN_TAKEN);
  assert.equal(fields.subscription_domain.validate('tg.example.com', { domain: 'de.example.com', telegram_domain: 'tg.example.com' }), model.DOMAIN_TAKEN);
  assert.ok(fields.subscription_domain.validate('bad', {}));
  assert.equal(fields.subscription_domain.suggest('https://Sub.Example.com/x'), 'sub.example.com');
  // Имя ноды: живая проверка с предложением.
  assert.equal(fields.name.live, true);
  assert.ok(fields.name.validate('my vps'));
  assert.equal(fields.name.suggest('my vps'), 'my-vps');
  assert.equal(fields.name.validate(''), null);
});

test('добавление с ролями: telegram set и хост подписок до одного node apply', async () => {
  const form = { ...keyForm, profile: 'edge', domain: 'de.example.com', telegram_domain: 'tg.example.com', subscription_domain: 'sub.example.com' };
  const apply = ['node', 'apply', '--name', 'vps-1', '--name', 'old'];
  const s = scripted([
    [addWords('key', ['--profile', 'edge', '--domain', 'de.example.com', '--accept-new-host-key']), ok({ name: 'vps-1' })],
    [['telegram', 'set', '--name', 'vps-1', '--domain', 'tg.example.com'], ok({})],
    [['subscription', 'host'], ok({ node: 'old', hostname: 'sub.old.example.com', port: 443 })],
    [['subscription', 'host', '--name', 'vps-1', '--domain', 'sub.example.com'], ok({})],
    [apply, ok({ applied: ['vps-1', 'old'], failed: [], unchanged: [] })],
  ], [form, true, undefined], { profiles: [edge] });
  const opened = [];
  assert.equal(await model.addNodeFlow(s.ctx, (name) => opened.push(name)), true);
  assert.deepEqual(opened, ['vps-1']);
  // Перенос хоста подписок называет прежнюю ноду.
  assert.ok(s.record.dialogs[1].context.some((line) => (line.text || line).includes('old')));
  s.done();
  // Отказ от переноса: хост не меняется, применяется только новая нода.
  const refused = scripted([
    [addWords('key', ['--profile', 'edge', '--domain', 'de.example.com', '--accept-new-host-key']), ok({ name: 'vps-1' })],
    [['subscription', 'host'], ok({ node: 'old', hostname: 'sub.old.example.com', port: 443 })],
    [['node', 'apply', '--name', 'vps-1'], ok({ applied: ['vps-1'], failed: [], unchanged: [] })],
  ], [{ ...form, telegram_domain: '' }, false, undefined], { profiles: [edge] });
  assert.equal(await model.addNodeFlow(refused.ctx, () => {}), true);
  refused.done();
});

test('добавление: сбой роли — «Повторить»/«Пропустить» с подсказкой, отложенная SSH-настройка — без применения', async () => {
  const words = addWords('key', ['--profile', 'edge', '--domain', 'de.example.com', '--accept-new-host-key']);
  const form = { ...keyForm, profile: 'edge', domain: 'de.example.com', telegram_domain: 'tg.example.com', subscription_domain: 'sub.example.com' };
  const applied = ok({ applied: ['vps-1'], failed: [], unchanged: [] });
  // telegram set не прошёл: «Повторить» с новым доменом; хост подписок не прошёл: «Пропустить»; затем одно применение.
  const s = scripted([
    [words, ok({ name: 'vps-1' })],
    [['telegram', 'set', '--name', 'vps-1', '--domain', 'tg.example.com'], fail('invalid')],
    [['telegram', 'set', '--name', 'vps-1', '--domain', 'tg2.example.com'], ok({})],
    [['subscription', 'host'], ok(null)], [['subscription', 'host', '--name', 'vps-1', '--domain', 'sub.example.com'], fail('invalid')],
    [['node', 'apply', '--name', 'vps-1'], applied],
  ], [form, 'retry', { domain: 'tg2.example.com' }, 'skip', undefined], { profiles: [edge] });
  assert.equal(await model.addNodeFlow(s.ctx, () => {}), true);
  assert.equal(s.record.dialogs[2].fields[0].value, 'tg.example.com');
  assert.ok(s.record.notices.filter(([, text]) => text.includes(model.ROLE_LATER)).length === 2);
  s.done();
  // Нода сохранена с отложенной SSH-настройкой: роли заданы, применения нет, сказано, что осталось.
  const deferred = scripted([
    [words, ok({ name: 'vps-1', needs_setup: true })],
    [['telegram', 'set', '--name', 'vps-1', '--domain', 'tg.example.com'], ok({})],
  ], [{ ...form, subscription_domain: '' }], { profiles: [edge] });
  assert.equal(await model.addNodeFlow(deferred.ctx, () => {}), true);
  assert.ok(deferred.record.notices.some(([, text]) => text === model.DEFERRED_APPLY));
  deferred.done();
});

test('имя новой ноды: предложение не совпадает с существующими', () => {
  const name = model.addFields({}, [], ['my-vps']).find((f) => f.name === 'name');
  assert.equal(name.suggest('my vps'), 'my-vps-2');
  // Порт SSH — правило ядра: `080` допустим, `000080` и `0` — нет.
  assert.equal(model.portError('080'), null);
  assert.equal(model.portError('000080'), model.PORT_INVALID);
  assert.equal(model.portError('0'), model.PORT_INVALID);
});

test('«Сделать хостом подписок» в карточке: домен и порт → subscription host, затем node apply --name', async () => {
  const node = { name: 'n', profile: 'edge', domain: 'de.example.com' };
  const s = scripted([
    [['subscription', 'host'], ok(null)], [['subscription', 'host', '--name', 'n', '--domain', 'sub.example.com', '--port', '8443'], ok({})],
    [['node', 'apply', '--name', 'n'], fail('confirmation_required')],
  ], [{ domain: 'sub.example.com', port: '8443' }]);
  assert.equal(await model.subscriptionRoleFlow(s.ctx, 'n', node), true);
  const domain = s.record.dialogs[0].fields[0];
  assert.equal(domain.validate('de.example.com'), model.DOMAIN_TAKEN);
  s.done();
});

test('оболочка: node shell без загрузки скриптов, conflict — уведомление', async () => {
  const opened = [];
  const s = scripted([], []);
  s.ctx.terminal = async (argv, title, options) => { opened.push([argv, options]); return fail('conflict'); };
  await model.interactive(s.ctx, 'n');
  assert.deepEqual(opened, [[['node', 'shell', '--name', 'n'], { expect: ['conflict'] }]]);
  assert.equal(s.record.notices.length, 1);
  assert.equal(typeof model.uploadOffer, 'undefined');
});

test('применение: состояние, подписи сбоев, отчёт и argv', async () => {
  assert.equal(apply.applyState({ status: 'pending' }).tone, 'warn');
  assert.equal(apply.applyState({ status: 'applied' }).tone, 'ok');
  assert.notEqual(apply.applyState({ status: 'running' }).label, apply.applyState({ status: 'pending' }).label);
  assert.deepEqual(apply.applyNamesArgv(['a', 'b']), ['node', 'apply', '--name', 'a', '--name', 'b']);
  assert.deepEqual(apply.applyProfileArgv('edge'), ['node', 'apply', '--profile', 'edge']);
  assert.deepEqual(apply.APPLY_PENDING_ARGV, ['node', 'apply', '--pending']);
  assert.deepEqual(apply.pendingNodes([{ name: 'a', status: 'pending' }, { name: 'b', status: 'running' }, { name: 'c', status: 'applied' }]), ['a']);
  assert.ok(apply.offersApply(['client', 'set-group', '--name', 'c']));
  assert.ok(apply.offersApply(['conn', 'set', '--name', 'n']));
  assert.ok(!apply.offersApply(['conn', 'sync']));
  assert.ok(!apply.offersApply(['client', 'rename', '--name', 'c']));
  // partial: отчёт из error, строка сбоя `имя: сообщение` с тоном error.
  const entries = [
    {"name":"de","stage":"config","code":"rolled_back","message":"откат на этапе «конфигурация и проверка»"},
    {"name":"de","stage":"probe","code":"port_busy","message":"порт 443 уже занят","port":443},
    {"name":"de","stage":"probe","code":"remote_failed","message":"Не удалось подключиться к «de»."},
    {"name":"de","stage":"probe","code":"unsupported_os","message":"ОС ноды «ubuntu 25.10» не поддерживается: нужна Debian 12/13 или Ubuntu 22.04/24.04/26.04 с systemd"},
  ];
  const partial = fail('partial', { message: 'Применение завершено с ошибками.', applied: ['a'], failed: entries, unchanged: ['c'] });
  const lines = apply.applyLines(apply.applyReport(partial));
  assert.equal(lines.length, 6);
  assert.deepEqual(lines.slice(2), entries.map((entry) => ({ text: `de: ${entry.message}`, tone: 'error' })));
  assert.equal(apply.applyReport(fail('locked')), null);
  // applyFlow: expect partial и nothing_pending, окно операции; nothing_pending — уведомление без окна итога.
  const s = scripted([[['node', 'apply', '--pending'], partial], [['node', 'apply', '--pending'], fail('nothing_pending')]], [undefined]);
  await apply.applyFlow(s.ctx, apply.APPLY_PENDING_ARGV);
  assert.deepEqual(s.record.options[0].expect, ['partial', 'nothing_pending']);
  assert.ok(s.record.options[0].operation);
  await apply.applyFlow(s.ctx, apply.APPLY_PENDING_ARGV);
  assert.deepEqual(s.record.dialogs.map((d) => d.kind), ['show']);
  assert.equal(s.record.notices.length, 1);
  s.done();
});

test('применение: ноды partial с domain_required — домен, node domain и один повтор', async () => {
  const entry = {"name":"de","stage":"probe","code":"domain_required","message":"Для ноды «de» нужен домен: node domain --name de --domain D."};
  const partial = fail('partial', { message: 'Применение завершено с ошибками.', applied: [], unchanged: [], failed: [entry] });
  const pending = ['node', 'apply', '--pending'];
  // Повтор с тем же отказом — без второго вопроса домена.
  const s = scripted([
    [pending, partial],
    [['node', 'domain', '--name', 'de', '--domain', 'de.example.com'], ok()],
    [pending, partial],
  ], [undefined, ' de.example.com ', undefined]);
  const reply = await apply.applyFlow(s.ctx, apply.APPLY_PENDING_ARGV);
  assert.equal(reply.error.code, 'partial');
  assert.deepEqual(s.record.dialogs.map((d) => d.kind), ['show', 'text', 'show']);
  assert.deepEqual(s.record.options[2].expect, ['partial', 'nothing_pending'], 'повтор — тем же потоком подтверждения');
  s.done();
  // Отказ от ввода домена — итог без повтора; профиль — тот же путь.
  const profile = apply.applyProfileArgv('edge');
  const refused = scripted([[profile, partial]], [undefined, null]);
  await apply.applyFlow(refused.ctx, profile);
  assert.deepEqual(refused.record.dialogs.map((d) => d.kind), ['show', 'text']);
  refused.done();
});

test('применение: прочие коды нод из partial — handleNodeCodes и один повтор', async () => {
  const entry = { name: 'de', stage: 'probe', code: 'missing_secret', message: 'Пароль SSH для «de» не сохранён.' };
  const partial = fail('partial', { message: 'Применение завершено с ошибками.', applied: [], unchanged: [], failed: [entry] });
  const pending = ['node', 'apply', '--pending'];
  const s = scripted([
    [pending, partial],
    [['node', 'password', '--name', 'de'], ok()],
    [pending, ok({ applied: ['de'], failed: [], unchanged: [] })],
  ], [undefined, true, 'pw', undefined]);
  const reply = await apply.applyFlow(s.ctx, apply.APPLY_PENDING_ARGV);
  assert.equal(reply.ok, true);
  assert.deepEqual(s.record.dialogs.map((d) => d.kind), ['show', 'confirm', 'secret', 'show']);
  assert.deepEqual(s.record.secrets[1], { password: 'pw' });
  s.done();
  // Отказ сохранить пароль — итог без повтора.
  const refused = scripted([[pending, partial]], [undefined, false]);
  assert.equal((await apply.applyFlow(refused.ctx, apply.APPLY_PENDING_ARGV)).error.code, 'partial');
  refused.done();
});

test('предложение применить: сразу node apply --pending без своего вопроса, без ожидающих — ничего', async () => {
  const s = scripted([
    [['node', 'list'], ok([{ name: 'de', status: 'pending' }])],
    [['node', 'apply', '--pending'], ok({ applied: ['de'], failed: [], unchanged: [] })],
  ], [undefined]);
  await apply.offerApply(s.ctx);
  assert.deepEqual(s.record.dialogs.map((d) => d.kind), ['show']);
  s.done();
  const none = scripted([[['node', 'list'], ok([{ name: 'de', status: 'applied' }])]], []);
  await apply.offerApply(none.ctx);
  none.done();
});
