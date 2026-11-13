import test from 'node:test';
import assert from 'node:assert/strict';
import * as model from '../assets/js/screens/nodes-model.js';

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
  assert.deepEqual(model.nodeStatus(problem), { tone: 'warn', label: 'нет пароля SSH' });
  assert.deepEqual(model.nodeStatus(deferred), { tone: 'warn', label: 'missing_identity, missing_host_key' });
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
  assert.deepEqual(options.map((o) => o.label), ['local', 'server', 'server+key']);
  assert.ok(options.every((o) => o.tone === 'danger'));
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
  assert.deepEqual(model.addNodeArgv({ ...base, ip: '' }), { warning: 'IP не указан.' });
  for (const port of ['0', '70000', 'x', '-1', '1.5']) {
    assert.deepEqual(model.addNodeArgv({ ...base, port }), { warning: 'Порт должен быть числом от 1 до 65535.' });
  }
  assert.deepEqual(model.addNodeArgv({ ...base, port: '65535' }).argv[7], '65535');
  assert.deepEqual(model.addNodeArgv({ ...base, auth: 'password' }), { warning: 'Пароль не может быть пустым.' });
  assert.deepEqual(model.addNodeArgv({ ...base, tag: '' }), { warning: 'Тег не может быть пустым.' });
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
