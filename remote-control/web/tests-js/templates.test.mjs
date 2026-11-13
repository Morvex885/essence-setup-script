// Действия редактора шаблонов (`screens/templates-model.js`) с поддельным ctx:
// argv, порядок вызовов и итоги, без текстов окон.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  settleDraft, saveTemplate, importTemplateFile, deleteLabel, deleteTemplate, editTemplateGroups, checkRunner,
  GROUPS_UNCHANGED, DRAFT_REPLACED,
} from '../assets/js/screens/templates-model.js';
import { TEMPLATE_FILE_UNREADABLE, DEFAULT_GROUP_HINT, DEFAULT_TEMPLATE } from '../assets/js/screens/catalog-model.js';
import { isFailure } from '../assets/js/flows.js';
import { FILE_TOO_LARGE } from '../assets/js/format.js';

const PLAN = { ok: false, error: { code: 'confirmation_required', message: '' } };

/** ctx по сценарию: `replies` — ответы `runConfirmed`/`request` по порядку, `answers` — `confirm`/`form`. */
function fakeCtx({ replies = [], answers = [] } = {}) {
  const calls = [];
  const next = () => replies.shift();
  const ctx = {
    calls,
    runConfirmed: async (title, question, argv, opts = {}) => { calls.push(['run', argv, opts.input, title]); return next(); },
    request: async (argv) => { calls.push(['request', argv]); return next(); },
    confirm: async (props) => { calls.push(['confirm', props.question]); return answers.shift(); },
    form: async (props) => { calls.push(['form', props]); return answers.shift(); },
    notify: (level, text) => calls.push(['notify', level, text]),
    failed: () => calls.push(['failed']),
    isFailure,
  };
  return ctx;
}

test('черновик после сохранения: сохранённый текст снимается, новая правка остаётся', () => {
  assert.equal(settleDraft('a', 'a'), null);
  assert.equal(settleDraft('ab', 'a'), 'ab');
  assert.equal(settleDraft(null, 'a'), null);
});

test('сохранение: import с черновиком; отказ от плана — не сбой, ошибка — failed', async () => {
  const ok = fakeCtx({ replies: [{ ok: true, data: { name: 'm.yaml' } }] });
  assert.equal(await saveTemplate(ok, 'm.yaml', 'proxies:\n'), true);
  assert.deepEqual(ok.calls.map((call) => call.slice(0, 3)), [['run', ['template', 'import', '--name', 'm.yaml'], { file: 'proxies:\n' }]]);
  const declined = fakeCtx({ replies: [PLAN] });
  assert.equal(await saveTemplate(declined, 'm.yaml', 'x'), false);
  assert.equal(declined.calls.some((call) => call[0] === 'failed'), false);
  const broken = fakeCtx({ replies: [{ ok: false, error: { code: 'failed' } }] });
  assert.equal(await saveTemplate(broken, 'm.yaml', 'x'), false);
  assert.deepEqual(broken.calls.at(-1), ['failed']);
});

test('импорт: нечитаемый файл, вопрос о черновике, затем план', async () => {
  const unreadable = fakeCtx();
  assert.equal(await importTemplateFile(unreadable, 'm.yaml', null, null, true), false);
  assert.deepEqual(unreadable.calls, [['notify', 'warn', TEMPLATE_FILE_UNREADABLE]]);
  const big = fakeCtx();
  await importTemplateFile(big, 'm.yaml', null, FILE_TOO_LARGE, false);
  assert.deepEqual(big.calls, [['notify', 'warn', FILE_TOO_LARGE]]);

  const kept = fakeCtx({ answers: [false] });
  assert.equal(await importTemplateFile(kept, 'm.yaml', 'f', null, true), false);
  assert.deepEqual(kept.calls.map((call) => call[0]), ['confirm'], 'отказ — без команды');
  assert.ok(kept.calls[0][1].startsWith(DRAFT_REPLACED));

  const replaced = fakeCtx({ answers: [true], replies: [{ ok: true, data: {} }] });
  assert.equal(await importTemplateFile(replaced, 'm.yaml', 'f', null, true), true);
  assert.deepEqual(replaced.calls.map((call) => call[0]), ['confirm', 'run']);
  assert.deepEqual(replaced.calls[1].slice(1, 3), [['template', 'import', '--name', 'm.yaml'], { file: 'f' }]);

  const clean = fakeCtx({ replies: [{ ok: true, data: {} }] });
  assert.equal(await importTemplateFile(clean, 'm.yaml', 'f', null, false), true);
  assert.deepEqual(clean.calls.map((call) => call[0]), ['run']);
});

test('удаление и сброс к встроенному: одна команда, разные подписи по виду', async () => {
  const custom = { name: 'm.yaml', source: 'custom', overrides: false };
  const override = { name: DEFAULT_TEMPLATE, source: 'custom', overrides: true };
  assert.notEqual(deleteLabel(custom), deleteLabel(override));
  const a = fakeCtx({ replies: [{ ok: true, data: {} }] });
  assert.equal(await deleteTemplate(a, custom), true);
  assert.deepEqual(a.calls[0][1], ['template', 'delete', '--name', 'm.yaml']);
  const b = fakeCtx({ replies: [PLAN] });
  assert.equal(await deleteTemplate(b, override), false);
  assert.deepEqual(b.calls[0][1], ['template', 'delete', '--name', DEFAULT_TEMPLATE]);
  assert.notEqual(a.calls[0][3], b.calls[0][3], 'сброс и удаление — разные окна плана');
  assert.equal(b.calls.length, 1, 'отказ от плана — не сбой');
});

test('группы: пустой выбор сбрасывает все, без изменений — сообщение, у default.yaml свои группы закреплены', async () => {
  const groups = { ok: true, data: [{ name: 'PC', template: 'm.yaml' }, { name: 'TV', template: DEFAULT_TEMPLATE }] };
  const reset = fakeCtx({ replies: [groups, { ok: true, data: { assigned: [], reset: ['PC'] } }], answers: [{ groups: [] }] });
  assert.equal(await editTemplateGroups(reset, 'm.yaml'), true);
  assert.deepEqual(reset.calls[0], ['request', ['group', 'list']]);
  assert.deepEqual(reset.calls[1][1].fields[0].value, ['PC']);
  assert.deepEqual(reset.calls[2][1], ['template', 'groups', '--name', 'm.yaml']);

  const same = fakeCtx({ replies: [groups, { ok: true, data: { assigned: [], reset: [] } }], answers: [{ groups: ['PC'] }] });
  assert.equal(await editTemplateGroups(same, 'm.yaml'), false);
  assert.deepEqual(same.calls[2][1], ['template', 'groups', '--name', 'm.yaml', '--group', 'PC']);
  assert.deepEqual(same.calls.at(-1), ['notify', 'info', GROUPS_UNCHANGED]);

  const fixed = fakeCtx({ replies: [groups], answers: [null] });
  assert.equal(await editTemplateGroups(fixed, DEFAULT_TEMPLATE), false);
  const options = fixed.calls[1][1].fields[0].options;
  assert.deepEqual(options.map((o) => [o.value, Boolean(o.disabled), o.hint ?? null]), [['PC', false, null], ['TV', true, DEFAULT_GROUP_HINT]]);
  assert.equal(fixed.calls.length, 2, 'отмена формы — без команды');

  const failed = fakeCtx({ replies: [{ ok: false, error: { code: 'failed' } }] });
  assert.equal(await editTemplateGroups(failed, 'm.yaml'), false);
  assert.deepEqual(failed.calls.at(-1), ['failed']);
});

test('очередь проверок: один запрос, из ожидающих — последний, устаревший ответ не доставляется', async () => {
  const started = [];
  const resolvers = [];
  const delivered = [];
  const runner = checkRunner((text) => {
    started.push(text);
    return new Promise((resolve) => resolvers.push(() => resolve(`r:${text}`)));
  }, (reply, text) => delivered.push([reply, text]));
  runner.submit('a');
  runner.submit('b');
  runner.submit('c');
  assert.deepEqual(started, ['a']);
  resolvers.shift()();
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.deepEqual(delivered, [], 'ответ для «a» устарел');
  assert.deepEqual(started, ['a', 'c']);
  resolvers.shift()();
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.deepEqual(delivered, [['r:c', 'c']]);
  runner.submit('d');
  runner.close();
  resolvers.shift()();
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.deepEqual(delivered, [['r:c', 'c']], 'после close ответы не доставляются');
  runner.submit('e');
  assert.deepEqual(started, ['a', 'c', 'd']);
});
