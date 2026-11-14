// Шаблоны (`tui/src/clients.rs::templates`, `template_card`, `check_view`,
// `template_groups`, `edit_template`): список `#/templates` и редактор
// `#/templates/<имя>`. Расхождение с TUI: вместо внешнего редактора — Ace в
// странице; черновик проверяется `template check` (текст — полем
// `input.file`) через 500 мс после правки; «Сохранить» и «Импорт из файла» —
// `template import --name T` с содержимым в `input.file` через `runConfirmed`.
// Действия без DOM — `templates-model.js`.
import { html, useState, useEffect, useMemo, useRef } from '../../vendor/preact-htm.js';
import {
  Page, Card, Chips, Badge, Button, DataTable, MoreMenu, Empty, FileText, downloadText,
} from '../ui.js';
import { Icon } from '../icons.js';
import { errorMessage, asList } from '../format.js';
import { AceEditor } from '../template-editor.js';
import { useCommand, useBusy, useMounted, Loaded, ReadFailed } from './kit.js';
import {
  NO_GROUP, TEMPLATE_KINDS, DEFAULT_TEMPLATE,
  templateList, templateShow, templateInput, templateCheck,
  templateKind, findTemplate, templateContent, problemCounts, annotations,
  droppedRanges, variantOptions, effectiveVariant, problemVariant, inVariant,
} from './catalog-model.js';
import {
  settleDraft, draftDirty, unsavedChanges, saveTemplate, importTemplateFile, deleteLabel, deleteTemplate, editTemplateGroups, checkRunner,
  createTemplate, exportTemplate, offerLostDraft, confirmLeave,
} from './templates-model.js';

/** Задержка проверки черновика после последней правки, мс. */
const CHECK_DELAY = 500;
const OVERRIDE_HINT = 'Сохранение создаст пользовательскую копию, перекрывающую встроенный шаблон.';

export function TemplatesScreen({ ctx, param }) {
  if (param) return html`<${TemplateEditor} key=${param} ctx=${ctx} name=${param} />`;
  return html`<${TemplateList} ctx=${ctx} />`;
}

const groupChips = (ctx, row) => asList(row && row.groups).filter((group) => typeof group === 'string')
  .map((group) => ({ label: group, href: ctx.href('groups', group) }));

function KindBadge({ row }) {
  const kind = TEMPLATE_KINDS[templateKind(row)];
  return html`<${Badge} tone=${kind.tone}>${kind.label}<//>`;
}

// ─── Список ─────────────────────────────────────────────────────────────────

function TemplateList({ ctx }) {
  const state = useCommand(ctx, templateList());
  const [busy, run] = useBusy();
  const mounted = useMounted();
  const create = () => run(async () => {
    const created = await createTemplate(ctx, state.data);
    if (created === null) return;
    // Как в TUI: созданный шаблон сразу открывается в редакторе — только пока
    // список открыт, иначе поздний ответ уведёт из выбранного раздела.
    if (created.name !== null) { if (mounted.current) ctx.navigate('templates', created.name); }
    else await state.reload();
  });
  const menu = (row) => {
    const items = [{ label: 'Экспорт', icon: 'download', disabled: busy, onClick: () => run(() => exportTemplate(ctx, row.name, downloadText)) }];
    if (templateKind(row) !== 'builtin') {
      items.push({
        label: deleteLabel(row), icon: 'trash-2', danger: true, disabled: busy,
        onClick: () => run(async () => { await deleteTemplate(ctx, row); await state.reload(); }),
      });
    }
    return items;
  };
  const actions = html`<${Button} kind="primary" icon="plus" disabled=${busy || !state.data} onClick=${create}>Создать шаблон<//>`;
  return html`<${Loaded} title="Шаблоны" state=${state} actions=${actions}>${(data) => html`
    <${Page} title="Шаблоны" actions=${actions}>
      ${asList(data).length === 0
        ? html`<${Card}><${Empty} icon="file-code" title="Нет шаблонов" /><//>`
        : html`<${DataTable} rows=${asList(data)} href=${(row) => ctx.href('templates', row.name)} menu=${menu}
            columns=${[
              { key: 'name', label: 'Шаблон', search: true },
              { key: 'source', label: 'Источник', render: (row) => html`<${KindBadge} row=${row} />` },
              { key: 'groups', label: 'Группы', search: true, render: (row) => html`<${Chips} items=${groupChips(ctx, row)} />` },
            ]} />`}
    <//>`}<//>`;
}

// ─── Редактор ───────────────────────────────────────────────────────────────

/**
 * Проверка черновика: при открытии сразу, после правок и смены `revision`
 * (группы изменились) — через `CHECK_DELAY`; одновременно один запрос, отчёт
 * принимается только для текущего текста. `current` — отчёт относится к `text`.
 */
function useCheck(ctx, name, text, revision) {
  const [result, setResult] = useState(null); // null | { reply, text }
  const latest = useRef(text);
  latest.current = text;
  const ctxRef = useRef(ctx);
  ctxRef.current = ctx;
  const runner = useRef(null);
  if (runner.current === null) {
    runner.current = checkRunner(
      (draft) => ctxRef.current.request(templateCheck(name), { input: templateInput(draft), quiet: true }),
      (reply, draft) => { if (draft === latest.current) setResult({ reply, text: draft }); },
    );
  }
  useEffect(() => () => runner.current.close(), []);
  const first = useRef(true);
  useEffect(() => {
    if (text === null) return undefined;
    const delay = first.current ? 0 : CHECK_DELAY;
    first.current = false;
    const timer = setTimeout(() => runner.current.submit(text), delay);
    return () => clearTimeout(timer);
  }, [text, revision]);
  return { check: result && result.reply, current: result !== null && result.text === text };
}

const isSaveKey = (event) => (event.ctrlKey || event.metaKey) && !event.altKey && !event.shiftKey
  && (event.code === 'KeyS' || event.key === 's' || event.key === 'S');

function TemplateEditor({ ctx, name }) {
  const list = useCommand(ctx, templateList());
  const shown = useCommand(ctx, templateShow(name), [], { expect: 'not_found' });
  const [busy, run] = useBusy();
  const mounted = useMounted();
  // Черновик редактора; `null` — без изменений.
  const [draft, setDraft] = useState(null);
  const draftRef = useRef(draft);
  draftRef.current = draft;
  // Замена текста редактора снаружи (сброс, импорт, новый текст с сервера).
  const [version, setVersion] = useState(0);
  // Повтор проверки при неизменном тексте (группы изменились).
  const [revision, setRevision] = useState(0);
  const [chosen, setVariant] = useState(NO_GROUP);
  const editor = useRef(null);
  const row = list.data ? findTemplate(list.data, name) : null;
  const content = templateContent(shown.data);
  const contentRef = useRef(content);
  contentRef.current = content;
  const text = draft !== null ? draft : content;
  const dirty = draftDirty(draft, content);
  // Текст, который записывает идущая команда (сохранение или импорт), иначе `null`.
  const [saving, setSaving] = useState(null);
  const guarded = unsavedChanges(draft, content, saving);
  const { check, current } = useCheck(ctx, name, text, revision);
  const report = check && check.ok ? check.data || {} : null;
  const variant = effectiveVariant(report && report.variants, chosen);

  const replaceText = () => { setDraft(null); setVersion((value) => value + 1); };
  // Новый текст с сервера без черновика — в редактор.
  useEffect(() => { if (draft === null) setVersion((value) => value + 1); }, [content]);

  const leave = (...route) => { if (mounted.current) ctx.navigate(...route); };
  // Шаблон исчез (удалён другим клиентом): несохранённые правки можно скачать, затем — к списку.
  const unsaved = useRef(null);
  unsaved.current = dirty ? draft : null;
  const gone = useRef(false);
  const leaveGone = async () => {
    if (gone.current || !mounted.current) return;
    gone.current = true;
    ctx.setLeaveGuard(null);
    await offerLostDraft(ctx, name, unsaved.current, downloadText);
    leave('templates');
  };
  useEffect(() => {
    if (list.data && !findTemplate(list.data, name)) leaveGone();
  }, [list.data]);
  useEffect(() => {
    if (shown.reply && !shown.reply.ok && shown.reply.error && shown.reply.error.code === 'not_found') leaveGone();
  }, [shown.reply]);
  // Несохранённые изменения (и правки поверх идущего сохранения): уход с экрана — только после вопроса.
  useEffect(() => {
    if (gone.current) return;
    ctx.setLeaveGuard(guarded ? () => confirmLeave(ctx) : null);
  }, [guarded]);
  useEffect(() => () => ctx.setLeaveGuard(null), []);

  // Отметки — только по отчёту для текущего текста.
  const marks = useMemo(() => (current ? annotations(report && report.problems, variant) : []), [check, current, variant]);
  const dropped = useMemo(() => (current ? droppedRanges(report && report.variants, variant) : []), [check, current, variant]);

  const reload = async () => { await Promise.all([list.reload(), shown.reload()]); };
  const kind = templateKind(row);

  const save = () => run(async () => {
    if (!dirty) return;
    const sent = draft;
    setSaving(sent);
    try {
      if (!(await saveTemplate(ctx, name, sent))) return;
      // Сначала новый текст с сервера, потом черновик: правки, набранные во
      // время сохранения, остаются, а редактор не показывает прежний текст.
      await reload();
      setDraft((now) => settleDraft(now, sent));
    } finally {
      if (mounted.current) setSaving(null);
    }
  });
  // Ctrl/Cmd+S на всей странице редактора (и в Ace), кроме открытых окон.
  const saveRef = useRef(save);
  saveRef.current = save;
  useEffect(() => {
    const onKey = (event) => {
      if (!isSaveKey(event)) return;
      event.preventDefault();
      if (!ctx.dialogOpen()) saveRef.current();
    };
    ctx.win.addEventListener('keydown', onKey);
    return () => ctx.win.removeEventListener('keydown', onKey);
  }, []);
  const importFile = (fileText, reason) => run(async () => {
    // Правки, набранные пока идёт импорт, не затираются импортированным текстом;
    // до конца импорта его текст — идущая запись для защиты ухода.
    // `FileText` вызывает обработчик, снятый до чтения файла: черновик и
    // сохранённый текст — из ссылок на момент вызова, не из замыкания.
    const before = draftRef.current;
    try {
      const imported = await importTemplateFile(ctx, name, fileText, reason, draftDirty(before, contentRef.current), setSaving);
      if (fileText === null) return;
      await reload();
      if (imported && settleDraft(draftRef.current, before) === null) replaceText();
    } finally {
      if (mounted.current) setSaving(null);
    }
  });
  const remove = () => run(async () => {
    // Правки, набранные пока идёт сброс к встроенному, не затираются его текстом.
    const before = draftRef.current;
    if (!(await deleteTemplate(ctx, row))) return;
    // Редактор уже закрыт: защита ухода принадлежит другому экрану.
    if (!mounted.current) return;
    if (kind === 'override') {
      await reload();
      if (settleDraft(draftRef.current, before) === null) replaceText();
      return;
    }
    ctx.setLeaveGuard(null);
    leave('templates');
  });
  const editGroups = () => run(async () => {
    if (await editTemplateGroups(ctx, name)) setRevision((value) => value + 1);
    await list.reload();
  });
  const pick = (problem) => {
    const own = problemVariant(problem);
    if (own !== null && own !== variant) setVariant(own);
    if (editor.current) editor.current.goto(problem.line, problem.column);
  };

  const back = { href: ctx.href('templates'), label: 'Шаблоны' };
  const more = [
    { label: 'Экспорт сохранённого', icon: 'download', disabled: busy || content === null, onClick: () => run(() => exportTemplate(ctx, name, downloadText)) },
    ...(dirty ? [{ label: 'Сбросить изменения', icon: 'x', disabled: busy, onClick: replaceText }] : []),
    ...(row && kind !== 'builtin' ? [{ label: deleteLabel(row), icon: 'trash-2', danger: true, disabled: busy, onClick: remove }] : []),
  ];
  const actions = html`
    <${FileText} label="Импорт из файла" accept=".yaml,.yml,text/*" disabled=${busy || content === null} onText=${importFile} />
    <${MoreMenu} items=${more} />
    <${Button} kind="primary" icon="save" disabled=${busy || !dirty} onClick=${save}>Сохранить<//>`;
  const badge = row && html`<${KindBadge} row=${row} />${dirty && html` <${Badge} tone="warn">не сохранено<//>`}`;
  // Сбой `template list` ограничен карточкой «Группы»: текст шаблона читается
  // отдельно (`template show`) и редактируется без него; вид шаблона (отметка,
  // подсказка, удаление) неизвестен — не показывается.
  const listFailed = Boolean(list.reply && !list.reply.ok);
  if (!list.reply) return html`<${Loaded} title=${name} back=${back} state=${list}>${() => null}<//>`;
  if (!row && !listFailed) return null;
  return html`
    <${Page} title=${name} back=${back} badge=${badge} actions=${actions} subtitle=${row && kind === 'builtin' ? OVERRIDE_HINT : null}>
      <div class="editor-layout">
        <div class="editor-main">
          ${!shown.reply
            ? html`<${Card}><p class="t-dim">Загрузка…</p><//>`
            : !shown.reply.ok || content === null
              ? html`<${Card}><${ReadFailed} reply=${shown.reply} loading=${shown.loading} reload=${shown.reload} /><//>`
              : html`<${AceEditor} value=${text} version=${version} onChange=${setDraft} annotations=${marks} dropped=${dropped}
                  dark=${Boolean(ctx.theme && ctx.theme.dark)} api=${editor} label=${`Содержимое: ${name}`} />`}
        </div>
        <div class="editor-side">
          <${ProblemsPanel} check=${check} report=${report} current=${current} variant=${variant} onPick=${pick} />
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
            ${listFailed
              ? html`<${ReadFailed} reply=${list.reply} loading=${list.loading} reload=${list.reload} />`
              : html`<${Chips} items=${groupChips(ctx, row)} />`}
            ${name === DEFAULT_TEMPLATE && html`<span class="field-hint t-dim">Группы без своего шаблона используют default.yaml</span>`}
          <//>
        </div>
      </div>
    <//>`;
}

const variantLabel = (variant) => (variant === '' ? 'без группы' : variant);

/**
 * Итог `template check`: счётчики и список проблем со ссылками на строки.
 * Проблемы других вариантов приглушены; щелчок по ним переключает вариант.
 */
function ProblemsPanel({ check, report, current, variant, onPick }) {
  if (check === null) return html`<${Card} title="Проблемы"><p class="t-dim">Проверка…</p><//>`;
  if (!report) {
    return html`<${Card} title="Проблемы">
      <p class="t-warn">Проверка недоступна</p>
      <p class="t-dim">${errorMessage(check)}</p>
    <//>`;
  }
  const counts = problemCounts(report);
  const problems = asList(report.problems).filter((problem) => problem && typeof problem === 'object');
  return html`<${Card} title="Проблемы">
    ${!current && html`<p class="t-dim">Проверка…</p>`}
    ${counts.errors === 0 && counts.warnings === 0
      ? html`<p class="t-ok row"><${Icon} name="circle-check" size=${16} />Проблем нет</p>`
      : html`<p class=${counts.errors > 0 ? 't-error' : 't-warn'}>ошибок: ${counts.errors}, предупреждений: ${counts.warnings}</p>`}
    ${problems.length > 0 && html`<ul class="problems">
      ${problems.map((problem, index) => {
        const here = inVariant(problem, variant);
        return html`<li key=${index}>
          <button type="button" class="problem ${here ? '' : 'problem-other'}" onClick=${() => onPick(problem)}>
            <span class=${problem.level === 'error' ? 't-error' : 't-warn'}>
              <${Icon} name=${problem.level === 'error' ? 'circle-alert' : 'triangle-alert'} size=${16} />
            </span>
            <span class="problem-text">
              <span class="problem-line t-dim">строка ${problem.line}${typeof problem.variant === 'string' && html` · ${variantLabel(problem.variant)}`}${!here && ' (другой вариант)'}</span>
              <span>${problem.message}</span>
            </span>
          </button>
        </li>`;
      })}
    </ul>`}
    ${report.truncated === true && html`<p class="t-dim">Показаны первые 200</p>`}
    ${typeof report.schema === 'string' && report.schema !== '' && html`<p class="t-dim">Схема: ${report.schema}</p>`}
  <//>`;
}
