// Тесты theme.js: выбор, тема документа, слежение за системой.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { THEME_KEY, readChoice, storeChoice, resolve, apply, watch } from '../assets/js/theme.js';

const store = (initial = {}) => {
  const data = new Map(Object.entries(initial));
  return { getItem: (key) => (data.has(key) ? data.get(key) : null), setItem: (key, value) => data.set(key, String(value)), data };
};

test('readChoice: неизвестное, пустое и недоступное — system', () => {
  assert.equal(readChoice(store({ [THEME_KEY]: 'dark' })), 'dark');
  assert.equal(readChoice(store({ [THEME_KEY]: 'light' })), 'light');
  assert.equal(readChoice(store({ [THEME_KEY]: 'neon' })), 'system');
  assert.equal(readChoice(store()), 'system');
  assert.equal(readChoice(null), 'system');
  assert.equal(readChoice({ getItem: () => { throw new Error('denied'); } }), 'system');
  const saved = store();
  storeChoice(saved, 'light');
  assert.equal(readChoice(saved), 'light');
  assert.deepEqual([...saved.data.keys()], [THEME_KEY], 'хранится только выбор темы');
});

test('resolve: выбор и системная настройка', () => {
  assert.equal(resolve('system', true), 'essence-dark');
  assert.equal(resolve('system', false), 'essence-light');
  assert.equal(resolve('light', true), 'essence-light');
  assert.equal(resolve('dark', false), 'essence-dark');
});

test('watch: применяет тему и следит за системной настройкой', () => {
  const listeners = new Set();
  const media = { matches: false, addEventListener: (_e, fn) => listeners.add(fn), removeEventListener: (_e, fn) => listeners.delete(fn) };
  const doc = { documentElement: { dataset: {} } };
  const win = { document: doc, matchMedia: () => media };
  const seen = [];
  const stop = watch(win, store(), (choice, theme) => seen.push([choice, theme]));
  assert.equal(doc.documentElement.dataset.theme, 'essence-light');
  media.matches = true;
  for (const fn of listeners) fn();
  assert.equal(doc.documentElement.dataset.theme, 'essence-dark');
  assert.deepEqual(seen, [['system', 'essence-light'], ['system', 'essence-dark']]);
  stop();
  assert.equal(listeners.size, 0);
  apply(doc, 'essence-light');
  assert.equal(doc.documentElement.dataset.theme, 'essence-light');
});
