// Шаблоны (`tui/src/clients.rs::templates`, `template_card`, `edit_template`).
// Расхождение с TUI (план 2.6): «Показать» и «Редактировать» — один редактор
// `<textarea>`; «Сохранить» и «Импорт из файла» — `template import --name T`
// с содержимым в `input.file` через `runConfirmed`; «Экспорт в файл» —
// `template show` и скачивание файла `<имя>`.
import { html, useState, useEffect } from '../../vendor/preact-htm.js';
import { Page, Card, Facts, Chips, Badge, Button, DataTable, Empty, FileText, downloadText } from '../ui.js';
import { useCommand, useBusy, Loaded, rows } from './kit.js';
import {
  TEMPLATE_NAME_MISSING, TEMPLATE_FILE_UNREADABLE, templateList, templateCreate, templateShow, templateImport,
  templateInput, findTemplate, templatePath, templateContent,
} from './catalog-model.js';
import { templateSource } from '../format.js';

export function TemplatesScreen({ ctx, param }) {
  if (param) return html`<${TemplateCard} key=${param} ctx=${ctx} name=${param} />`;
  return html`<${TemplateList} ctx=${ctx} />`;
}

const groupChips = (ctx, row) => rows(row && row.groups).filter((group) => typeof group === 'string')
  .map((group) => ({ label: group, href: ctx.href('groups', group) }));

/** `clients.rs::templates`: список и «Создать шаблон». */
function TemplateList({ ctx }) {
  const state = useCommand(ctx, templateList());
  const [busy, run] = useBusy();
  const create = () => run(async () => {
    const values = await ctx.form({
      title: 'Создать шаблон',
      fields: [{ name: 'name', label: 'Имя шаблона', type: 'text', placeholder: 'my.yaml', required: TEMPLATE_NAME_MISSING }],
      submit: 'Создать',
    });
    if (values === null) return;
    const reply = await ctx.request(templateCreate(values.name));
    if (!reply.ok) { ctx.failed(); await state.reload(); return; }
    // Как в TUI: созданный шаблон сразу открывается в редакторе.
    if (reply.data && typeof reply.data.name === 'string') ctx.navigate('templates', reply.data.name);
    else await state.reload();
  });
  const actions = html`<${Button} kind="primary" icon="plus" disabled=${busy} onClick=${create}>Создать шаблон<//>`;
  return html`<${Loaded} title="Шаблоны" state=${state} actions=${actions}>${(data) => html`
    <${Page} title="Шаблоны" actions=${actions}>
      ${rows(data).length === 0
        ? html`<${Card}><${Empty} icon="file-code" title="Нет шаблонов" /><//>`
        : html`<${DataTable} rows=${rows(data)} href=${(row) => ctx.href('templates', row.name)}
            columns=${[
              { key: 'name', label: 'Шаблон', search: true },
              { key: 'source', label: 'Источник', render: (row) => html`<${Badge} tone=${row.source === 'builtin' ? 'neutral' : 'info'}>${templateSource(row)}<//>` },
              { key: 'groups', label: 'Группы', search: true, render: (row) => html`<${Chips} items=${groupChips(ctx, row)} />` },
            ]} />`}
    <//>`}<//>`;
}

/** `clients.rs::template_card` + `edit_template`: карточка с редактором. */
function TemplateCard({ ctx, name }) {
  const list = useCommand(ctx, templateList());
  const shown = useCommand(ctx, templateShow(name));
  const [busy, run] = useBusy();
  // Рабочая копия редактора; `null` — без изменений. Отклонённый импорт
  // оставляет её до сохранения или явной отмены (TUI `reopen_editor`).
  const [draft, setDraft] = useState(null);
  const [rejected, setRejected] = useState(false);
  const row = list.data ? findTemplate(list.data, name) : null;
  const content = templateContent(shown.data);
  const dirty = draft !== null && draft !== content;

  useEffect(() => {
    if (!list.data) return;
    if (!findTemplate(list.data, name)) {
      ctx.notify('warn', `Шаблон «${name}» не найден.`);
      ctx.navigate('templates');
    }
  }, [list.data]);
  useEffect(() => {
    const reply = shown.reply;
    if (!reply || reply.ok) return;
    if (reply.error && reply.error.code === 'not_found') ctx.navigate('templates');
    else ctx.failed();
  }, [shown.reply]);
  // Несохранённые изменения: уход с экрана — только после вопроса.
  useEffect(() => {
    ctx.setLeaveGuard(dirty
      ? () => ctx.confirm({ title: 'Несохранённые изменения', question: 'Уйти без сохранения изменений шаблона?', yes: 'Уйти', tone: 'danger' })
      : null);
  }, [dirty]);
  useEffect(() => () => ctx.setLeaveGuard(null), []);

  const reload = async () => { await Promise.all([list.reload(), shown.reload()]); };
  const discard = () => { setDraft(null); setRejected(false); };

  const save = () => run(async () => {
    if (draft === null || draft === content) { ctx.notify('info', 'Изменений нет.'); discard(); return; }
    const reply = await ctx.runConfirmed('Импорт изменений шаблона', 'Сохранить изменения шаблона?',
      templateImport(name), { input: templateInput(draft) });
    if (reply.ok) {
      discard();
      await reload();
      return;
    }
    // Отказ от плана (`confirmation_required`, `plan_changed`) оставляет
    // рабочую копию: удалить её — отдельное действие «Отменить изменения».
    if (!ctx.isFailure(reply)) return;
    ctx.failed();
    setRejected(true);
  });
  const importFile = (text, reason) => run(async () => {
    if (text === null) { ctx.notify('warn', reason || TEMPLATE_FILE_UNREADABLE); return; }
    const reply = await ctx.runConfirmed('Импорт шаблона', 'Перезаписать шаблон?', templateImport(name), { input: templateInput(text) });
    if (ctx.isFailure(reply)) ctx.failed();
    if (reply.ok) discard();
    await reload();
  });
  const exportFile = () => run(async () => {
    const reply = await ctx.request(templateShow(name));
    if (!reply.ok) { ctx.failed(); return; }
    const fresh = templateContent(reply.data);
    if (fresh === null) { ctx.failed(); return; }
    downloadText(name, fresh);
    ctx.notify('success', `Шаблон ${name} сохранён в файл ${name}`);
  });

  const back = { href: ctx.href('templates'), label: 'Шаблоны' };
  const actions = html`
    ${dirty && html`<${Button} kind="ghost" disabled=${busy} onClick=${discard}>Отменить изменения<//>`}
    <${Button} icon="download" disabled=${busy || content === null} onClick=${exportFile}>Экспорт в файл<//>
    <${FileText} label="Импорт из файла" accept=".yaml,.yml,text/*" disabled=${busy || content === null} onText=${importFile} />
    <${Button} kind="primary" icon="save" disabled=${busy || content === null || !dirty} onClick=${save}>Сохранить<//>`;
  return html`<${Loaded} title=${name} back=${back} state=${list}>${() => (row ? html`
    <${Page} title=${name} back=${back} actions=${actions}
      badge=${html`<${Badge} tone=${row.source === 'builtin' ? 'neutral' : 'info'}>${templateSource(row)}<//>`}>
      <div class="editor-layout">
        <${Card}>
          ${!shown.reply
            ? html`<p class="t-dim">Загрузка…</p>`
            : !shown.reply.ok || content === null
              ? html`<p class="t-warn">Содержимое недоступно</p>
                <div class="row"><${Button} icon="refresh-cw" disabled=${shown.loading} onClick=${() => shown.reload()}>Повторить чтение<//></div>`
              : html`
                ${rejected && dirty && html`<div role="alert" class="alert alert-warning alert-soft">Изменения шаблона не сохранены. Рабочая копия сохранена до решения.</div>`}
                <textarea class="textarea code editor" rows="24" spellcheck=${false} aria-label=${`Содержимое: ${name}`}
                  value=${draft !== null ? draft : content} disabled=${busy}
                  onInput=${(event) => setDraft(event.target.value)}></textarea>`}
        <//>
        <div class="editor-side">
          <${Card} title="Сведения">
            <${Facts} items=${[
              { label: 'Источник', value: templateSource(row) },
              { label: 'Путь', value: shown.data ? templatePath(shown.data).replace(/^Путь: /, '') : '—' },
              { label: 'Группы', value: html`<${Chips} items=${groupChips(ctx, row)} />` },
            ]} />
          <//>
        </div>
      </div>
    <//>` : null)}<//>`;
}
