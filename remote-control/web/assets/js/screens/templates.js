// Шаблоны (`tui/src/clients.rs::templates`, `template_card`, `check_view`,
// `template_groups`, `edit_template`): список `#/templates` и редактор
// `#/templates/<имя>`. Расхождение с TUI: вместо внешнего редактора — Ace в
// странице; черновик проверяется `template check` (текст — полем
// `input.file`) через 500 мс после правки; «Сохранить» и «Импорт из файла» —
// `template import --name T` с содержимым в `input.file` через `runConfirmed`.
import { html, useState, useEffect, useMemo, useRef } from '../../vendor/preact-htm.js';
import {
  Page, Card, Chips, Badge, Button, DataTable, MoreMenu, Empty, FileText, downloadText,
} from '../ui.js';
import { Icon } from '../icons.js';
import { errorMessage } from '../format.js';
import { AceEditor } from '../template-editor.js';
import { useCommand, useBusy, useMounted, Loaded, ReadFailed, rows } from './kit.js';
import {
  TEMPLATE_NAME_MISSING, TEMPLATE_FILE_UNREADABLE, DEFAULT_TEMPLATE, NO_GROUP, TEMPLATE_KINDS,
  templateList, templateCreate, templateShow, templateImport, templateInput, templateCheck, templateDelete,
  templateGroups, templateKind, findTemplate, templateContent, groupOptions, problemCounts, annotations,
  droppedRanges, variantOptions,
} from './catalog-model.js';

/** Задержка проверки черновика после последней правки, мс. */
const CHECK_DELAY = 500;
const OVERRIDE_HINT = 'Сохранение создаст пользовательскую копию, перекрывающую встроенный шаблон.';

export function TemplatesScreen({ ctx, param }) {
  if (param) return html`<${TemplateEditor} key=${param} ctx=${ctx} name=${param} />`;
  return html`<${TemplateList} ctx=${ctx} />`;
}

const groupChips = (ctx, row) => rows(row && row.groups).filter((group) => typeof group === 'string')
  .map((group) => ({ label: group, href: ctx.href('groups', group) }));

function KindBadge({ row }) {
  const kind = TEMPLATE_KINDS[templateKind(row)];
  return html`<${Badge} tone=${kind.tone}>${kind.label}<//>`;
}

/** Пункт удаления: пользовательский — «Удалить», перекрывающий встроенный — «Сбросить к встроенному». */
function deleteLabel(row) {
  return templateKind(row) === 'override' ? 'Сбросить к встроенному' : 'Удалить';
}

/** `template delete` по плану; `true` — удалено. */
async function deleteTemplate(ctx, name) {
  const reply = await ctx.runConfirmed('Удаление шаблона', 'Удалить шаблон?', templateDelete(name));
  if (ctx.isFailure(reply)) ctx.failed();
  return reply.ok;
}

/** `template show` → файл `<имя>` (`clients.rs::export_template`). */
async function exportTemplate(ctx, name) {
  const reply = await ctx.request(templateShow(name));
  const content = reply.ok ? templateContent(reply.data) : null;
  if (content === null) { ctx.failed(); return; }
  downloadText(name, content);
  ctx.notify('success', `Шаблон ${name} сохранён в файл ${name}`);
}

// ─── Список ─────────────────────────────────────────────────────────────────

function TemplateList({ ctx }) {
  const state = useCommand(ctx, templateList());
  const [busy, run] = useBusy();
  const create = () => run(async () => {
    const names = rows(state.data).map((row) => row && row.name).filter((name) => typeof name === 'string');
    const values = await ctx.form({
      title: 'Создать шаблон',
      submit: 'Создать',
      fields: [
        { name: 'name', label: 'Имя шаблона', type: 'text', placeholder: 'my.yaml', required: TEMPLATE_NAME_MISSING, autofocus: true },
        { name: 'from', label: 'На основе', type: 'select', value: names.includes(DEFAULT_TEMPLATE) ? DEFAULT_TEMPLATE : names[0],
          options: names.map((name) => ({ value: name, label: name })) },
      ],
    });
    if (values === null) return;
    const reply = await ctx.request(templateCreate(values.name, values.from || null));
    if (!reply.ok) { ctx.failed(); await state.reload(); return; }
    // Как в TUI: созданный шаблон сразу открывается в редакторе.
    if (reply.data && typeof reply.data.name === 'string') ctx.navigate('templates', reply.data.name);
    else await state.reload();
  });
  const menu = (row) => {
    const items = [{ label: 'Экспорт', icon: 'download', disabled: busy, onClick: () => run(() => exportTemplate(ctx, row.name)) }];
    if (templateKind(row) !== 'builtin') {
      items.push({
        label: deleteLabel(row), icon: 'trash-2', danger: true, disabled: busy,
        onClick: () => run(async () => { await deleteTemplate(ctx, row.name); await state.reload(); }),
      });
    }
    return items;
  };
  const actions = html`<${Button} kind="primary" icon="plus" disabled=${busy || !state.data} onClick=${create}>Создать шаблон<//>`;
  return html`<${Loaded} title="Шаблоны" state=${state} actions=${actions}>${(data) => html`
    <${Page} title="Шаблоны" actions=${actions}>
      ${rows(data).length === 0
        ? html`<${Card}><${Empty} icon="file-code" title="Нет шаблонов" /><//>`
        : html`<${DataTable} rows=${rows(data)} href=${(row) => ctx.href('templates', row.name)} menu=${menu}
            columns=${[
              { key: 'name', label: 'Шаблон', search: true },
              { key: 'source', label: 'Источник', render: (row) => html`<${KindBadge} row=${row} />` },
              { key: 'groups', label: 'Группы', search: true, render: (row) => html`<${Chips} items=${groupChips(ctx, row)} />` },
            ]} />`}
    <//>`}<//>`;
}

// ─── Редактор ───────────────────────────────────────────────────────────────

/** Проверка черновика: при открытии сразу, после правок — через `CHECK_DELAY`; поздние ответы отбрасываются. */
function useCheck(ctx, name, text) {
  const [check, setCheck] = useState(null); // null | ответ `template check`
  const generation = useRef(0);
  const first = useRef(true);
  useEffect(() => {
    if (text === null) return undefined;
    generation.current += 1;
    const mine = generation.current;
    const delay = first.current ? 0 : CHECK_DELAY;
    first.current = false;
    const timer = setTimeout(async () => {
      const reply = await ctx.request(templateCheck(name), { input: templateInput(text), quiet: true });
      if (mine === generation.current) setCheck(reply);
    }, delay);
    return () => clearTimeout(timer);
  }, [text]);
  return check;
}

function TemplateEditor({ ctx, name }) {
  const list = useCommand(ctx, templateList());
  const shown = useCommand(ctx, templateShow(name), [], { expect: 'not_found' });
  const [busy, run] = useBusy();
  const mounted = useMounted();
  // Черновик редактора; `null` — без изменений.
  const [draft, setDraft] = useState(null);
  const [variant, setVariant] = useState(NO_GROUP);
  const editor = useRef(null);
  const row = list.data ? findTemplate(list.data, name) : null;
  const content = templateContent(shown.data);
  const text = draft !== null ? draft : content;
  const dirty = draft !== null && draft !== content;
  const check = useCheck(ctx, name, text);
  const report = check && check.ok ? check.data || {} : null;

  const leave = (...route) => { if (mounted.current) ctx.navigate(...route); };
  useEffect(() => {
    if (!list.data || findTemplate(list.data, name)) return;
    ctx.notify('warn', `Шаблон «${name}» не найден.`);
    leave('templates');
  }, [list.data]);
  useEffect(() => {
    if (shown.reply && !shown.reply.ok && shown.reply.error && shown.reply.error.code === 'not_found') leave('templates');
  }, [shown.reply]);
  // Несохранённые изменения: уход с экрана — только после вопроса.
  useEffect(() => {
    ctx.setLeaveGuard(dirty
      ? () => ctx.confirm({ title: 'Несохранённые изменения', question: 'Уйти без сохранения?', yes: 'Уйти', tone: 'danger' })
      : null);
  }, [dirty]);
  useEffect(() => () => ctx.setLeaveGuard(null), []);

  const marks = useMemo(() => annotations(report && report.problems, variant), [check, variant]);
  const dropped = useMemo(() => droppedRanges(report && report.variants, variant), [check, variant]);

  const reload = async () => { await Promise.all([list.reload(), shown.reload()]); };
  const discard = () => setDraft(null);
  const kind = templateKind(row);

  const save = () => run(async () => {
    if (!dirty) return;
    const reply = await ctx.runConfirmed('Сохранение шаблона', 'Сохранить шаблон?', templateImport(name), { input: templateInput(draft) });
    // Отказ от плана оставляет черновик.
    if (ctx.isFailure(reply)) ctx.failed();
    if (!reply.ok) return;
    discard();
    await reload();
  });
  const importFile = (fileText, reason) => run(async () => {
    if (fileText === null) { ctx.notify('warn', reason || TEMPLATE_FILE_UNREADABLE); return; }
    const reply = await ctx.runConfirmed('Импорт шаблона', 'Перезаписать шаблон?', templateImport(name), { input: templateInput(fileText) });
    if (ctx.isFailure(reply)) ctx.failed();
    if (reply.ok) discard();
    await reload();
  });
  const remove = () => run(async () => {
    if (!(await deleteTemplate(ctx, name))) return;
    if (kind === 'override') { discard(); await reload(); return; }
    ctx.setLeaveGuard(null);
    leave('templates');
  });
  const editGroups = () => run(async () => {
    const groups = await ctx.request(['group', 'list']);
    if (!groups.ok) { ctx.failed(); return; }
    const { options, selected } = groupOptions(groups.data, name);
    const values = await ctx.form({
      title: `Группы шаблона: ${name}`,
      submit: 'Далее',
      context: name === DEFAULT_TEMPLATE ? ['Группы без своего шаблона используют default.yaml.'] : ['Снятые группы вернутся к default.yaml.'],
      fields: [{ name: 'groups', label: 'Группы', type: 'multi', options, value: selected }],
    });
    if (values === null) return;
    const reply = await ctx.runConfirmed('Группы шаблона', 'Применить?', templateGroups(name, values.groups));
    if (ctx.isFailure(reply)) ctx.failed();
    if (reply.ok && rows(reply.data && reply.data.assigned).length === 0 && rows(reply.data && reply.data.reset).length === 0) {
      ctx.notify('info', 'Изменений нет.');
    }
    await list.reload();
  });

  const back = { href: ctx.href('templates'), label: 'Шаблоны' };
  const more = [
    { label: 'Экспорт в файл', icon: 'download', disabled: busy || content === null, onClick: () => run(() => exportTemplate(ctx, name)) },
    ...(dirty ? [{ label: 'Сбросить изменения', icon: 'x', disabled: busy, onClick: discard }] : []),
    ...(row && kind !== 'builtin' ? [{ label: deleteLabel(row), icon: 'trash-2', danger: true, disabled: busy, onClick: remove }] : []),
  ];
  const actions = html`
    <${FileText} label="Импорт из файла" accept=".yaml,.yml,text/*" disabled=${busy || content === null} onText=${importFile} />
    <${MoreMenu} items=${more} />
    <${Button} kind="primary" icon="save" disabled=${busy || !dirty} onClick=${save}>Сохранить<//>`;
  const badge = row && html`<${KindBadge} row=${row} />${dirty && html` <${Badge} tone="warn">не сохранено<//>`}`;
  return html`<${Loaded} title=${name} back=${back} state=${list}>${() => (row ? html`
    <${Page} title=${name} back=${back} badge=${badge} actions=${actions} subtitle=${kind === 'builtin' ? OVERRIDE_HINT : null}>
      <div class="editor-layout">
        <div class="editor-main">
          ${!shown.reply
            ? html`<${Card}><p class="t-dim">Загрузка…</p><//>`
            : !shown.reply.ok || content === null
              ? html`<${Card}><${ReadFailed} reply=${shown.reply} loading=${shown.loading} reload=${shown.reload} /><//>`
              : html`<${AceEditor} value=${text} onChange=${setDraft} annotations=${marks} dropped=${dropped}
                  dark=${Boolean(ctx.theme && ctx.theme.dark)} onSave=${save} api=${editor} label=${`Содержимое: ${name}`} />`}
        </div>
        <div class="editor-side">
          <${ProblemsPanel} check=${check} report=${report} onGoto=${(line, column) => editor.current && editor.current.goto(line, column)} />
          <${Card} title="Вариант">
            <label class="field">
              <span class="field-label">Группа, для которой показан шаблон</span>
              <select class="select select-sm" value=${variant} onChange=${(event) => setVariant(event.target.value)}>
                ${variantOptions(report && report.variants).map((option) => html`<option key=${option.value} value=${option.value}>${option.label}</option>`)}
              </select>
            </label>
            <span class="field-hint t-dim">Строки, которых нет в этом варианте, приглушены.</span>
          <//>
          <${Card} title="Группы" actions=${html`<${Button} icon="folders" disabled=${busy} onClick=${editGroups}>Группы…<//>`}>
            <${Chips} items=${groupChips(ctx, row)} />
            ${name === DEFAULT_TEMPLATE && html`<span class="field-hint t-dim">Группы без своего шаблона используют default.yaml</span>`}
          <//>
        </div>
      </div>
    <//>` : null)}<//>`;
}

const variantLabel = (variant) => (variant === '' ? 'без группы' : variant);

/** Итог `template check`: счётчики и список проблем со ссылками на строки. */
function ProblemsPanel({ check, report, onGoto }) {
  if (check === null) return html`<${Card} title="Проблемы"><p class="t-dim">Проверка…</p><//>`;
  if (!report) {
    return html`<${Card} title="Проблемы">
      <p class="t-warn">Проверка недоступна</p>
      <p class="t-dim">${errorMessage(check)}</p>
    <//>`;
  }
  const counts = problemCounts(report);
  const problems = rows(report.problems);
  return html`<${Card} title="Проблемы">
    ${counts.errors === 0 && counts.warnings === 0
      ? html`<p class="t-ok row"><${Icon} name="circle-check" size=${16} />Проблем нет</p>`
      : html`<p class=${counts.errors > 0 ? 't-error' : 't-warn'}>ошибок: ${counts.errors}, предупреждений: ${counts.warnings}</p>`}
    ${problems.length > 0 && html`<ul class="problems">
      ${problems.map((problem, index) => html`<li key=${index}>
        <button type="button" class="problem" onClick=${() => onGoto(problem.line, problem.column)}>
          <span class=${problem.level === 'error' ? 't-error' : 't-warn'}>
            <${Icon} name=${problem.level === 'error' ? 'circle-alert' : 'triangle-alert'} size=${16} />
          </span>
          <span class="problem-text">
            <span class="problem-line t-dim">строка ${problem.line}${typeof problem.variant === 'string' && html` · ${variantLabel(problem.variant)}`}</span>
            <span>${problem.message}</span>
          </span>
        </button>
      </li>`)}
    </ul>`}
    ${report.truncated === true && html`<p class="t-dim">Показаны первые 200</p>`}
  <//>`;
}
