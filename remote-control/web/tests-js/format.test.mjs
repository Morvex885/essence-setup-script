// Тесты format.js: форматирование значений, массивы ответов, журнал.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  asList, strings, text, joined, versionLabel, syncState, sourceLabel,
  activity, activityIndicator, openPanel, OPEN_PANEL_WARNING,
  errorMessage, readInputFile, MAX_INPUT, FILE_TOO_LARGE, filterJournal, appendJournal,
} from '../assets/js/format.js';

test('asList и strings: не массив — пустой список, строки — только строки', () => {
  const list = [1, 'a'];
  assert.equal(asList(list), list);
  for (const value of [null, undefined, 'a', { length: 1 }]) assert.deepEqual(asList(value), []);
  assert.deepEqual(strings(['a', 1, null, 'b']), ['a', 'b']);
  assert.deepEqual(strings(null), []);
});

test('text: null, undefined и пустая строка — тире', () => {
  assert.equal(text(null), '—');
  assert.equal(text(undefined), '—');
  assert.equal(text(''), '—');
  assert.equal(text('lab'), 'lab');
  assert.equal(text(8377), '8377');
  assert.equal(text(false), 'false');
  assert.equal(text({ a: 1 }), '{"a":1}');
});

test('joined: пустой и отсутствующий список — одна и та же отметка', () => {
  const none = joined([]);
  assert.ok(none);
  assert.equal(joined(null), none);
  assert.equal(joined(undefined), none);
  assert.equal(joined(['de', 'nl']), 'de, nl');
  assert.equal(joined([1, 2]), '1, 2');
});

test('versionLabel: приставка v ровно один раз', () => {
  assert.equal(versionLabel('1.2.3'), 'v1.2.3');
  assert.equal(versionLabel('v1.2.3'), 'v1.2.3');
  assert.equal(versionLabel(''), 'v');
});

test('syncState: тон по состоянию, неизвестное — как нет связи', () => {
  assert.equal(syncState('clean').tone, 'ok');
  assert.equal(syncState('pending').tone, 'warn');
  assert.equal(syncState('conflict').tone, 'warn');
  assert.deepEqual(syncState(null), syncState('conflict'));
  assert.equal(new Set(['clean', 'pending', 'conflict'].map((state) => syncState(state).label)).size, 3);
});

test('sourceLabel: GitHub с репозиторием и синхронизацией, локальная — без', () => {
  const github = sourceLabel({ type: 'github', repo: 'user/rc', sync: 'clean' });
  assert.ok(github.label.endsWith('user/rc'));
  assert.deepEqual(github.sync, syncState('clean'));
  const local = sourceLabel({ type: 'local' });
  assert.notEqual(local.label, github.label);
  assert.equal(local.sync, null);
});

test('activity: группы команд как в app.rs::activity', () => {
  const generic = activity([]);
  for (const argv of [['node', 'list'], ['group', 'list'], ['node', 'show', '--name', 'de']]) assert.equal(activity(argv), generic, argv.join(' '));
  const remote = activity(['node', 'harden', '--name', 'de']);
  assert.notEqual(remote, generic);
  assert.equal(activity(['telegram', 'status', '--all']), remote);
  assert.equal(activity(['conn', 'sync']), remote);
  assert.equal(activity(['source', 'github-push']), activity(['source', 'github-rotate-key']));
  const distinct = [
    ['session', 'open'], ['status'], ['source', 'github-login'], ['source', 'github-fetch'], ['source', 'github-delete-repo'],
    ['source', 'github-anything'], ['subscription', 'publish-all'], ['self', 'version'], ['node', 'harden'], [],
  ].map(activity);
  assert.equal(new Set(distinct).size, distinct.length);
});

test('activityIndicator: строка шапки с командой, без команды — пусто', () => {
  assert.ok(activityIndicator('group add').endsWith('group add'));
  assert.equal(activityIndicator(null), '');
  assert.equal(activityIndicator(''), '');
});

test('openPanel: web status приоритетнее, иначе listener + пароль', () => {
  const hello = { listener: { loopback: false, tls: true } };
  assert.equal(openPanel(hello, { script_password: false }, null), true);
  assert.equal(openPanel(hello, { script_password: true }, null), false);
  assert.equal(openPanel({ listener: { loopback: true } }, { script_password: false }, null), false);
  assert.equal(openPanel({ listener: null }, { script_password: false }, null), false);
  assert.equal(openPanel(hello, { script_password: true }, { open: true }), true);
  assert.equal(openPanel(hello, { script_password: false }, { open: false }), false);
  assert.ok(OPEN_PANEL_WARNING);
});

test('errorMessage: текст ошибки ядра, иначе одна общая подпись', () => {
  assert.equal(errorMessage({ error: { code: 'not_found', message: 'node de not found' } }), 'node de not found');
  const fallback = errorMessage(null);
  assert.ok(fallback);
  assert.equal(errorMessage({ error: {} }), fallback);
  assert.equal(errorMessage({ error: { code: 'x', message: '' } }), fallback);
});

test('readInputFile: UTF-8 не больше 1 МиБ, как у меню', async () => {
  assert.deepEqual(await readInputFile(new Blob(['mode: rule\n'])), { text: 'mode: rule\n' });
  assert.deepEqual(await readInputFile(new Blob(['\uFEFFkey'])), { text: '\uFEFFkey' }, 'BOM сохраняется');
  assert.equal((await readInputFile(new Blob(['a'.repeat(MAX_INPUT)]))).text.length, MAX_INPUT);
  assert.deepEqual(await readInputFile(new Blob(['a'.repeat(MAX_INPUT + 1)])), { error: FILE_TOO_LARGE });
  assert.deepEqual(await readInputFile(new Blob([new Uint8Array([0xff, 0x00])])), { error: null }, 'не UTF-8');
});

test('filterJournal: все, только ошибки, только предупреждения', () => {
  const entries = [
    { id: 1, level: 'info', text: 'a' }, { id: 2, level: 'error', text: 'b' },
    { id: 3, level: 'warn', text: 'c' }, { id: 4, level: 'success', text: 'd' }, { id: 5, level: 'error', text: 'e' },
  ];
  assert.equal(filterJournal(entries, 'all'), entries);
  assert.deepEqual(filterJournal(entries, 'error').map((entry) => entry.id), [2, 5]);
  assert.deepEqual(filterJournal(entries, 'warn').map((entry) => entry.id), [3]);
  assert.equal(filterJournal(entries, 'other'), entries);
  assert.deepEqual(filterJournal(null, 'error'), []);
});

test('appendJournal: предел длины; повтор фоновой записи подряд не добавляется', () => {
  const entry = (id, level, text) => ({ id, level, text });
  let journal = [];
  journal = appendJournal(journal, entry(1, 'warn', 'x'), 3, false);
  const same = appendJournal(journal, entry(2, 'warn', 'x'), 3, false);
  assert.equal(same, journal, 'та же запись подряд — журнал не меняется');
  assert.equal(appendJournal(journal, entry(2, 'warn', 'x'), 3).length, 2, 'обычные записи повторяются');
  assert.equal(appendJournal(journal, entry(2, 'error', 'x'), 3, false).length, 2, 'другой уровень — новая запись');
  journal = appendJournal(journal, entry(2, 'info', 'y'), 3);
  journal = appendJournal(journal, entry(3, 'warn', 'x'), 3, false);
  assert.deepEqual(journal.map((item) => item.id), [1, 2, 3], 'не подряд — записывается');
  journal = appendJournal(journal, entry(4, 'info', 'z'), 3);
  assert.deepEqual(journal.map((item) => item.id), [2, 3, 4]);
});
