// Тесты router.js: разбор и сборка `#/раздел/параметр/вкладка`, решение защиты ухода.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parse, format, navigate, consumeTicket, routeDecision, hashUrl, screenKey, screenRoute } from '../assets/js/router.js';

test('parse: раздел, параметр и вкладка декодируются по отдельности', () => {
  assert.deepEqual(parse('#/nodes/a%2Fb/awg'), { name: 'nodes', param: 'a/b', tab: 'awg' });
  assert.deepEqual(parse('#/nodes/vps-1'), { name: 'nodes', param: 'vps-1', tab: null });
  assert.deepEqual(parse('#/clients'), { name: 'clients', param: null, tab: null });
  assert.deepEqual(parse(''), { name: 'summary', param: null, tab: null });
  assert.deepEqual(parse('#/'), { name: 'summary', param: null, tab: null });
  // Лишние сегменты отбрасываются; неверная кодировка остаётся как есть.
  assert.deepEqual(parse('#/nodes/a/b/c/d'), { name: 'nodes', param: 'a', tab: 'b' });
  assert.deepEqual(parse('#/nodes/%E0%A4%A'), { name: 'nodes', param: '%E0%A4%A', tab: null });
});

test('format: обратная сборка и вкладка только при параметре', () => {
  assert.equal(format('nodes', 'a/b', 'awg'), '#/nodes/a%2Fb/awg');
  assert.deepEqual(parse(format('nodes', 'a/b', 'awg')), { name: 'nodes', param: 'a/b', tab: 'awg' });
  assert.equal(format('nodes', 'vps-1', 'connections'), '#/nodes/vps-1/connections');
  assert.equal(format('nodes'), '#/nodes');
  assert.equal(format('nodes', null, 'awg'), '#/nodes');
  assert.equal(format(''), '#/');
  for (const name of ['клиент «1»', 'a b', '100%']) {
    assert.equal(parse(format('clients', name, 'subscription')).param, name);
  }
});

test('navigate и consumeTicket работают с переданным окном', () => {
  const win = { location: { hash: '#ticket=AB12', pathname: '/', search: '' }, history: { replaceState: (_s, _t, url) => { win.replaced = url; } } };
  assert.equal(consumeTicket(win), 'AB12');
  assert.equal(win.replaced, '/');
  navigate(win, 'clients', 'alice', 'access');
  assert.equal(win.location.hash, '#/clients/alice/access');
  assert.equal(consumeTicket(win), null);
});

test('защита ухода: один вопрос, новые смены ждут его итога, без защиты — сразу', () => {
  const base = { hash: '#/nodes', current: '#/templates/a', guarded: true, pending: false };
  assert.equal(routeDecision(base), 'ask');
  assert.equal(routeDecision({ ...base, pending: true }), 'wait');
  assert.equal(routeDecision({ ...base, guarded: false }), 'apply');
  // Тот же адрес (первый вызов `start`, восстановление) — без вопроса.
  assert.equal(routeDecision({ ...base, hash: '#/templates/a' }), 'apply');
});

test('hashUrl и screenKey: адрес для replaceState и ключ экрана без вкладки', () => {
  const location = { pathname: '/', search: '?x=1' };
  assert.equal(hashUrl(location, '#/templates/a'), '/?x=1#/templates/a');
  assert.equal(hashUrl(location, ''), '/?x=1');
  assert.equal(screenKey(parse('#/nodes/a/awg')), screenKey(parse('#/nodes/a/connections')));
  assert.notEqual(screenKey(parse('#/nodes/a')), screenKey(parse('#/nodes/b')));
});

test('screenRoute: только собственные разделы, остальное (и имена прототипа) — сводка', () => {
  const screens = { summary: () => null, nodes: () => null };
  const route = { name: 'nodes', param: 'a', tab: 'awg' };
  assert.equal(screenRoute(route, screens), route);
  for (const name of ['nope', 'constructor', 'hasOwnProperty', '__proto__', 'toString', '']) {
    assert.deepEqual(screenRoute({ name, param: 'a', tab: null }, screens), { name: 'summary', param: 'a', tab: null }, name);
  }
});
