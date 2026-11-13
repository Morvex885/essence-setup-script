// Тесты catalog-model.js: argv и подписи шаблонов, генерации и подписок
// (эталон — `tui/src/clients.rs` и его тесты).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  templateList, templateCreate, templateShow, templateImport, templateInput, findTemplate, templateContent,
  templateCheck, templateDelete, templateGroups, templateKind, groupOptions, problemCounts, annotations,
  droppedRanges, variantOptions, effectiveVariant, problemVariant, inVariant, NO_GROUP,
  PUBLISH_FIELDS, GENERATE_ALL, generateGroup, generateClient, generateScope, SUBSCRIPTION_HOST,
  subscriptionSetHost, SUBSCRIPTION_LIST, SUBSCRIPTION_PUBLISH_ALL, subscriptionMigrate, subscriptionHost,
  subscriptionState, subscriptionRow, publishSummary,
} from '../assets/js/screens/catalog-model.js';
import { summaryLines, GENERATE_FIELDS, generateFlow } from '../assets/js/screens/clients-model.js';

/** Строка итога `«подпись»: значение` по таблице полей. */
const line = (fields, key, value, tone = null) => ({ text: `${new Map(fields).get(key)}: ${value}`, tone });

test('шаблоны: argv команд и input.file', () => {
  assert.deepEqual(templateList(), ['template', 'list']);
  assert.deepEqual(templateCreate('x'), ['template', 'create', '--name', 'x']);
  assert.deepEqual(templateCreate('x', 'default.yaml'), ['template', 'create', '--name', 'x', '--from', 'default.yaml']);
  assert.deepEqual(templateCheck('m.yaml'), ['template', 'check', '--name', 'm.yaml']);
  assert.deepEqual(templateDelete('m.yaml'), ['template', 'delete', '--name', 'm.yaml']);
  assert.deepEqual(templateGroups('m.yaml', ['PC', 'TV']), ['template', 'groups', '--name', 'm.yaml', '--group', 'PC', '--group', 'TV']);
  assert.deepEqual(templateGroups('m.yaml', []), ['template', 'groups', '--name', 'm.yaml']);
  assert.deepEqual(templateShow('m.yaml'), ['template', 'show', '--name', 'm.yaml']);
  assert.deepEqual(templateImport('m.yaml'), ['template', 'import', '--name', 'm.yaml']);
  assert.deepEqual(templateInput('mode: rule\n'), { file: 'mode: rule\n' });
});

test('шаблоны: вид, поиск строки и содержимое', () => {
  const list = [
    { name: 'default.yaml', source: 'builtin', overrides: false, groups: ['PC'] },
    { name: 'm.yaml', source: 'custom', overrides: false, groups: [] },
    { name: 'lab.yaml', source: 'custom', overrides: true, groups: [] },
  ];
  assert.deepEqual(list.map(templateKind), ['builtin', 'custom', 'override']);
  assert.equal(templateKind(null), 'builtin');
  assert.equal(findTemplate(list, 'm.yaml'), list[1]);
  assert.equal(findTemplate(list, 'gone'), null);
  assert.equal(findTemplate(null, 'm.yaml'), null);
  assert.equal(templateContent({ content: 'mode: rule\n' }), 'mode: rule\n');
  assert.equal(templateContent({ content: null }), null);
  assert.equal(templateContent(null), null);
});

test('шаблоны: выбор групп с текущим шаблоном и отметками', () => {
  const groups = [{ name: 'PC', template: 'm.yaml' }, { name: 'TV', template: 'default.yaml' }, { name: null }];
  const { options, selected } = groupOptions(groups, 'm.yaml');
  assert.deepEqual(options.map((o) => [o.value, o.label]), [['PC', 'PC — сейчас: m.yaml'], ['TV', 'TV — сейчас: default.yaml']]);
  assert.deepEqual(selected, ['PC']);
  assert.deepEqual(groupOptions(null, 'm.yaml'), { options: [], selected: [] });
});

test('шаблоны: отчёт проверки — счётчики, отметки по варианту, выпавшие строки', () => {
  assert.deepEqual(problemCounts({ errors: 3, warnings: 250 }), { errors: 3, warnings: 250 });
  assert.deepEqual(problemCounts(null), { errors: 0, warnings: 0 });
  const problems = [
    { line: 4, column: 3, level: 'error', message: 'all', variant: null },
    { line: 1, column: 1, level: 'warning', message: 'nogroup', variant: '' },
    { line: 9, column: 2, level: 'error', message: 'pc', variant: 'PC' },
  ];
  assert.deepEqual(annotations(problems, NO_GROUP), [
    { row: 3, column: 2, text: 'all', type: 'error' }, { row: 0, column: 0, text: 'nogroup', type: 'warning' },
  ]);
  assert.deepEqual(annotations(problems, 'PC').map((a) => a.text), ['all', 'pc']);
  assert.deepEqual(annotations(null, NO_GROUP), []);
  const variants = [{ tag: null, dropped: [[30, 39]] }, { tag: 'PC', dropped: [[5, 6], [8, 8]] }];
  assert.deepEqual(droppedRanges(variants, NO_GROUP), [[30, 39]]);
  assert.deepEqual(droppedRanges(variants, 'PC'), [[5, 6], [8, 8]]);
  assert.deepEqual(droppedRanges(variants, 'TV'), []);
  assert.deepEqual(variantOptions(variants).map((o) => o.value), [NO_GROUP, 'PC']);
  // Выбранный тег исчез из отчёта — показывается «без группы».
  assert.equal(effectiveVariant(variants, 'PC'), 'PC');
  assert.equal(effectiveVariant(variants, 'TV'), NO_GROUP);
  assert.equal(effectiveVariant(null, 'PC'), NO_GROUP);
  assert.deepEqual(problems.map(problemVariant), [null, NO_GROUP, 'PC']);
  assert.deepEqual(problems.map((p) => inVariant(p, 'PC')), [true, false, true]);
});

test('итог генерации: пустые поля пропущены, ошибки жёлтые', () => {
  const partial = { ok: ['a'], skipped: ['s'], failed: ['bad'], nodes_ok: ['de'], nodes_failed: ['ru'], dir: '/g' };
  assert.deepEqual(summaryLines(partial, GENERATE_FIELDS, 'EMPTY'), [
    line(GENERATE_FIELDS, 'ok', 'a'), line(GENERATE_FIELDS, 'skipped', 's'), line(GENERATE_FIELDS, 'failed', 'bad', 'warn'),
    line(GENERATE_FIELDS, 'nodes_failed', 'ru', 'warn'), line(GENERATE_FIELDS, 'dir', '/g'),
  ]);
  const single = { ok: ['alice'], skipped: [], failed: [], nodes_ok: [], nodes_failed: [], dir: '/g' };
  assert.equal(summaryLines(single, GENERATE_FIELDS, 'EMPTY').length, 2);
  assert.deepEqual(summaryLines({}, GENERATE_FIELDS, 'EMPTY'), [{ text: 'EMPTY', tone: 'dim' }]);
});

test('итог публикации: число 0 пропущено, сводка ошибки из error', () => {
  assert.deepEqual(summaryLines({ published: ['alice'], skipped: [], failed: [], removed: 0 }, PUBLISH_FIELDS, 'EMPTY'),
    [line(PUBLISH_FIELDS, 'published', 'alice')]);
  assert.deepEqual(summaryLines({ published: [], removed: 2 }, PUBLISH_FIELDS, 'EMPTY'),
    [line(PUBLISH_FIELDS, 'removed', '2')]);
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
    form: async () => { calls.push('form'); return { scope: 'group', group: 'PC' }; },
    show: async (props) => { calls.push(['show', props.context]); },
  };
  await generateFlow(ctx, { client: 'alice' });
  assert.deepEqual(calls, [['generate', '--client', 'alice'], ['show', [line(GENERATE_FIELDS, 'ok', 'alice')]]]);
  calls.length = 0;
  await generateFlow(ctx);
  assert.equal(failed, 1);
  assert.ok(!calls.includes('form'), 'без списков форма не открывается');
  calls.length = 0;
  lists = { ok: true, data: [{ name: 'PC' }] };
  await generateFlow(ctx);
  assert.deepEqual(calls.slice(2, 4), ['form', ['generate', '--group', 'PC']]);
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
