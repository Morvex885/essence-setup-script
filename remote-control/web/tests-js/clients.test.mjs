// Модель экранов клиентов и групп против `remote-control/tui/src/clients.rs`.
import test from 'node:test';
import assert from 'node:assert/strict';
import * as m from '../assets/js/screens/clients-model.js';

const row = (name, inherit, subscription) => ({ name, group: 'PC', inherit_nodes: inherit, nodes: ['de'], subscription });
const unpublished = { published: false, expires_at: null };
const nodes = [{ name: 'de', ip: '127.0.0.1', port: 22 }, { name: 'ru', ip: '10.0.0.2', port: 2222 }];

test('labels of nodes and clients', () => {
  assert.equal(m.nodeLabel(nodes[0]), 'de  127.0.0.1:22');
  assert.equal(m.clientLabel(row('bob', true, unpublished)), 'bob  (PC)');
  assert.equal(m.joined([]), 'нет');
  assert.equal(m.joined(['a', 1, 'b']), 'a, b');
});

test('client delete argv repeats --name in selection order', () => {
  assert.deepEqual(m.deleteClientsArgv(['alice', 'bob']), ['client', 'delete', '--name', 'alice', '--name', 'bob']);
});

test('subscription state and list badge', () => {
  assert.equal(m.subscriptionState(row('a', true, unpublished)), 'нет');
  assert.equal(m.subscriptionState(row('a', true, { published: true, expires_at: '2026-12-01T00:00:00Z' })), 'опубликована до 2026-12-01T00:00:00Z');
  assert.equal(m.subscriptionState(row('a', true, { published: true, expires_at: null })), 'опубликована, без срока');
  assert.equal(m.subscriptionBadge(row('a', true, unpublished)).tone, 'neutral');
  assert.deepEqual(m.subscriptionBadge(row('a', true, { published: true, expires_at: 'X' })), { tone: 'ok', label: 'до X' });
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
  const text = m.clientDataLines(shown).map((l) => l.text).join('\n');
  for (const part of ['VLESS UUID: UUID-SECRET', 'Hysteria2 пароль: HY2-SECRET', 'Конфиг: /g/PC/alice/config.yaml (создан)',
    'Подписка: https://h/sub/tok', 'Подключения по нодам:', '  de (свои): p1']) assert.ok(text.includes(part), part);
  const bare = m.clientDataLines({ ...shown, connections: [], nodes: [], subscription: { url: null } }).map((l) => l.text).join('\n');
  assert.ok(bare.includes('Ноды: нет') && bare.includes('ссылка недоступна') && !bare.includes('Подключения по нодам'));
  assert.ok(m.clientDataLines({ ...shown, subscription: null }).some((l) => l.text === 'Подписка: нет'));
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
  assert.equal(m.ttlOptions(null)[0].label, 'Без срока');
  assert.ok(m.ttlOptions('2026-12-01T00:00:00Z')[0].label.startsWith('Оставить текущий срок'));
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
  assert.equal(m.ttlError('7d'), null);
  assert.ok(m.ttlError('7') && m.ttlError('d7') && m.ttlError('7 d'));
});

test('host line', () => {
  assert.equal(m.hostLine({ ok: true, data: { node: 'de' } }).text, 'Хост подписок: de');
  assert.ok(m.hostLine({ ok: true, data: null }).text.startsWith('Хост подписок не задан'));
  assert.ok(m.hostLine({ ok: false, error: { code: 'x' } }).text.startsWith('Хост подписок не задан'));
});

test('share bundle: link, expiry, headers, curl, json', () => {
  const share = m.shareModel({ client: 'alice', url: 'https://h/sub/tok', expires_at: '2026-12-01T00:00:00Z',
    headers: [{ name: 'profile-title', value: 'Essence' }] });
  assert.equal(share.title, 'Подписка: alice');
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
  assert.equal(m.headerLine({ name: 'X-A', value: '1', source: 'group' }, true), 'X-A: 1  [группа]');
  assert.equal(m.headerLine({ name: 'X-G', value: '1' }, false), 'X-G: 1');
  assert.deepEqual(m.headerLines([], true), ['Нет заголовков']);
  const data = [{ name: 'X-Default', value: 'a', source: 'default' }, { name: 'X-Own', value: 'b', source: 'client' }];
  assert.deepEqual(m.removableHeaders(data, true), ['X-Own']);
  assert.deepEqual(m.removableHeaders(data, false), ['X-Default', 'X-Own']);
  assert.deepEqual(m.headersArgv('client', 'alice', '--set', 'X-New=value'), ['subscription', 'headers', '--client', 'alice', '--set', 'X-New=value']);
  assert.deepEqual(m.headersArgv('group', 'PC', '--unset', 'X-G'), ['subscription', 'headers', '--group', 'PC', '--unset', 'X-G']);
});

test('generation summary reads partial from error and omits empty lines', () => {
  const partial = { ok: false, error: { code: 'partial', ok: ['a'], skipped: ['s'], failed: ['bad'], nodes_ok: ['de'], nodes_failed: ['ru'], dir: '/g' } };
  const lines = m.summaryLines(m.generateResult(partial), m.GENERATE_FIELDS, 'Нет результатов');
  assert.deepEqual(lines.map((l) => l.text), ['Готово: a', 'Пропущено: s', 'Ошибки: bad', 'Ноды с ошибкой: ru', 'Каталог: /g']);
  assert.deepEqual(lines.map((l) => l.tone), [null, null, 'warn', 'warn', null]);
  assert.equal(m.generateResult({ ok: false, error: { code: 'remote_failed' } }), null);
  const done = m.summaryLines(m.generateResult({ ok: true, data: { ok: ['alice'], skipped: [], failed: [], nodes_failed: [], dir: '/g' } }), m.GENERATE_FIELDS, 'Нет результатов');
  assert.deepEqual(done.map((l) => l.text), ['Готово: alice', 'Каталог: /g']);
  assert.deepEqual(m.summaryLines({}, m.GENERATE_FIELDS, 'Нет результатов'), [{ text: 'Нет результатов', tone: 'dim' }]);
});

test('group template change', () => {
  assert.equal(m.templateChange('default.yaml', { template: 'default.yaml' }), null);
  assert.deepEqual(m.templateChange('default.yaml', { template: m.NEW_TEMPLATE, name: 'lab' }), { kind: 'create', name: 'lab' });
  assert.deepEqual(m.templateChange('default.yaml', { template: 'm.yaml' }), { kind: 'set', template: 'm.yaml' });
});
