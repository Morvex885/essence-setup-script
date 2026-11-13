// Тесты screens/system-model.js: сводка, настройки, источник и мастер GitHub
// против эталонов `tui/src/system.rs` и `tui/src/source.rs` (точный argv,
// имена секретов, коды решений).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { runConfirmed } from '../assets/js/flows.js';
import { joined } from '../assets/js/format.js';
import {
  dashboardTitle, attentionItems, updateAvailable, settingsAction, uninstallArgv, daemonLines,
  sourceView, sourceAction, importRecoveryKey, recoveryRun, githubWizardFlow, wizardAccounts,
  storageLabel, existingLabel, targetReplaceContext, passwordForm, CANCELLED, FILE_UNREADABLE, PASSWORDS_DIFFER, PASSWORD_EMPTY,
  OTHER_LOGIN,
} from '../assets/js/screens/system-model.js';

const ok = (data = null) => ({ ok: true, data });
const error = (code, extra = {}) => ({ ok: false, error: { code, message: '', ...extra } });
const plan = (token) => error('confirmation_required', { plan: ['plan: X'], plan_token: token });
const yes = (argv, token) => [...argv, '--yes', '--plan-token', token];
/** Отметка `ctx.failed()` в уведомлениях поддельного ctx. */
const FAILED = Symbol('failed');
/** Ссылки для ручных действий (`deps.link`): только адреса. */
const linkSink = (links) => ({ link: (label, url) => links.push(url) });

/**
 * Поддельный `ctx`: `steps` — `[argv, reply]` по порядку, `answers` — ответы
 * диалогов по порядку. Записывает argv, имена секретов, input и уведомления.
 */
function scripted(steps, answers = []) {
  const queue = [...steps];
  const replies = [...answers];
  const record = { calls: [], secretNames: [], inputs: [], notices: [], dialogs: [], wizard: [], operations: [] };
  const dialog = (kind) => async (props) => {
    record.dialogs.push({ kind, ...props });
    assert.ok(replies.length > 0, `нет ответа для диалога ${kind}: ${props.title}`);
    return replies.shift();
  };
  const ctx = {
    async request(argv, options = {}) {
      assert.ok(queue.length > 0, `лишний запрос ${argv.join(' ')}`);
      const [expected, reply] = queue.shift();
      assert.deepEqual(argv, expected);
      record.calls.push([...argv]);
      record.secretNames.push(Object.keys(options.secrets || {}).sort());
      record.inputs.push(options.input || null);
      if (options.operation) record.operations.push(options.operation);
      return reply;
    },
    confirm: dialog('confirm'),
    askSecret: dialog('secret'),
    ask: dialog('ask'),
    choose: dialog('choose'),
    form: dialog('form'),
    notify: (level, text) => record.notices.push(text),
    failed: () => record.notices.push(FAILED),
    runConfirmed: (title, question, argv, { secrets, input } = {}) => runConfirmed(title, question, argv, {
      request: ctx.request, confirm: ctx.confirm, notify: ctx.notify, secrets, input,
    }),
    wizard: async (mode) => { record.wizard.push(mode); return false; },
  };
  const finished = () => {
    assert.equal(queue.length, 0, `не выполнены запросы: ${JSON.stringify(queue.map((step) => step[0]))}`);
    assert.equal(replies.length, 0, 'остались ответы диалогов');
  };
  return { ctx, record, finished };
}

// ─── Сводка ────────────────────────────────────────────────────────────────

const statusData = {
  version: '1.1.0', update: { current: '1.1.0', latest: 'v1.2.0', available: true }, script_password: false,
  source: { type: 'github', repo: 'o/r', sync: 'pending' }, counts: { nodes: 2, groups: 3, clients: 1 },
  password_missing: ['ru'], ssh_setup_pending: true, subscription_host: null,
};

test('сводка: заголовок — версия из status, без неё — из hello (dashboard_view)', () => {
  assert.equal(dashboardTitle(statusData, '0.0.0'), 'Remote Control v1.1.0');
  assert.equal(dashboardTitle({}, 'test'), 'Remote Control vtest');
  assert.equal(dashboardTitle(null, '2.0.0'), 'Remote Control v2.0.0');
});

test('сводка: «Требует внимания» из status и hello', () => {
  const items = attentionItems(statusData, { listener: { loopback: false } });
  assert.deepEqual(items.map((item) => item.id), ['password:ru', 'ssh-setup', 'subscription-host', 'sync', 'update', 'open-panel']);
  assert.deepEqual({ type: items[0].action.type, node: items[0].action.node }, { type: 'password', node: 'ru' });
  assert.equal(items[1].action.type, 'ssh-setup');
  assert.deepEqual(items.slice(2).map((item) => item.action.route), ['subscriptions', 'source', 'settings', 'settings']);
  assert.equal(items.find((item) => item.id === 'sync').tone, 'warn');
  // Всё в порядке: синхронизировано, хост задан, пароль запуска есть, loopback.
  const calm = attentionItems({
    update: { available: false }, script_password: false, source: { type: 'github', repo: 'o/r', sync: 'clean' },
    password_missing: [], ssh_setup_pending: false, subscription_host: 'de',
  }, { listener: { loopback: true } });
  assert.deepEqual(calm, []);
  assert.deepEqual(attentionItems({ source: { type: 'local' }, subscription_host: 'de' }, null), []);
  assert.deepEqual(attentionItems(null, null).map((item) => item.id), ['subscription-host']);
});

test('сводка: группы без нод и ноды без назначенных подключений', () => {
  const calm = { source: { type: 'local' }, subscription_host: 'de' };
  const groups = [
    { name: 'PC', clients: 2, nodes: [] },
    { name: 'EMPTY', clients: 0, nodes: [] },
    { name: 'ROUTER', clients: 1, nodes: ['de'] },
  ];
  const nodes = [{ name: 'de' }, { name: 'nl' }];
  const items = attentionItems(calm, null, { groups, nodes });
  assert.deepEqual(items.map((item) => [item.id, item.tone]), [
    ['group-nodes:PC', 'warn'], ['group-nodes:EMPTY', 'info'], ['node-groups:nl', 'info'],
  ]);
  // Нода без назначений ведёт на свою вкладку подключений.
  assert.deepEqual(items[2].action, { label: items[2].action.label, type: 'route', route: 'nodes', param: 'nl', tab: 'connections' });
  // Единственная нода — группа без нод сразу ведёт к её подключениям.
  const single = attentionItems(calm, null, { groups: [{ name: 'PC', clients: 1, nodes: [] }], nodes: [{ name: 'de' }] });
  assert.deepEqual([single[0].action.param, single[0].action.tab], ['de', 'connections']);
  // Списки не прочитаны — пунктов нет.
  assert.deepEqual(attentionItems(calm, null, { groups: null, nodes }), []);
  assert.deepEqual(attentionItems(calm, null, { groups: [{ name: 'PC', clients: 0, nodes: ['de'] }], nodes: null }), []);
});

// ─── Настройки ─────────────────────────────────────────────────────────────

const version = (available) => ok({ current: '1.1.0', latest: available ? 'v1.2.0' : null, update_available: available, checked: available });

test('настройки: обновление только при update_available, удаление — объём данных (settings_view)', () => {
  assert.equal(updateAvailable(version(false)), false);
  assert.equal(updateAvailable(version(true)), true);
  assert.equal(updateAvailable(error('failed')), false);
  assert.equal(updateAvailable(null), false);
  assert.deepEqual(uninstallArgv('keep'), ['self', 'uninstall']);
  assert.deepEqual(uninstallArgv('remove'), ['self', 'uninstall', '--remove-data']);
});

test('настройки: пароль запуска передаётся только секретами', async () => {
  const set = ['self', 'password-set'];
  const remove = ['self', 'password-remove'];
  let s = scripted([[set, ok({ password_set: true })]], [{ password: 'new-pw', repeat: 'new-pw' }]);
  assert.equal(await settingsAction(s.ctx, 'l', { password: false }), null);
  s.finished();
  assert.deepEqual(s.record.secretNames, [['password']]);
  s = scripted([[set, ok()]], [{ current: 'cur-pw', password: 'next-pw', repeat: 'next-pw' }]);
  await settingsAction(s.ctx, 'l', { password: true });
  s.finished();
  assert.deepEqual(s.record.secretNames, [['current-password', 'password']]);
  s = scripted([[remove, plan('T1')], [yes(remove, 'T1'), ok({ password_set: false })]], ['cur-pw', true]);
  await settingsAction(s.ctx, 'r', { password: true });
  s.finished();
  assert.deepEqual(s.record.secretNames, [['current-password'], ['current-password']]);
  for (const secret of ['new-pw', 'cur-pw', 'next-pw']) assert.ok(!JSON.stringify(s.record.calls).includes(secret));
  // Несовпадающие пароли — ничего не отправляется.
  s = scripted([], [{ password: 'a', repeat: 'b' }]);
  await settingsAction(s.ctx, 'l', { password: false });
  s.finished();
  assert.deepEqual(s.record.notices, [PASSWORDS_DIFFER]);
  // Убрать пароль без пароля — недоступно.
  s = scripted([]);
  assert.equal(await settingsAction(s.ctx, 'r', { password: false }), null);
  s.finished();
});

test('настройки: обновление только при наличии, удаление с объёмом', async () => {
  const update = ['self', 'update'];
  let s = scripted([]);
  assert.equal(await settingsAction(s.ctx, 'u', { password: false, available: false }), null);
  s.finished();
  s = scripted([[update, plan('T1')]], [false]);
  assert.equal(await settingsAction(s.ctx, 'u', { password: false, available: true }), null);
  s.finished();
  assert.ok(!s.record.notices.includes(FAILED), 'отказ от плана — не сбой');
  s = scripted([[update, plan('T1')], [yes(update, 'T1'), ok()]], [true]);
  assert.equal(await settingsAction(s.ctx, 'u', { password: false, available: true }), 'update');
  s.finished();
  const uninstall = ['self', 'uninstall', '--remove-data'];
  s = scripted([[uninstall, plan('T1')], [yes(uninstall, 'T1'), ok({ removed: true })]], [{ scope: 'remove' }, true]);
  assert.equal(await settingsAction(s.ctx, 'x', { password: false }), 'uninstall');
  s.finished();
  s = scripted([], [null]);
  assert.equal(await settingsAction(s.ctx, 'x', { password: false }), null);
  s.finished();
});

test('настройки: блок «Демон» из daemon status, отсутствующее — «—»', () => {
  const full = daemonLines({
    version: '2.0.0', clients: [{ origin: 'local', since_s: 3 }, { origin: 'web', since_s: 1 }], terminals: ['de', 'nl'],
    web: { enabled: true, url: 'https://10.0.0.1:8377', fingerprint: 'SHA256:ab' },
  });
  assert.deepEqual(full.map((l) => l.value), ['v2.0.0', '2', 'de, nl', 'https://10.0.0.1:8377', 'SHA256:ab']);
  const bare = daemonLines({ version: '2.0.0', clients: [], terminals: [], web: null });
  assert.deepEqual(bare.map((l) => l.value), ['v2.0.0', '0', joined([]), '—', '—']);
  assert.deepEqual(daemonLines({}).map((l) => l.value), ['—', '—', '—', '—', '—']);
  assert.deepEqual(daemonLines(null).map((l) => l.value), ['—', '—', '—', '—', '—']);
});

// ─── Источник ──────────────────────────────────────────────────────────────

const sourceData = (storage) => ({ type: 'github', repo: 'o/r', branch: 'main', storage, sync: 'clean', key_saved: false });
const localData = { type: 'local', repo: null, branch: null, storage: null, sync: null, key_saved: null };
test('источник: клавиши действий по режиму и хранению (source_view)', () => {
  const age = sourceView(sourceData('age'));
  assert.deepEqual([age.github, age.encrypted], [true, true]);
  assert.deepEqual(age.keys, ['f', 'p', 'c', 'r', 'v', 'k', 'e', 'l', 'd']);
  const plain = sourceView(sourceData('none'));
  assert.deepEqual([plain.encrypted, plain.keys], [false, ['f', 'p', 'c', 'e', 'l', 'd']]);
  assert.deepEqual(sourceView(localData), { github: false, encrypted: false, keys: ['g'] });
});

test('источник: синхронизация, переключение и ключ восстановления', async () => {
  const s = scripted([
    [['source', 'github-fetch'], ok({ sync: 'clean' })],
    [['source', 'github-push'], error('source_failed', { message: 'push rejected' })],
    [['source', 'github-switch-local'], ok({ source: 'local' })],
    [['source', 'github-import-recovery-key'], ok()],
  ]);
  for (const key of ['f', 'p', 'e']) await sourceAction(s.ctx, key, sourceData('age'));
  await importRecoveryKey(s.ctx, 'AGE-SECRET-KEY-1TEST\n');
  await importRecoveryKey(s.ctx, null);
  s.finished();
  assert.deepEqual(s.record.inputs[3], { file: 'AGE-SECRET-KEY-1TEST\n' });
  assert.deepEqual(s.record.notices, [FAILED, FILE_UNREADABLE]);
  // Без шифрования действия ключа ничего не вызывают.
  const plain = scripted([]);
  for (const key of ['r', 'v']) await sourceAction(plain.ctx, key, sourceData('none'));
  plain.finished();
  // Локальный источник: только мастер подключения.
  const local = scripted([]);
  await sourceAction(local.ctx, 'g', localData);
  await sourceAction(local.ctx, 'f', localData);
  local.finished();
  assert.deepEqual(local.record.wizard, ['connect']);
  const change = scripted([]);
  await sourceAction(change.ctx, 'c', sourceData('none'));
  assert.deepEqual(change.record.wizard, ['change']);
});

test('источник: смена пароля и новый ключ — пароли только секретами', async () => {
  const rewrap = ['source', 'github-rewrap-password'];
  const rotate = ['source', 'github-rotate-key'];
  const s = scripted([
    [rewrap, ok({ sync: 'clean' })],
    [rotate, plan('T1')],
    [rotate, plan('T1')], [yes(rotate, 'T1'), ok()],
  ], [
    { current: 'old-pass', password: 'new-pass', repeat: 'new-pass' }, { current: 'old-pass', password: 'new-pass', repeat: 'other' },
    { password: 'n1', repeat: 'n1' }, false, { password: 'n1', repeat: 'n1' }, true,
  ]);
  const data = sourceData('age');
  await sourceAction(s.ctx, 'r', data);
  await sourceAction(s.ctx, 'r', data);
  await sourceAction(s.ctx, 'v', data);
  await sourceAction(s.ctx, 'v', data);
  s.finished();
  assert.deepEqual(s.record.secretNames, [['new-vault-password', 'vault-password'], ['new-vault-password'], ['new-vault-password'], ['new-vault-password']]);
  assert.ok(s.record.notices.includes(PASSWORDS_DIFFER));
  assert.ok(!s.record.notices.includes(FAILED), 'отказ от плана — не сбой');
  for (const secret of ['old-pass', 'new-pass', 'n1']) assert.ok(!JSON.stringify(s.record.calls).includes(secret));
});

test('источник: замена спрашивает о ключе, удаление показывает ссылку настроек', async () => {
  const replace = ['source', 'github-replace-with-local'];
  const provisioned = [...replace, '--provision-keys', 'yes'];
  const remove = ['source', 'github-delete-repo'];
  const links = [];
  const s = scripted([
    [replace, error('key_provisioning_required', { nodes: ['de', 'nl'] })],
    [provisioned, plan('T1')], [yes(provisioned, 'T1'), ok({ published: true, refreshed: true })],
    [remove, plan('T2')],
    [remove, plan('T2')], [yes(remove, 'T2'), error('remote_failed', { settings_url: 'https://github.com/o/r/settings' })],
  ], [true, true, false, true]);
  const deps = linkSink(links);
  await sourceAction(s.ctx, 'l', sourceData('age'), deps);
  await sourceAction(s.ctx, 'd', sourceData('age'), deps);
  await sourceAction(s.ctx, 'd', sourceData('age'), deps);
  s.finished();
  assert.ok(s.record.dialogs.some((d) => Array.isArray(d.context) && d.context.some((line) => line.includes('de, nl'))));
  assert.deepEqual(links, ['https://github.com/o/r/settings']);
  assert.deepEqual(s.record.notices.filter((n) => n === FAILED).length, 1);
});

test('recovery_run: свой пароль запуска и пароль хранилища', async () => {
  const migrate = ['source', 'github-migrate-format'];
  const s = scripted([
    [migrate, error('auth_required')], [migrate, error('vault_password_invalid')], [migrate, plan('T1')], [yes(migrate, 'T1'), ok()],
  ], ['pw', 'vp', true]);
  const reply = await recoveryRun(s.ctx, 'T', 'Q', 'github-migrate-format', {});
  s.finished();
  assert.ok(reply.ok);
  assert.deepEqual(s.record.secretNames.slice(2), [['script-password', 'vault-password'], ['script-password', 'vault-password']]);
  const cancel = scripted([[migrate, error('auth_required')]], [null]);
  assert.equal(await recoveryRun(cancel.ctx, 'T', 'Q', 'github-migrate-format', {}), null);
  cancel.finished();
});

test('passwordForm: одна форма, отмена и повторная проверка значений', async () => {
  let s = scripted([], [{ password: 'a', repeat: 'a' }]);
  assert.deepEqual(await passwordForm(s.ctx, 'T'), { current: null, password: 'a' });
  assert.deepEqual(s.record.dialogs[0].fields.map((field) => field.name), ['password', 'repeat']);
  s = scripted([], [{ current: 'c', password: 'a', repeat: 'a' }]);
  assert.deepEqual(await passwordForm(s.ctx, 'T', { current: true }), { current: 'c', password: 'a' });
  assert.deepEqual(s.record.dialogs[0].fields.map((field) => [field.name, field.type]),
    [['current', 'secret'], ['password', 'secret'], ['repeat', 'secret']]);
  s = scripted([], [null]);
  assert.equal(await passwordForm(s.ctx, 'T'), null);
  s = scripted([], [{ password: '', repeat: '' }]);
  assert.equal(await passwordForm(s.ctx, 'T'), null);
  assert.deepEqual(s.record.notices, [PASSWORD_EMPTY]);
  s = scripted([], [{ password: 'a', repeat: 'b' }]);
  assert.equal(await passwordForm(s.ctx, 'T'), null);
  assert.deepEqual(s.record.notices, [PASSWORDS_DIFFER]);
});

// ─── Мастер GitHub ─────────────────────────────────────────────────────────

const accounts = () => [['source', 'github-accounts'], ok({ accounts: ['test-owner'], global_login: 'glob' })];

test('мастер: подписи выбора', () => {
  assert.deepEqual(wizardAccounts({ accounts: ['a', 'glob'], global_login: 'glob' }), ['a', 'glob']);
  assert.deepEqual(wizardAccounts({ accounts: ['test-owner'], global_login: 'glob' }), ['test-owner', 'glob']);
  assert.deepEqual(wizardAccounts({ accounts: [], global_login: '' }), []);
  const labels = [storageLabel('age'), storageLabel('none'), existingLabel('remote', {}), existingLabel('local'), existingLabel('migrate')];
  assert.equal(new Set(labels).size, labels.length, 'подписи вариантов различаются');
  const counted = existingLabel('remote', { remote_counts: { nodes: 2, clients: 1, groups: 3 } });
  assert.notEqual(counted, existingLabel('remote', {}));
  assert.ok(counted.includes('2') && counted.includes('1'), 'число нод и клиентов');
  const lines = targetReplaceContext({ repo: 'o/c', tracked_files: 6, reason: 'path ssh/known_hosts' });
  assert.equal(lines.length, 3);
  for (const part of ['o/c', 'path ssh/known_hosts', '6']) assert.ok(lines.join('\n').includes(part), part);
});

test('мастер подключения: каждый код решения → флаг или секрет', async () => {
  const base = ['source', 'github-connect', '--login', 'test-owner'];
  const create = [...base, '--create-repo'];
  const storage = [...create, '--storage', 'age'];
  const keysNo = [...storage, '--provision-keys', 'no'];
  const s = scripted([accounts(),
    [base, error('github_auth_required', { login: 'test-owner', hint: 'h' })],
    [['source', 'github-login', '--login', 'test-owner'], ok({ login: 'test-owner' })],
    [base, error('repo_create_required', { repo: 'test-owner/essence-config' })],
    [create, error('storage_mode_required', { choices: ['age', 'none'] })],
    [storage, error('new_vault_password_required', { secret: 'new-vault-password' })],
    [storage, error('key_provisioning_required', { nodes: ['de'] })],
    [keysNo, plan('T1')], [yes(keysNo, 'T1'), ok({ repo: 'test-owner/essence-config', storage: 'age', sync: 'clean' })],
  ], [0, true, true, 0, { password: 'vp', repeat: 'vp' }, false, true]);
  assert.equal(await githubWizardFlow(s.ctx, 'connect'), true);
  s.finished();
  assert.equal(s.record.operations.length, 1, 'код устройства — в окне операции');
  const chooser = s.record.dialogs[0];
  assert.deepEqual(chooser.options.map((o) => o.label), ['test-owner', 'glob', OTHER_LOGIN]);
  assert.ok(s.record.dialogs.some((d) => d.kind === 'confirm' && String(d.question).includes('test-owner/essence-config')));
  assert.deepEqual(s.record.secretNames[6], ['new-vault-password']);
  assert.deepEqual(s.record.secretNames[8], ['new-vault-password']);
  assert.ok(!JSON.stringify(s.record.calls).includes('vp'));
  assert.deepEqual(s.record.notices, []);
});

test('мастер подключения: пароль хранилища, выбор конфигурации и другой логин', async () => {
  const base = ['source', 'github-connect', '--login', 'other-owner'];
  const remember = [...base, '--remember-key'];
  const existing = [...remember, '--existing', 'local'];
  const s = scripted([accounts(), [base, error('vault_password_required')],
    [remember, error('existing_config_action_required', { choices: ['remote', 'local'], remote_counts: { nodes: 2, clients: 1, groups: 3 } })],
    [existing, plan('T1')], [yes(existing, 'T1'), ok()],
  ], [2, 'other-owner', 'vp', true, 1, true]);
  assert.equal(await githubWizardFlow(s.ctx, 'connect'), true);
  s.finished();
  const chooser = s.record.dialogs[4];
  assert.deepEqual(chooser.options.map((o) => o.label),
    [existingLabel('remote', { remote_counts: { nodes: 2, clients: 1, groups: 3 } }), existingLabel('local')]);
  assert.deepEqual(s.record.secretNames[4], ['vault-password']);
});

test('мастер: --remember-key следует последнему ответу после неверного пароля', async () => {
  const base = ['source', 'github-connect', '--login', 'other-owner'];
  const remember = [...base, '--remember-key'];
  let s = scripted([accounts(), [base, error('vault_password_required')], [remember, error('vault_password_invalid')], [base, ok()]],
    [2, 'other-owner', 'vp', true, 'vp2', false]);
  assert.equal(await githubWizardFlow(s.ctx, 'connect'), true);
  s.finished();
  s = scripted([accounts(), [base, error('vault_password_required')], [base, error('vault_password_invalid')], [remember, ok()]],
    [2, 'other-owner', 'vp', false, 'vp2', true]);
  assert.equal(await githubWizardFlow(s.ctx, 'connect'), true);
  s.finished();
});

test('мастер: варианты хранения — из ответа', async () => {
  const base = ['source', 'github-connect', '--login', 'test-owner'];
  const s = scripted([accounts(), [base, error('storage_mode_required', { choices: ['none'] })], [[...base, '--storage', 'none'], ok()]], [0, 0]);
  assert.equal(await githubWizardFlow(s.ctx, 'connect'), true);
  s.finished();
  assert.deepEqual(s.record.dialogs[1].options.map((o) => o.label), [storageLabel('none')]);
});

test('мастер смены аккаунта: кэш, чужой репозиторий, приватность, ссылка прежнего', async () => {
  const base = ['source', 'github-change-account', '--login', 'glob'];
  const cache = [...base, '--without-cache'];
  const target = [...cache, '--replace-target'];
  const priv = [...target, '--make-private'];
  const links = [];
  let s = scripted([accounts(), [base, error('cache_skip_required')],
    [cache, error('target_replace_required', { repo: 'glob/essence-config', tracked_files: 3 })],
    [target, error('repo_private_required', { repo: 'glob/essence-config' })], [priv, plan('T1')],
    [yes(priv, 'T1'), ok({ repo: 'glob/essence-config', sync: 'clean', old_repo_settings_url: 'https://github.com/test-owner/essence-config/settings' })],
  ], [1, true, true, true]);
  assert.equal(await githubWizardFlow(s.ctx, 'change', linkSink(links)), true);
  s.finished();
  assert.deepEqual(links, ['https://github.com/test-owner/essence-config/settings']);
  // Смена аккаунта не предлагает запомнить ключ.
  s = scripted([accounts(), [base, error('vault_password_required')], [base, ok()]], [1, 'vp']);
  assert.equal(await githubWizardFlow(s.ctx, 'change'), true);
  s.finished();
});

test('мастер: отказ заменить чужой репозиторий — «Отменено.» без вызовов', async () => {
  const base = ['source', 'github-connect', '--login', 'test-owner'];
  const foreign = error('target_replace_required', { repo: 'test-owner/essence-config', tracked_files: 6, reason: 'bad path: ssh/known_hosts' });
  const s = scripted([accounts(), [base, foreign]], [0, false]);
  assert.equal(await githubWizardFlow(s.ctx, 'connect'), false);
  s.finished();
  assert.deepEqual(s.record.notices, [CANCELLED]);
  const question = s.record.dialogs.find((d) => d.kind === 'confirm' && Array.isArray(d.context));
  assert.ok(question.context.join(' ').includes('ssh/known_hosts'));
  assert.ok(question.context.join(' ').includes('6'));
});

test('мастер: отказ или отмена на любом шаге', async () => {
  const base = ['source', 'github-connect', '--login', 'test-owner'];
  for (const answer of [false, null]) {
    const s = scripted([accounts(), [base, error('repo_create_required', { repo: 'r' })]], [0, answer]);
    assert.equal(await githubWizardFlow(s.ctx, 'connect'), false);
    s.finished();
    assert.ok(s.record.notices.includes(CANCELLED));
  }
  for (const answers of [[null], [2, ''], [2, null]]) {
    const s = scripted([accounts()], answers);
    assert.equal(await githubWizardFlow(s.ctx, 'connect'), false);
    s.finished();
  }
  let s = scripted([accounts(), [base, error('github_auth_required', { login: 'test-owner' })]], [0, false]);
  assert.equal(await githubWizardFlow(s.ctx, 'connect'), false);
  s.finished();
  s = scripted([accounts(), [base, plan('T1')]], [0, false]);
  assert.equal(await githubWizardFlow(s.ctx, 'connect'), false);
  s.finished();
  assert.ok(!s.record.notices.includes(FAILED));
  // Сбой входа в GitHub и чтения аккаунтов — «Операция завершилась ошибкой».
  s = scripted([accounts(), [base, error('github_auth_required')], [['source', 'github-login', '--login', 'test-owner'], error('failed')]], [0, true]);
  assert.equal(await githubWizardFlow(s.ctx, 'connect'), false);
  s.finished();
  assert.deepEqual(s.record.notices, [FAILED]);
  s = scripted([[['source', 'github-accounts'], error('failed')]]);
  assert.equal(await githubWizardFlow(s.ctx, 'connect'), false);
  s.finished();
  assert.deepEqual(s.record.notices, [FAILED]);
});
