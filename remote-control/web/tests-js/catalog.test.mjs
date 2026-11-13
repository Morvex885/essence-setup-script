// Тесты catalog-model.js: argv и подписи шаблонов, генерации и подписок
// (эталон — `tui/src/clients.rs` и его тесты).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  templateList, templateCreate, templateShow, templateImport, templateInput, templateLabel, findTemplate,
  templateContext, templatePath, templateContent,
  PUBLISH_FIELDS, GENERATE_ALL, generateGroup, generateClient, generateScope, SUBSCRIPTION_HOST,
  subscriptionSetHost, SUBSCRIPTION_LIST, SUBSCRIPTION_PUBLISH_ALL, subscriptionMigrate, subscriptionHost,
  subscriptionState, subscriptionRow, publishSummary,
} from '../assets/js/screens/catalog-model.js';
import { summaryLines, GENERATE_FIELDS } from '../assets/js/screens/clients-model.js';
import { generateFlow } from '../assets/js/screens/generate.js';

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

test('генерация: argv хвостов и выбор формы', () => {
  assert.deepEqual(GENERATE_ALL, ['--all']);
  assert.deepEqual(generateGroup('PC'), ['--group', 'PC']);
  assert.deepEqual(generateClient('alice'), ['--client', 'alice']);
  assert.deepEqual(generateScope({ scope: 'all' }), ['--all']);
  assert.deepEqual(generateScope({ scope: 'group', group: 'PC' }), ['--group', 'PC']);
  assert.deepEqual(generateScope({ scope: 'client', client: 'alice' }), ['--client', 'alice']);
});

test('генерация: пресет без формы, сбой чтения списков — без формы', async () => {
  const calls = [];
  let failed = 0;
  let lists = { ok: false, error: { code: 'x' } };
  const ctx = {
    request: async (argv) => {
      calls.push(argv);
      if (argv[0] === 'generate') return { ok: true, data: { ok: ['alice'] } };
      return lists;
    },
    failed: () => { failed += 1; },
    form: async (spec) => { calls.push(spec.title); return { scope: 'group', group: 'PC' }; },
    show: async () => {},
  };
  await generateFlow(ctx, { client: 'alice' });
  assert.deepEqual(calls, [['generate', '--client', 'alice']]);
  calls.length = 0;
  await generateFlow(ctx);
  assert.equal(failed, 1);
  assert.ok(!calls.includes('Генерация конфигов'));
  calls.length = 0;
  lists = { ok: true, data: [{ name: 'PC' }] };
  await generateFlow(ctx);
  assert.deepEqual(calls.at(-1), ['generate', '--group', 'PC']);
});

test('подписки: argv и хост-нода', () => {
  assert.deepEqual(SUBSCRIPTION_HOST, ['subscription', 'host']);
  assert.deepEqual(subscriptionSetHost('de'), ['subscription', 'host', '--name', 'de']);
  assert.deepEqual(SUBSCRIPTION_LIST, ['subscription', 'list']);
  assert.deepEqual(SUBSCRIPTION_PUBLISH_ALL, ['subscription', 'publish-all']);
  assert.deepEqual(subscriptionMigrate('ru'), ['subscription', 'migrate', '--name', 'ru']);
  assert.deepEqual(subscriptionHost({ node: 'de', base_url: 'https://h' }), { node: 'de', baseUrl: 'https://h' });
  assert.equal(subscriptionHost({ node: '' }), null);
  assert.equal(subscriptionHost(null), null);
});

test('подписки: состояния списка', () => {
  assert.deepEqual(subscriptionState('active'), { label: 'действует', tone: 'ok' });
  assert.deepEqual(subscriptionState('expired'), { label: 'истекла', tone: 'warn' });
  assert.deepEqual(subscriptionState('unlimited'), { label: 'без срока', tone: 'dim' });
  assert.deepEqual(subscriptionState('unknown'), { label: 'срок неизвестен', tone: 'dim' });
  assert.deepEqual(subscriptionRow({ client: 'u', expires_at: null, state: 'unlimited' }),
    { client: 'u', expires: '—', state: { label: 'без срока', tone: 'dim' } });
});
