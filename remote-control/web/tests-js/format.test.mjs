// Тесты format.js: подписи и форматирование (TUI-эталоны).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  text, joined, versionLabel, syncState, sourceLabel, scriptsState,
  templateSource, activity, activityIndicator, openPanel, OPEN_PANEL_WARNING,
  errorMessage,
} from '../assets/js/format.js';

test('text: null, undefined и пустая строка — тире', () => {
  assert.equal(text(null), '—');
  assert.equal(text(undefined), '—');
  assert.equal(text(''), '—');
  assert.equal(text('lab'), 'lab');
  assert.equal(text(8377), '8377');
  assert.equal(text(false), 'false');
  assert.equal(text({ a: 1 }), '{"a":1}');
});

test('joined: пустой список — «нет»', () => {
  assert.equal(joined([]), 'нет');
  assert.equal(joined(null), 'нет');
  assert.equal(joined(undefined), 'нет');
  assert.equal(joined(['de', 'nl']), 'de, nl');
  assert.equal(joined([1, 2]), '1, 2');
});

test('versionLabel: приставка v ровно один раз', () => {
  assert.equal(versionLabel('1.2.3'), 'v1.2.3');
  assert.equal(versionLabel('v1.2.3'), 'v1.2.3');
  assert.equal(versionLabel(''), 'v');
});

test('syncState: подписи как в system.rs', () => {
  assert.deepEqual(syncState('clean'), { label: 'синхронизировано', tone: 'ok' });
  assert.deepEqual(syncState('pending'), { label: 'ожидает отправки', tone: 'warn' });
  assert.deepEqual(syncState('conflict'), { label: 'нет связи', tone: 'warn' });
  assert.deepEqual(syncState(null), { label: 'нет связи', tone: 'warn' });
});

test('sourceLabel: GitHub и локальная', () => {
  assert.deepEqual(sourceLabel({ type: 'github', repo: 'user/rc', sync: 'clean' }), {
    label: 'GitHub user/rc',
    sync: { label: 'синхронизировано', tone: 'ok' },
  });
  const local = sourceLabel({ type: 'local' });
  assert.equal(local.label, 'локальная');
  assert.equal(local.sync, null);
});

test('scriptsState: состояния скриптов ноды', () => {
  assert.equal(scriptsState('missing'), 'скрипты отсутствуют');
  assert.equal(scriptsState('outdated'), 'скрипты устарели');
  assert.equal(scriptsState('broken'), 'установка повреждена');
  assert.equal(scriptsState('unknown'), 'версия скриптов неизвестна');
  assert.equal(scriptsState(''), 'версия скриптов неизвестна');
});

test('templateSource: встроенный и пользовательский', () => {
  assert.equal(templateSource({ source: 'builtin' }), 'встроенный');
  assert.equal(templateSource({ source: 'file' }), 'пользовательский');
  assert.equal(templateSource(null), 'пользовательский');
});

test('activity: подписи как в app.rs::activity', () => {
  assert.equal(activity(['session', 'open']), 'Открытие сессии…');
  assert.equal(activity(['status']), 'Загрузка состояния…');
  assert.equal(activity(['source', 'github-login']), 'Вход в GitHub: следуйте инструкциям в журнале и браузере…');
  assert.equal(activity(['source', 'github-fetch']), 'Загрузка конфигурации из GitHub…');
  assert.equal(activity(['source', 'github-delete-repo']), 'Удаление репозитория GitHub…');
  assert.equal(activity(['source', 'github-anything']), 'Обмен данными с GitHub…');
  assert.equal(activity(['node', 'list']), 'Выполняется…');
  assert.equal(activity(['node', 'harden', '--name', 'de']), 'Подключение к серверам…');
  assert.equal(activity(['telegram', 'status', '--all']), 'Подключение к серверам…');
  assert.equal(activity(['subscription', 'publish-all']), 'Публикация подписок на серверах…');
  assert.equal(activity(['self', 'version']), 'Проверка обновлений…');
  assert.equal(activity(['group', 'list']), 'Выполняется…');
  assert.equal(activity([]), 'Выполняется…');
});

test('activityIndicator: строка шапки', () => {
  assert.equal(activityIndicator('group add'), 'Выполняется: group add');
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
  assert.ok(OPEN_PANEL_WARNING.includes('доступна всем'));
});

test('errorMessage: текст ошибки ядра', () => {
  assert.equal(errorMessage({ error: { code: 'not_found', message: 'Нода «de» не найдена.' } }), 'Нода «de» не найдена.');
  assert.equal(errorMessage({ error: {} }), 'Операция не выполнена.');
  assert.equal(errorMessage(null), 'Операция не выполнена.');
  assert.equal(errorMessage({ error: { code: 'x', message: '' } }), 'Операция не выполнена.');
});
