// Тесты router.js: разбор и сборка `#/раздел/параметр/вкладка`.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parse, format, navigate, consumeTicket } from '../assets/js/router.js';

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
