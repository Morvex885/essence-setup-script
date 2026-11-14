// Модель экранов клиентов и групп против `remote-control/tui/src/clients.rs`:
// argv, состояния и действия поверх поддельного ctx (без текстов окон).
import test from 'node:test';
import assert from 'node:assert/strict';
import * as m from '../assets/js/screens/clients-model.js';
import { isFailure } from '../assets/js/flows.js';

const row = (name, inherit, subscription) => ({ name, group: 'PC', inherit_nodes: inherit, nodes: ['de'], subscription });
const unpublished = { published: false, expires_at: null };
const nodes = [{ name: 'de', ip: '127.0.0.1', port: 22 }, { name: 'ru', ip: '10.0.0.2', port: 2222 }];

test('node labels and joined lists', () => {
  assert.equal(m.nodeLabel(nodes[0]), 'de  127.0.0.1:22');
  assert.equal(m.joined([]), m.joined(null));
  assert.ok(m.joined([]));
  assert.equal(m.joined(['a', 1, 'b']), 'a, b');
});

test('client delete argv repeats --name in selection order', () => {
  assert.deepEqual(m.deleteClientsArgv(['alice', 'bob']), ['client', 'delete', '--name', 'alice', '--name', 'bob']);
});

test('subscription state and list badge', () => {
  const none = m.subscriptionState(row('a', true, unpublished));
  const until = m.subscriptionState(row('a', true, { published: true, expires_at: '2026-12-01T00:00:00Z' }));
  const forever = m.subscriptionState(row('a', true, { published: true, expires_at: null }));
  assert.ok(until.includes('2026-12-01T00:00:00Z'));
  assert.equal(new Set([none, until, forever]).size, 3);
  assert.equal(m.subscriptionBadge(row('a', true, unpublished)).tone, 'neutral');
  const badge = m.subscriptionBadge(row('a', true, { published: true, expires_at: 'X' }));
  assert.equal(badge.tone, 'ok');
  assert.ok(badge.label.includes('X'));
  assert.equal(m.subscriptionBadge(row('a', true, { published: true, expires_at: null })).tone, 'ok');
});

test('client edit: set-group under the old name, then rename', () => {
  const r = row('alice', true, unpublished);
  assert.deepEqual(m.editSteps('alice', r, { name: 'alice', group: 'PC' }), []);
  const both = m.editSteps('alice', r, { name: 'bob', group: 'LAB' });
  assert.deepEqual(both.map((s) => s.argv), [
    ['client', 'set-group', '--name', 'alice', '--group', 'LAB'],
    ['client', 'rename', '--name', 'alice', '--new-name', 'bob'],
  ]);
  assert.deepEqual(both.map((s) => Boolean(s.rename)), [false, true]);
  assert.deepEqual(m.editSteps('alice', r, { name: 'bob', group: 'PC' }).map((s) => s.argv[1]), ['rename']);
});

test('rename and delete follow error extras', () => {
  assert.equal(m.renamedName({ ok: true, data: { name: 'Bob' } }), 'Bob');
  assert.equal(m.renamedName({ ok: false, error: { code: 'partial', name: 'alice.2' } }), 'alice.2');
  assert.equal(m.renamedName({ ok: false, error: { code: 'confirmation_required' } }), null);
  assert.equal(m.clientDeleted({ ok: false, error: { code: 'partial', deleted: ['alice.2'] } }, 'alice.2'), true);
  assert.equal(m.clientDeleted({ ok: false, error: { code: 'remote_failed', deleted: [] } }, 'Bob'), false);
  assert.equal(m.clientDeleted({ ok: true, data: {} }, 'x'), true);
});

test('client data shows credentials, link state and connections', () => {
  const shown = {
    group: 'PC', nodes: ['de'], subscription: { url: 'https://h/sub/tok', expires_at: null, headers: [] },
    credentials: { vless_uuid: 'UUID-SECRET', hy2_password: 'HY2-SECRET' },
    connections: [{ node: 'de', mode: 'own', proxies: ['p1'] }],
    config: { path: '/g/PC/alice/config.yaml', exists: true },
  };
  const lines = m.clientDataLines(shown);
  const text = lines.map((l) => l.text).join('\n');
  for (const part of ['UUID-SECRET', 'HY2-SECRET', '/g/PC/alice/config.yaml', 'https://h/sub/tok', 'de', 'p1']) assert.ok(text.includes(part), part);
  assert.equal(lines.filter((l) => l.tone === 'info').length, 1, 'заголовок подключений по нодам');
  const bare = m.clientDataLines({ ...shown, connections: [], nodes: [], subscription: { url: null } });
  assert.ok(!bare.some((l) => l.tone === 'info') && !bare.map((l) => l.text).join('\n').includes('https://'));
  assert.equal(bare.length, m.clientDataLines({ ...shown, connections: [], subscription: null }).length);
});

test('client nodes change and argv', () => {
  assert.equal(m.nodesChange('alice', true, { mode: 'inherit' }), null);
  assert.deepEqual(m.nodesChange('alice', false, { mode: 'inherit' }), { kind: 'inherit', argv: m.inheritNodesArgv('alice') });
  assert.deepEqual(m.nodesChange('alice', true, { mode: 'own', nodes: ['de'] }), { kind: 'own', argv: ['client', 'nodes', '--name', 'alice', '--node', 'de'] });
  assert.deepEqual(m.clientNodesArgv('alice', ['de', 'ru']), ['client', 'nodes', '--name', 'alice', '--node', 'de', '--node', 'ru']);
  assert.deepEqual(m.inheritNodesArgv('alice'), ['client', 'nodes', '--name', 'alice', '--inherit']);
});

test('client connections: current proxies, argv', () => {
  assert.deepEqual(m.assignedProxies([{ node: 'de', mode: 'own', proxies: ['p1'] }, { node: 'ru', proxies: ['x'] }], 'de'), ['p1']);
  assert.deepEqual(m.discoveredProxies([{ node: 'de', groups: [], discovered: ['p1', 'p2'] }]), ['p1', 'p2']);
  assert.deepEqual(m.discoveredProxies(null), []);
  assert.deepEqual(m.clientConnectionsArgv('alice', 'de', ['p1', 'p2']),
    ['client', 'connections', '--name', 'alice', '--node', 'de', '--proxy', 'p1', '--proxy', 'p2']);
  assert.deepEqual(m.resetConnectionsArgv('alice', 'de'), ['client', 'connections', '--name', 'alice', '--node', 'de', '--reset']);
});

test('ttl menu and publish argv', () => {
  assert.notEqual(m.ttlOptions(null)[0].label, m.ttlOptions('2026-12-01T00:00:00Z')[0].label);
  assert.ok(m.ttlOptions('2026-12-01T00:00:00Z')[0].label.includes('2026-12-01T00:00:00Z'));
  assert.deepEqual(m.ttlOptions(null).map((o) => o.value), ['keep', '12h', '30d', '2w', 'custom']);
  assert.equal(m.currentExpiry(row('a', true, { published: true, expires_at: '2026-12-01T00:00:00Z' })), '2026-12-01T00:00:00Z');
  assert.equal(m.currentExpiry(row('a', true, { published: false, expires_at: '2026-12-01T00:00:00Z' })), null);
  assert.deepEqual(m.publishArgv('alice', null), ['subscription', 'publish', '--name', 'alice']);
  assert.deepEqual(m.publishArgv('alice', '7d'), ['subscription', 'publish', '--name', 'alice', '--ttl', '7d']);
  assert.equal(m.published({ ok: false, error: { code: 'partial' } }), true);
  assert.equal(m.published({ ok: false, error: { code: 'needs_setup' } }), false);
  assert.equal(m.ttlValue({ ttl: 'keep' }), null);
  assert.equal(m.ttlValue({ ttl: '30d' }), '30d');
  assert.equal(m.ttlValue({ ttl: 'custom', custom: '7d' }), '7d');
  // Правило ядра (`ttl_expiry`): 1–6 цифр без ведущего нуля и h|d|w.
  for (const ok of ['7d', '12h', '2w', '999999d']) assert.equal(m.ttlError(ok), null, ok);
  for (const bad of ['7', 'd7', '7 d', '0d', '07d', '1234567h', '7m', '', null]) assert.ok(m.ttlError(bad), String(bad));
});

test('host line: set, unset and unreadable are different states', () => {
  const set = m.hostLine({ ok: true, data: { node: 'de' } });
  const unset = m.hostLine({ ok: true, data: null });
  const failed = m.hostLine({ ok: false, error: { code: 'locked' } });
  assert.ok(set.text.endsWith('de'));
  assert.deepEqual([set.tone, unset.tone, failed.tone], [null, 'dim', 'warn']);
  assert.equal(new Set([set.text, unset.text, failed.text]).size, 3);
});

test('own nodes: missing ones are marked only once the node list is known', () => {
  assert.deepEqual(m.ownNodeRows(['de', 'gone'], null), [{ name: 'de', missing: false }, { name: 'gone', missing: false }]);
  assert.deepEqual(m.ownNodeRows(['de', 'gone'], nodes), [{ name: 'de', missing: false }, { name: 'gone', missing: true }]);
});

test('share bundle: link, expiry, headers, curl, json', () => {
  const share = m.shareModel({ client: 'alice', url: 'https://h/sub/tok', expires_at: '2026-12-01T00:00:00Z',
    headers: [{ name: 'profile-title', value: 'Essence' }] });
  assert.ok(share.title.endsWith('alice'));
  assert.equal(share.curl, "curl 'https://h/sub/tok'");
  assert.equal(share.json, '{"url":"https://h/sub/tok"}');
  assert.deepEqual(share.headers, ['profile-title: Essence']);
  assert.equal(share.expires, '2026-12-01T00:00:00Z');
  assert.equal(share.qr, 'https://h/sub/tok');
  const plain = m.shareModel({ client: 'alice', url: null, expires_at: null, headers: [] });
  assert.equal(plain.expires, null);
  assert.equal(plain.qr, null);
  assert.equal(m.curlLine("https://h/a'b"), "curl 'https://h/a'\\''b'");
});

test('header lines and removable headers', () => {
  const plain = m.headerLine({ name: 'X-A', value: '1', source: 'group' }, false);
  assert.equal(plain, 'X-A: 1');
  const sourced = m.headerLine({ name: 'X-A', value: '1', source: 'group' }, true);
  assert.ok(sourced.startsWith(plain) && sourced !== plain, 'источник — после значения');
  assert.notEqual(sourced, m.headerLine({ name: 'X-A', value: '1', source: 'client' }, true));
  assert.equal(m.headerLines([], true).length, 1, 'пустой список — одна строка');
  const data = [{ name: 'X-Default', value: 'a', source: 'default' }, { name: 'X-Own', value: 'b', source: 'client' }];
  assert.deepEqual(m.removableHeaders(data, true), ['X-Own']);
  assert.deepEqual(m.removableHeaders(data, false), ['X-Default', 'X-Own']);
  assert.deepEqual(m.headersArgv('client', 'alice', '--set', 'X-New=value'), ['subscription', 'headers', '--client', 'alice', '--set', 'X-New=value']);
  assert.deepEqual(m.headersArgv('group', 'PC', '--unset', 'X-G'), ['subscription', 'headers', '--group', 'PC', '--unset', 'X-G']);
});

test('generation summary reads partial from error and omits empty lines', () => {
  const partial = { ok: false, error: { code: 'partial', ok: ['a'], skipped: ['s'], failed: ['bad'], nodes_ok: ['de'], nodes_failed: ['ru'], dir: '/g' } };
  const label = new Map(m.GENERATE_FIELDS);
  const lines = m.summaryLines(m.generateResult(partial), m.GENERATE_FIELDS, 'EMPTY');
  assert.deepEqual(lines.map((l) => l.text), [
    `${label.get('ok')}: a`, `${label.get('skipped')}: s`, `${label.get('failed')}: bad`, `${label.get('nodes_failed')}: ru`, `${label.get('dir')}: /g`,
  ]);
  assert.deepEqual(lines.map((l) => l.tone), [null, null, 'warn', 'warn', null]);
  assert.equal(m.generateResult({ ok: false, error: { code: 'remote_failed' } }), null);
  const done = m.summaryLines(m.generateResult({ ok: true, data: { ok: ['alice'], skipped: [], failed: [], nodes_failed: [], dir: '/g' } }), m.GENERATE_FIELDS, 'EMPTY');
  assert.deepEqual(done.map((l) => l.text), [`${label.get('ok')}: alice`, `${label.get('dir')}: /g`]);
  assert.deepEqual(m.summaryLines({}, m.GENERATE_FIELDS, 'EMPTY'), [{ text: 'EMPTY', tone: 'dim' }]);
});

test('group template change', () => {
  assert.equal(m.templateChange('default.yaml', { template: 'default.yaml' }), null);
  assert.deepEqual(m.templateChange('default.yaml', { template: m.NEW_TEMPLATE, name: 'lab' }), { kind: 'create', name: 'lab' });
  assert.deepEqual(m.templateChange('default.yaml', { template: 'm.yaml' }), { kind: 'set', template: 'm.yaml' });
});

test('argv действий клиентов и групп', () => {
  assert.deepEqual(m.clientAddArgv({ name: 'alice', group: 'PC' }), ['client', 'add', '--name', 'alice', '--group', 'PC']);
  assert.deepEqual(m.clientDeleteArgv('alice'), ['client', 'delete', '--name', 'alice']);
  assert.deepEqual(m.clientSetGroupArgv('alice', 'TV'), ['client', 'set-group', '--name', 'alice', '--group', 'TV']);
  assert.deepEqual(m.discoverArgv('de'), ['conn', 'list', '--name', 'de', '--discover']);
  assert.deepEqual(m.subscriptionRotateArgv('alice'), ['subscription', 'rotate', '--name', 'alice']);
  assert.deepEqual(m.subscriptionRevokeArgv('alice'), ['subscription', 'revoke', '--name', 'alice']);
  assert.deepEqual(m.groupDeleteArgv('PC'), ['group', 'delete', '--name', 'PC']);
  assert.deepEqual(m.groupSetTemplateArgv('PC', 'm.yaml'), ['group', 'set-template', '--name', 'PC', '--template', 'm.yaml']);
  assert.deepEqual(m.groupTemplateCreateArgv('lab.yaml', 'PC'), ['template', 'create', '--name', 'lab.yaml', '--group', 'PC']);
});

// ─── Действия поверх ctx ────────────────────────────────────────────────────

const okReply = (data = null) => ({ ok: true, data });
const failure = (code = 'failed') => ({ ok: false, error: { code, message: '' } });
const PLAN = failure('confirmation_required');

/**
 * ctx по сценарию: `replies` — ответы `request`/`runConfirmed`/`nodeRequest` по порядку,
 * `answers` — ответы `form`/`choose`/`confirm`. `calls` — порядок вызовов.
 * Фоновое чтение `node list` предложения применить (`quiet`) не входит в
 * сценарий: отвечает `nodes` (по умолчанию нод нет) и пишется в `offers`.
 */
function fakeCtx({ replies = [], answers = [], nodes = [] } = {}) {
  const calls = [];
  const offers = [];
  const answer = (kind) => async (props) => { calls.push([kind, props]); return answers.shift(); };
  return {
    calls,
    offers,
    request: async (argv, options = {}) => {
      if (options.quiet && argv.join(' ') === 'node list') { offers.push(argv); return { ok: true, data: nodes }; }
      calls.push(['request', argv]);
      return replies.shift();
    },
    runConfirmed: async (title, question, argv) => { calls.push(['run', argv]); return replies.shift(); },
    nodeRequest: async (node, argv) => { calls.push(['node', argv]); return replies.shift(); },
    form: answer('form'),
    choose: answer('choose'),
    confirm: answer('confirm'),
    show: async (props) => { calls.push(['show', props]); },
    notify: (level) => calls.push(['notify', level]),
    failed: () => calls.push(['failed']),
    isFailure,
  };
}
const kinds = (ctx) => ctx.calls.map((call) => call[0]);
const commands = (ctx) => ctx.calls.filter((call) => ['request', 'run', 'node'].includes(call[0])).map((call) => call[1]);

test('execute и confirmed: сбой — failed, отказ от плана — не сбой', async () => {
  const a = fakeCtx({ replies: [failure()] });
  await m.execute(a, ['x']);
  assert.deepEqual(kinds(a), ['request', 'failed']);
  const b = fakeCtx({ replies: [PLAN, failure()] });
  await m.confirmed(b, 't', 'q', ['y']);
  assert.deepEqual(kinds(b), ['run']);
  await m.confirmed(b, 't', 'q', ['y']);
  assert.deepEqual(kinds(b), ['run', 'run', 'failed']);
});

test('добавление клиента: группы до формы, переход по имени из ответа', async () => {
  const groups = okReply([{ name: 'PC' }, { name: 'TV' }]);
  const went = [];
  const ctx = fakeCtx({ replies: [groups, okReply({ name: 'Alice' })], answers: [{ name: 'alice', group: 'TV' }] });
  await m.addClientFlow(ctx, (name) => went.push(name));
  assert.deepEqual(commands(ctx), [['group', 'list'], ['client', 'add', '--name', 'alice', '--group', 'TV']]);
  assert.deepEqual(ctx.calls[1][1].fields.find((f) => f.name === 'group').options.map((o) => o.value), ['PC', 'TV']);
  assert.deepEqual(went, ['Alice']);

  const cancelled = fakeCtx({ replies: [groups], answers: [null] });
  await m.addClientFlow(cancelled, (name) => went.push(name));
  assert.deepEqual(kinds(cancelled), ['request', 'form']);
  const unread = fakeCtx({ replies: [failure()] });
  await m.addClientFlow(unread, (name) => went.push(name));
  assert.deepEqual(kinds(unread), ['request', 'failed'], 'без групп форма не открывается');
  const refused = fakeCtx({ replies: [groups, failure('exists')], answers: [{ name: 'alice', group: 'PC' }] });
  await m.addClientFlow(refused, (name) => went.push(name));
  assert.deepEqual(went, ['Alice'], 'отказ ядра — без перехода');
});

test('добавление группы: argv одной командой, переход по имени из ответа', async () => {
  assert.deepEqual(m.addGroupArgv({ name: 'lab', template: 'default.yaml' }), ['group', 'add', '--name', 'lab']);
  assert.deepEqual(m.addGroupArgv({ name: 'lab', template: '' }), ['group', 'add', '--name', 'lab']);
  assert.deepEqual(m.addGroupArgv({ name: 'lab', template: 'm.yaml' }), ['group', 'add', '--name', 'lab', '--template', 'm.yaml']);

  const templates = okReply([{ name: 'default.yaml' }, { name: 'm.yaml' }]);
  const went = [];
  const plain = fakeCtx({ replies: [templates, okReply({ name: 'LAB', template: 'default.yaml' })], answers: [{ name: 'lab', template: 'default.yaml' }] });
  await m.addGroupFlow(plain, (name) => went.push(name));
  assert.deepEqual(commands(plain), [['template', 'list'], ['group', 'add', '--name', 'lab']]);
  assert.equal(plain.calls[1][1].fields.find((f) => f.name === 'template').value, 'default.yaml');

  const custom = fakeCtx({ replies: [templates, okReply({ name: 'LAB', template: 'm.yaml' })], answers: [{ name: 'lab', template: 'm.yaml' }] });
  await m.addGroupFlow(custom, (name) => went.push(name));
  assert.deepEqual(commands(custom), [['template', 'list'], ['group', 'add', '--name', 'lab', '--template', 'm.yaml']]);
  assert.deepEqual(went, ['LAB', 'LAB']);

  for (const code of ['not_found', 'invalid', 'conflict']) {
    const refused = fakeCtx({ replies: [templates, failure(code)], answers: [{ name: 'lab', template: 'm.yaml' }] });
    await m.addGroupFlow(refused, (name) => went.push(name));
    assert.deepEqual(kinds(refused), ['request', 'form', 'request', 'failed'], code);
  }
  assert.equal(went.length, 2, 'отказ ядра — без перехода');

  const cancelled = fakeCtx({ replies: [templates], answers: [null] });
  await m.addGroupFlow(cancelled, (name) => went.push(name));
  assert.deepEqual(kinds(cancelled), ['request', 'form']);
});

test('шаблон группы: назначение, новый шаблон — имя для редактора, без изменений — без команды', async () => {
  const templates = okReply([{ name: 'default.yaml' }, { name: 'm.yaml' }]);
  const set = fakeCtx({ replies: [templates, okReply()], answers: [{ template: 'm.yaml' }] });
  assert.equal(await m.groupTemplateFlow(set, 'PC', 'default.yaml'), null);
  assert.deepEqual(commands(set).at(-1), ['group', 'set-template', '--name', 'PC', '--template', 'm.yaml']);
  assert.ok(set.calls[1][1].fields[0].options.some((o) => o.value === m.NEW_TEMPLATE));

  const created = fakeCtx({ replies: [templates, okReply({ name: 'lab.yaml' })], answers: [{ template: m.NEW_TEMPLATE, name: 'lab' }] });
  assert.equal(await m.groupTemplateFlow(created, 'PC', 'default.yaml'), 'lab.yaml');
  assert.deepEqual(commands(created).at(-1), ['template', 'create', '--name', 'lab', '--group', 'PC']);

  const same = fakeCtx({ replies: [templates], answers: [{ template: 'default.yaml' }] });
  assert.equal(await m.groupTemplateFlow(same, 'PC', 'default.yaml'), null);
  assert.deepEqual(kinds(same), ['request', 'form']);

  const refused = fakeCtx({ replies: [templates, failure('exists')], answers: [{ template: m.NEW_TEMPLATE, name: 'lab' }] });
  assert.equal(await m.groupTemplateFlow(refused, 'PC', 'default.yaml'), null);
  assert.deepEqual(kinds(refused).at(-1), 'failed');
});

test('перенос клиента: другие группы, смена по плану; нет других — без формы', async () => {
  const groups = [{ name: 'PC' }, { name: 'TV' }];
  const ctx = fakeCtx({ replies: [okReply()], answers: [{ group: 'TV' }] });
  await m.moveClientFlow(ctx, 'PC', groups, 'alice');
  assert.deepEqual(ctx.calls[0][1].fields[0].options.map((o) => o.value), ['TV']);
  assert.deepEqual(commands(ctx), [['client', 'set-group', '--name', 'alice', '--group', 'TV']]);
  assert.equal(ctx.calls[1][0], 'run', 'смена группы — по плану');

  const alone = fakeCtx();
  await m.moveClientFlow(alone, 'PC', [{ name: 'PC' }], 'alice');
  assert.deepEqual(kinds(alone), ['notify']);
});

test('изменение клиента: смена группы, затем переименование; итог — новое имя', async () => {
  const groups = okReply([{ name: 'PC' }, { name: 'LAB' }]);
  const r = row('alice', true, unpublished);
  const both = fakeCtx({ replies: [groups, okReply(), okReply({ name: 'BOB' })], answers: [{ name: 'bob', group: 'LAB' }] });
  assert.equal(await m.editClientFlow(both, 'alice', r), 'BOB');
  assert.deepEqual(commands(both), [
    ['group', 'list'],
    ['client', 'set-group', '--name', 'alice', '--group', 'LAB'],
    ['client', 'rename', '--name', 'alice', '--new-name', 'bob'],
  ]);

  const partial = fakeCtx({ replies: [groups, failure('partial')], answers: [{ name: 'alice', group: 'LAB' }] });
  assert.equal(await m.editClientFlow(partial, 'alice', r), null);
  assert.equal(kinds(partial).at(-1), 'failed', 'partial смены группы — итог сбоя');

  const refused = fakeCtx({ replies: [groups, PLAN], answers: [{ name: 'bob', group: 'LAB' }] });
  assert.equal(await m.editClientFlow(refused, 'alice', r), null);
  assert.equal(commands(refused).length, 2, 'отказ от плана группы — без переименования');

  const cancelled = fakeCtx({ replies: [groups], answers: [null] });
  assert.equal(await m.editClientFlow(cancelled, 'alice', r), null);
  assert.deepEqual(kinds(cancelled), ['request', 'form']);
});

test('ноды клиента: свои — client nodes, возврат к группе — по плану, отмена и partial', async () => {
  const listed = okReply(nodes);
  const own = fakeCtx({ replies: [listed, okReply()], answers: [{ mode: 'own', nodes: ['ru'] }] });
  await m.clientNodesFlow(own, 'alice', row('alice', true, unpublished));
  assert.deepEqual(commands(own).at(-1), ['client', 'nodes', '--name', 'alice', '--node', 'ru']);
  assert.equal(own.calls.at(-1)[0], 'request');

  const back = fakeCtx({ replies: [listed, okReply()], answers: [{ mode: 'inherit' }] });
  await m.clientNodesFlow(back, 'alice', row('alice', false, unpublished));
  assert.deepEqual(back.calls[1][1].fields.find((f) => f.name === 'nodes').value, ['de']);
  assert.deepEqual(back.calls.at(-1), ['run', ['client', 'nodes', '--name', 'alice', '--inherit']]);

  const same = fakeCtx({ replies: [listed], answers: [{ mode: 'inherit' }] });
  await m.clientNodesFlow(same, 'alice', row('alice', true, unpublished));
  assert.deepEqual(kinds(same), ['request', 'form']);

  const cancelled = fakeCtx({ replies: [listed], answers: [null] });
  await m.clientNodesFlow(cancelled, 'alice', row('alice', true, unpublished));
  assert.deepEqual(kinds(cancelled), ['request', 'form']);

  const partial = fakeCtx({ replies: [listed, failure('partial')], answers: [{ mode: 'own', nodes: ['de'] }] });
  await m.clientNodesFlow(partial, 'alice', row('alice', true, unpublished));
  assert.equal(kinds(partial).at(-1), 'failed', '`partial` изменил ноды: форма не открывается снова');

  const retried = fakeCtx({ replies: [listed, failure('locked'), okReply()], answers: [{ mode: 'own', nodes: ['ru'] }, { mode: 'own', nodes: ['ru'] }] });
  await m.clientNodesFlow(retried, 'alice', row('alice', true, unpublished));
  assert.deepEqual(kinds(retried), ['request', 'form', 'request', 'failed', 'form', 'request']);
  const again = retried.calls[4][1].fields;
  assert.deepEqual([again.find((f) => f.name === 'mode').value, again.find((f) => f.name === 'nodes').value], ['own', ['ru']]);
});

test('подключения группы: записи одной группы объединяются', () => {
  assert.deepEqual(m.groupProxies([{ node: 'de', groups: [{ name: 'PC', proxies: ['p1'] }, { name: 'TV', proxies: ['x'] }, { name: 'PC', proxies: ['a,b', 'p1'] }] }], 'PC'),
    ['p1', 'a,b']);
});

test('подключения группы: нода по выбору (одна — сама), назначенные группе отмечены, conn set только для группы', async () => {
  const two = okReply([{ name: 'de', ip: '1.1.1.1', port: 22 }, { name: 'nl', ip: '2.2.2.2', port: 22 }]);
  const found = okReply([{ node: 'nl', groups: [{ name: 'PC', proxies: ['p2'] }, { name: 'TV', proxies: ['p1'] }], discovered: ['p1', 'p2'] }]);
  const ctx = fakeCtx({ replies: [two, found, okReply()], answers: [{ node: 'nl' }, { proxies: ['p1', 'p2'] }] });
  await m.groupConnectionsFlow(ctx, 'PC');
  assert.deepEqual(commands(ctx), [['node', 'list'], m.discoverArgv('nl'),
    ['conn', 'set', '--name', 'nl', '--assign', 'PC=p1', '--assign', 'PC=p2']]);
  assert.deepEqual(ctx.calls.filter((c) => c[0] === 'form')[1][1].fields[0].value, ['p2']);

  const one = fakeCtx({ replies: [okReply([{ name: 'de', ip: '1.1.1.1', port: 22 }]), okReply([{ node: 'de', discovered: ['p1'] }]), okReply()],
    answers: [{ proxies: ['p1'] }] });
  await m.groupConnectionsFlow(one, 'PC');
  assert.deepEqual(kinds(one), ['request', 'node', 'form', 'request'], 'единственная нода без выбора');

  const noNodes = fakeCtx({ replies: [okReply([])] });
  await m.groupConnectionsFlow(noNodes, 'PC');
  assert.deepEqual(kinds(noNodes), ['request', 'notify']);

  const nothing = fakeCtx({ replies: [okReply([{ name: 'de' }]), okReply([{ node: 'de', discovered: [] }])] });
  await m.groupConnectionsFlow(nothing, 'PC');
  assert.deepEqual(kinds(nothing), ['request', 'node', 'notify']);

  const same = fakeCtx({ replies: [okReply([{ name: 'de' }]), okReply([{ node: 'de', groups: [{ name: 'PC', proxies: ['p1'] }], discovered: ['p1', 'p2'] }])],
    answers: [{ proxies: ['p1'] }] });
  await m.groupConnectionsFlow(same, 'PC');
  assert.deepEqual(kinds(same), ['request', 'node', 'form'], 'без изменений команды нет');

  // Назначенное, но не найденное на ноде подключение показано отмеченным и снимается.
  const stale = fakeCtx({ replies: [okReply([{ name: 'de' }]), okReply([{ node: 'de', groups: [{ name: 'PC', proxies: ['gone'] }], discovered: [] }]), okReply()],
    answers: [{ proxies: [] }] });
  await m.groupConnectionsFlow(stale, 'PC');
  assert.deepEqual(stale.calls.find((c) => c[0] === 'form')[1].fields[0].value, ['gone']);
  assert.deepEqual(commands(stale).at(-1), ['conn', 'set', '--name', 'de', '--assign', 'PC=']);

  const cancelled = fakeCtx({ replies: [two], answers: [null] });
  await m.groupConnectionsFlow(cancelled, 'PC');
  assert.deepEqual(kinds(cancelled), ['request', 'form']);

  // Нода недоступна (сбой сообщает nodeRequest): сохранённые назначения без
  // SSH, без отметки «не найдено», снятие доступно; сбой записи — форма снова.
  const saved = okReply([{ node: 'de', groups: [{ name: 'PC', proxies: ['p1'] }] }]);
  const unset = ['conn', 'set', '--name', 'de', '--assign', 'PC='];
  const unreachable = fakeCtx({ replies: [okReply([{ name: 'de' }]), failure('remote_failed'), saved, failure('locked'), okReply()],
    answers: [{ proxies: [] }, { proxies: [] }] });
  await m.groupConnectionsFlow(unreachable, 'PC');
  assert.deepEqual(kinds(unreachable), ['request', 'node', 'request', 'notify', 'form', 'request', 'failed', 'form', 'request']);
  assert.deepEqual(unreachable.calls[2][1], ['conn', 'list', '--name', 'de']);
  const forms = unreachable.calls.filter((c) => c[0] === 'form').map((c) => c[1].fields[0]);
  assert.deepEqual([forms[0].options.map((o) => o.label), forms[0].value, forms[1].value], [['p1'], ['p1'], []]);
  assert.deepEqual(commands(unreachable).at(-1), unset);
});

test('подключения клиента на ноде: поиск через nodeRequest, отмечены назначенные', async () => {
  const assigned = [{ node: 'de', proxies: ['p2'] }];
  const found = okReply([{ node: 'de', discovered: ['p1', 'p2'] }]);
  const ctx = fakeCtx({ replies: [found, okReply()], answers: [{ proxies: ['p1'] }] });
  await m.clientConnectionsFlow(ctx, 'alice', 'de', assigned);
  assert.deepEqual(ctx.calls[0], ['node', m.discoverArgv('de')]);
  assert.deepEqual(ctx.calls[1][1].fields[0].value, ['p2']);
  assert.deepEqual(commands(ctx).at(-1), m.clientConnectionsArgv('alice', 'de', ['p1']));

  // Ни найденных, ни назначенных — предупреждение без формы.
  const none = fakeCtx({ replies: [okReply([{ node: 'de', discovered: [] }])] });
  await m.clientConnectionsFlow(none, 'alice', 'de', []);
  assert.deepEqual(kinds(none), ['node', 'notify']);

  // Нода недоступна (сбой сообщает nodeRequest): сохранённые назначения без
  // SSH, без отметки «не найдено»; сбой записи открывает форму снова с выбранным.
  const saved = okReply([{ node: 'de', groups: [] }]);
  const unreachable = fakeCtx({ replies: [failure('remote_failed'), saved, failure('locked'), okReply()],
    answers: [{ proxies: ['p2'] }, { proxies: ['p2'] }] });
  await m.clientConnectionsFlow(unreachable, 'alice', 'de', assigned);
  assert.deepEqual(kinds(unreachable), ['node', 'request', 'notify', 'form', 'request', 'failed', 'form', 'request']);
  assert.deepEqual(unreachable.calls[1][1], ['conn', 'list', '--name', 'de']);
  assert.deepEqual(unreachable.calls[3][1].fields[0].options.map((o) => o.label), ['p2']);
  assert.deepEqual(unreachable.calls[6][1].fields[0].value, ['p2']);
  const lost = fakeCtx({ replies: [failure('remote_failed'), failure('locked')] });
  await m.clientConnectionsFlow(lost, 'alice', 'de', assigned);
  assert.deepEqual(kinds(lost), ['node', 'request', 'failed']);

  const cancelled = fakeCtx({ replies: [found], answers: [null] });
  await m.clientConnectionsFlow(cancelled, 'alice', 'de', assigned);
  assert.deepEqual(kinds(cancelled), ['node', 'form']);
});

test('подключения клиента на ноде: назначенные, но не найденные (awg-<peer>, устаревшие) отмечены и сохраняются', async () => {
  const assigned = [{ node: 'de', proxies: ['p1', 'awg-alice', 'old'] }];
  const found = okReply([{ node: 'de', discovered: ['p1', 'p2', 'AWG'] }]);
  const ctx = fakeCtx({ replies: [found, okReply()], answers: [] });
  ctx.form = async (props) => { ctx.calls.push(['form', props]); return { proxies: props.fields[0].value }; };
  await m.clientConnectionsFlow(ctx, 'alice', 'de', assigned);
  const [field] = ctx.calls[1][1].fields;
  assert.deepEqual(field.options.map((option) => option.value), ['p1', 'p2', 'AWG', 'awg-alice', 'old']);
  assert.deepEqual(field.value, ['p1', 'awg-alice', 'old']);
  const labels = Object.fromEntries(field.options.map((option) => [option.value, option.label]));
  assert.equal(labels['awg-alice'], 'awg-alice', 'клиент AmneziaWG при найденном AWG не помечен');
  assert.notEqual(labels.old, 'old', 'устаревшее подключение помечено');
  assert.deepEqual(commands(ctx).at(-1), m.clientConnectionsArgv('alice', 'de', ['p1', 'awg-alice', 'old']));

  // Ничего не найдено, но назначения есть — форма с ними, а не «пусто».
  const only = fakeCtx({ replies: [okReply([{ node: 'de', discovered: [] }])], answers: [null] });
  await m.clientConnectionsFlow(only, 'alice', 'de', assigned);
  assert.deepEqual(kinds(only), ['node', 'form']);
});

test('публикация подписки: срок формой, ссылка после успеха и partial, отмена — без команды', async () => {
  const r = row('alice', true, unpublished);
  const shared = [];
  const share = async (name) => { shared.push(name); };
  const keep = fakeCtx({ replies: [okReply()], answers: [{ ttl: 'keep' }] });
  await m.publishFlow(keep, 'alice', r, share);
  assert.deepEqual(commands(keep), [m.publishArgv('alice', null)]);
  const custom = fakeCtx({ replies: [failure('partial')], answers: [{ ttl: 'custom', custom: '7d' }] });
  await m.publishFlow(custom, 'alice', r, share);
  assert.deepEqual(commands(custom), [m.publishArgv('alice', '7d')]);
  assert.deepEqual(shared, ['alice', 'alice']);

  const refused = fakeCtx({ replies: [failure('remote_failed')], answers: [{ ttl: 'keep' }] });
  await m.publishFlow(refused, 'alice', r, share);
  assert.equal(kinds(refused).at(-1), 'failed');
  const cancelled = fakeCtx({ answers: [null] });
  await m.publishFlow(cancelled, 'alice', r, share);
  assert.deepEqual(kinds(cancelled), ['form']);
  assert.equal(shared.length, 2);
});

test('подписки: хост-нода через nodeRequest, перенос по плану, заголовки группы', async () => {
  const listed = okReply(nodes);
  const host = fakeCtx({ replies: [listed, okReply()], answers: [{ node: 'ru' }] });
  await m.subscriptionHostFlow(host, 'de');
  assert.equal(host.calls[1][1].fields[0].value, 'de');
  assert.deepEqual(host.calls.at(-1), ['node', ['subscription', 'host', '--name', 'ru']]);
  const noHost = fakeCtx({ replies: [listed], answers: [null] });
  await m.subscriptionHostFlow(noHost, null);
  assert.deepEqual(kinds(noHost), ['request', 'form']);

  const moved = fakeCtx({ replies: [listed, failure('remote_failed')], answers: [{ node: 'ru' }] });
  await m.migrateFlow(moved);
  assert.deepEqual(moved.calls.filter((c) => c[0] === 'run').map((c) => c[1]), [['subscription', 'migrate', '--name', 'ru']]);
  assert.equal(kinds(moved).at(-1), 'failed');
  const declined = fakeCtx({ replies: [listed, PLAN], answers: [{ node: 'ru' }] });
  await m.migrateFlow(declined);
  assert.notEqual(kinds(declined).at(-1), 'failed', 'отказ от плана — не сбой');

  const published = fakeCtx({ replies: [okReply({ published: ['alice'], failed: [] })] });
  await m.publishAllFlow(published);
  assert.deepEqual(kinds(published), ['run', 'show']);

  const headers = fakeCtx({ replies: [okReply([{ name: 'PC' }]), okReply({ headers: [] })], answers: [{ group: 'PC' }, null] });
  await m.groupHeadersFlow(headers);
  assert.deepEqual(commands(headers), [['group', 'list'], m.headersArgv('group', 'PC')]);
  const noGroup = fakeCtx({ replies: [okReply([{ name: 'PC' }])], answers: [null] });
  await m.groupHeadersFlow(noGroup);
  assert.deepEqual(kinds(noGroup), ['request', 'form']);
});

test('конфиг клиента: client config → текст; не создан или сбой — null', async () => {
  const ready = fakeCtx({ replies: [okReply({ exists: true, content: 'proxies:\n' })] });
  assert.equal(await m.readClientConfig(ready, 'a'), 'proxies:\n');
  assert.deepEqual(commands(ready), [m.clientConfigArgv('a')]);
  assert.deepEqual(m.clientConfigArgv('a'), ['client', 'config', '--name', 'a']);
  const missing = fakeCtx({ replies: [okReply({ exists: false })] });
  assert.equal(await m.readClientConfig(missing, 'a'), null);
  assert.deepEqual(kinds(missing), ['request', 'notify']);
  const broken = fakeCtx({ replies: [failure()] });
  assert.equal(await m.readClientConfig(broken, 'a'), null);
  assert.deepEqual(kinds(broken), ['request', 'failed']);
});

test('предложение применить: после client add и conn set — node list, вопрос, node apply --pending', async () => {
  const pending = [{ name: 'de', status: 'pending' }, { name: 'nl', status: 'applied' }];
  const report = { ok: true, data: { applied: ['de'], failed: [], unchanged: [] } };
  const yes = fakeCtx({ replies: [{ ok: true, data: { name: 'c' } }, report], answers: [true], nodes: pending });
  await m.execute(yes, ['client', 'add', '--name', 'c', '--group', 'PC']);
  assert.deepEqual(yes.offers, [['node', 'list']]);
  assert.deepEqual(commands(yes), [['client', 'add', '--name', 'c', '--group', 'PC'], ['node', 'apply', '--pending']]);
  assert.deepEqual(kinds(yes), ['request', 'confirm', 'node', 'show']);
  // Отказ — без применения; без ожидающих нод — без вопроса.
  const no = fakeCtx({ replies: [{ ok: true, data: {} }], answers: [false], nodes: pending });
  await m.execute(no, ['conn', 'set', '--name', 'de', '--assign', 'PC=VLESS TCP']);
  assert.deepEqual(kinds(no), ['request', 'confirm']);
  const none = fakeCtx({ replies: [{ ok: true, data: {} }], nodes: [{ name: 'de', status: 'applied' }] });
  await m.execute(none, ['client', 'nodes', '--name', 'c', '--inherit']);
  assert.deepEqual(kinds(none), ['request']);
  // Прочие команды не предлагают применение; сбой — тоже.
  const other = fakeCtx({ replies: [{ ok: true, data: {} }, failure()], nodes: pending });
  await m.execute(other, ['group', 'add', '--name', 'g']);
  await m.execute(other, ['client', 'add', '--name', 'c', '--group', 'PC']);
  assert.deepEqual(other.offers, []);
  // По плану: client delete подтверждён — предложение.
  const deleted = fakeCtx({ replies: [{ ok: true, data: {} }], answers: [false], nodes: pending });
  await m.confirmed(deleted, 'T', 'Q?', ['client', 'delete', '--name', 'c']);
  assert.deepEqual(deleted.offers, [['node', 'list']]);
});

test('генерация: nodes_pending в итоге и предложение применить', async () => {
  assert.ok(m.GENERATE_FIELDS.some(([field]) => field === 'nodes_pending'));
  const ctx = fakeCtx({ replies: [{ ok: true, data: { ok: ['c'], nodes_pending: ['de'] } }], answers: [false], nodes: [{ name: 'de', status: 'pending' }] });
  await m.runGenerate(ctx, ['--all']);
  assert.deepEqual(ctx.offers, [['node', 'list']]);
  assert.deepEqual(kinds(ctx), ['request', 'show', 'confirm']);
  const clean = fakeCtx({ replies: [{ ok: true, data: { ok: ['c'] } }] });
  await m.runGenerate(clean, ['--all']);
  assert.deepEqual(clean.offers, []);
});
