// Тесты catalog-model.js: argv и подписи шаблонов, генерации и подписок
// (эталон — `tui/src/clients.rs` и его тесты).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  templateList, templateCreate, templateShow, templateImport, templateInput, templateLabel, findTemplate,
  templateContext, templatePath, templateContent,
  PUBLISH_FIELDS, GENERATE_ALL, generateGroup, generateClient, generationContext, SUBSCRIPTION_HOST,
  subscriptionSetHost, SUBSCRIPTION_LIST, SUBSCRIPTION_PUBLISH_ALL, subscriptionMigrate, subscriptionHost,
  subscriptionState, subscriptionRow, publishSummary,
} from '../assets/js/screens/catalog-model.js';
import { pickOptions, pick, summaryLines, GENERATE_FIELDS } from '../assets/js/screens/clients-model.js';

test('шаблоны: argv команд и input.file', () => {
  assert.deepEqual(templateList(), ['template', 'list']);
  assert.deepEqual(templateCreate('x'), ['template', 'create', '--name', 'x']);
  assert.deepEqual(templateShow('m.yaml'), ['template', 'show', '--name', 'm.yaml']);
  assert.deepEqual(templateImport('m.yaml'), ['template', 'import', '--name', 'm.yaml']);
  assert.deepEqual(templateInput('mode: rule\n'), { file: 'mode: rule\n' });
});

test('шаблоны: подписи списка и карточки', () => {
  const list = [{ name: 'default.yaml', source: 'builtin', groups: ['PC'] }, { name: 'm.yaml', source: 'custom', groups: [] }];
  assert.equal(templateLabel(list[0]), 'default.yaml  (встроенный)');
  assert.equal(templateLabel(list[1]), 'm.yaml  (пользовательский)');
  assert.equal(findTemplate(list, 'm.yaml'), list[1]);
  assert.equal(findTemplate(list, 'gone'), null);
  assert.equal(findTemplate(null, 'm.yaml'), null);
  assert.deepEqual(templateContext(list[0]), ['Источник: встроенный', 'Группы: PC']);
  assert.deepEqual(templateContext(list[1]), ['Источник: пользовательский', 'Группы: нет']);
});

test('шаблоны: путь и содержимое template show', () => {
  const shown = { name: 'm.yaml', source: 'builtin', path: null, content: 'mode: rule\nproxies:\n' };
  assert.equal(templatePath(shown), 'Путь: встроенный шаблон');
  assert.equal(templatePath({ path: '/s/templates/m.yaml' }), 'Путь: /s/templates/m.yaml');
  assert.equal(templateContent(shown), 'mode: rule\nproxies:\n');
  assert.equal(templateContent({ content: null }), null);
  assert.equal(templateContent(null), null);
});

test('выбор: подписи нод и прочих объектов', () => {
  assert.equal(pickOptions('node', [{ name: 'ru', ip: '10.0.0.2', port: 2222 }])[0].label, 'ru  10.0.0.2:2222');
  assert.equal(pickOptions('group', [{ name: 'PC' }])[0].label, 'PC');
  assert.deepEqual(pickOptions('client', [{ name: 'alice' }]), [{ value: 'alice', label: 'alice', tone: 'view' }]);
  assert.deepEqual(pickOptions('client', null), []);
});

test('выбор: читает список, сбой — ctx.failed без окна', async () => {
  const calls = [];
  let failed = 0;
  const ctx = {
    request: async (argv) => { calls.push(argv); return calls.length === 1 ? { ok: false, error: { code: 'x' } } : { ok: true, data: [{ name: 'PC' }] }; },
    failed: () => { failed += 1; },
    choose: async (props) => { calls.push(props); return props.options[0].value; },
  };
  assert.equal(await pick(ctx, 'group', 'Генерация по группе'), null);
  assert.equal(failed, 1);
  assert.equal(await pick(ctx, 'group', 'Генерация по группе'), 'PC');
  assert.deepEqual(calls[0], ['group', 'list']);
  assert.equal(calls[2].title, 'Генерация по группе');
  assert.equal(calls[2].empty, 'Нет объектов для выбора');
});

test('итог генерации: пустые поля пропущены, ошибки жёлтые', () => {
  const partial = { ok: ['a'], skipped: ['s'], failed: ['bad'], nodes_ok: ['de'], nodes_failed: ['ru'], dir: '/g' };
  assert.deepEqual(summaryLines(partial, GENERATE_FIELDS, 'Нет результатов'), [
    { text: 'Готово: a', tone: null }, { text: 'Пропущено: s', tone: null }, { text: 'Ошибки: bad', tone: 'warn' },
    { text: 'Ноды с ошибкой: ru', tone: 'warn' }, { text: 'Каталог: /g', tone: null },
  ]);
  const single = { ok: ['alice'], skipped: [], failed: [], nodes_ok: [], nodes_failed: [], dir: '/g' };
  assert.equal(summaryLines(single, GENERATE_FIELDS, 'Нет результатов').length, 2);
  assert.deepEqual(summaryLines({}, GENERATE_FIELDS, 'Нет результатов'), [{ text: 'Нет результатов', tone: 'dim' }]);
});

test('итог публикации: число 0 пропущено, сводка ошибки из error', () => {
  assert.deepEqual(summaryLines({ published: ['alice'], skipped: [], failed: [], removed: 0 }, PUBLISH_FIELDS, 'Нечего публиковать.'),
    [{ text: 'Опубликовано: alice', tone: null }]);
  assert.deepEqual(summaryLines({ published: [], removed: 2 }, PUBLISH_FIELDS, 'Нечего публиковать.'),
    [{ text: 'Удалено устаревших: 2', tone: null }]);
  const failed = { code: 'remote_failed', published: [], skipped: [], failed: ['alice'], removed: 0 };
  assert.equal(publishSummary({ ok: false, error: failed }), failed);
  assert.equal(publishSummary({ ok: false, error: { code: 'confirmation_required' } }), null);
  assert.deepEqual(publishSummary({ ok: true, data: { published: [] } }), { published: [] });
});

test('генерация: argv хвостов и контекст групп', () => {
  assert.deepEqual(GENERATE_ALL, ['--all']);
  assert.deepEqual(generateGroup('PC'), ['--group', 'PC']);
  assert.deepEqual(generateClient('alice'), ['--client', 'alice']);
  assert.deepEqual(generationContext([{ name: 'PC', template: 'default.yaml' }]), ['PC → default.yaml']);
  assert.deepEqual(generationContext([]), [{ text: 'Нет групп', tone: 'dim' }]);
});

test('подписки: argv и хост-нода', () => {
  assert.deepEqual(SUBSCRIPTION_HOST, ['subscription', 'host']);
  assert.deepEqual(subscriptionSetHost('de'), ['subscription', 'host', '--name', 'de']);
  assert.deepEqual(SUBSCRIPTION_LIST, ['subscription', 'list']);
  assert.deepEqual(SUBSCRIPTION_PUBLISH_ALL, ['subscription', 'publish-all']);
  assert.deepEqual(subscriptionMigrate('ru'), ['subscription', 'migrate', '--name', 'ru']);
  assert.deepEqual(subscriptionHost({ node: 'de', base_url: 'https://h' }), { node: 'de', baseUrl: 'Базовый URL: https://h' });
  assert.equal(subscriptionHost({ node: '' }), null);
  assert.equal(subscriptionHost(null), null);
});

test('подписки: состояния списка', () => {
  assert.deepEqual(subscriptionState('active'), { label: 'действует', tone: 'ok' });
  assert.deepEqual(subscriptionState('expired'), { label: 'истекла', tone: 'warn' });
  assert.deepEqual(subscriptionState('unlimited'), { label: 'без срока', tone: 'dim' });
  assert.deepEqual(subscriptionState('unknown'), { label: 'срок неизвестен', tone: 'dim' });
  assert.deepEqual(subscriptionRow({ client: 'u', expires_at: null, state: 'unlimited' }),
    { prefix: 'u  —  ', state: { label: 'без срока', tone: 'dim' } });
});
