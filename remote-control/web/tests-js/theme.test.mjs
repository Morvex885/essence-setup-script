// Тесты theme.js: выбор, тема документа, слежение за системой; theme-boot.js
// (классический скрипт до отрисовки) даёт ту же тему, что readChoice + resolve.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { THEME_KEY, THEME_OPTIONS, readChoice, storeChoice, resolve, apply, watch } from '../assets/js/theme.js';

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

/** Тема из `theme-boot.js` в `node:vm` с поддельными окном, хранилищем и matchMedia. */
function bootTheme(storage, prefersDark, withMatchMedia = true) {
  const attributes = {};
  const window = { localStorage: storage };
  if (withMatchMedia) window.matchMedia = (query) => ({ matches: query === '(prefers-color-scheme: dark)' && prefersDark });
  const document = { documentElement: { setAttribute: (name, value) => { attributes[name] = value; } } };
  vm.runInNewContext(readFileSync(new URL('../assets/js/theme-boot.js', import.meta.url), 'utf8'), { window, document });
  return attributes['data-theme'];
}

test('theme-boot.js совпадает с readChoice + resolve', () => {
  const broken = { getItem: () => { throw new Error('denied'); } };
  const stores = [store(), store({ [THEME_KEY]: 'neon' }), broken, ...THEME_OPTIONS.map((option) => store({ [THEME_KEY]: option.value }))];
  for (const storage of stores) {
    for (const dark of [false, true]) {
      assert.equal(bootTheme(storage, dark), resolve(readChoice(storage), dark), `${readChoice(storage)}, dark=${dark}`);
    }
    assert.equal(bootTheme(storage, true, false), resolve(readChoice(storage), false), 'без matchMedia — светлая система');
  }
});
