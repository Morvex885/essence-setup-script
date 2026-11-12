// Шаблоны (`tui/src/clients.rs::templates`, `template_card`, `edit_template`).
// Расхождение с TUI (план 2.6): «Показать» и «Редактировать» — один редактор
// `<textarea>`; «Сохранить» и «Импорт из файла» — `template import --name T`
// с содержимым в `input.file` через `runConfirmed`; «Экспорт в файл» —
// `template show` и скачивание файла `<имя>`.
import { html, useState, useEffect } from '../../vendor/preact-htm.js';
import { Card, FileText, downloadText } from '../ui.js';
import { useCommand, useBusy, Action, Actions, Context, Back, Loaded, rows } from './kit.js';
import {
  TEMPLATE_NAME_MISSING, TEMPLATE_FILE_UNREADABLE, templateList, templateCreate, templateShow, templateImport,
  templateInput, templateLabel, findTemplate, templateContext, templatePath, templateContent,
} from './catalog-model.js';

export function TemplatesScreen({ ctx, param }) {
  if (param) return html`<${TemplateCard} key=${param} ctx=${ctx} name=${param} />`;
  return html`<${TemplateList} ctx=${ctx} />`;
}

/** `clients.rs::templates`: список и «Создать шаблон». */
function TemplateList({ ctx }) {
  const state = useCommand(ctx, templateList());
  const [busy, run] = useBusy();
  const create = () => run(async () => {
    const name = await ctx.ask({ title: 'Создать шаблон', label: 'Имя шаблона' });
    if (name === null) return;
    if (name === '') { ctx.notify('warn', TEMPLATE_NAME_MISSING); return; }
    const reply = await ctx.request(templateCreate(name));
    if (!reply.ok) { ctx.failed(); await state.reload(); return; }
    // Как в TUI: созданный шаблон сразу открывается в редакторе.
    if (reply.data && typeof reply.data.name === 'string') ctx.navigate('templates', reply.data.name);
    else await state.reload();
  });
  const actions = html`
    <${Action} tone="create" disabled=${busy} onClick=${create}>Создать шаблон<//>
    <${Back} ctx=${ctx} to="summary" />`;
  return html`<${Loaded} title="Шаблоны" state=${state} actions=${actions}>${(data) => html`
    <${Card} title="Шаблоны" actions=${actions}>
      ${rows(data).length === 0
        ? html`<${Context} lines=${[{ text: 'Нет шаблонов', tone: 'dim' }]} />`
        : html`<${Actions} column>
            ${rows(data).map((row) => html`
              <${Action} key=${row.name} tone="view" disabled=${busy} onClick=${() => ctx.navigate('templates', row.name)}>${templateLabel(row)}<//>`)}
          <//>`}
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

  const title = `Шаблон: ${name}`;
  const back = html`<${Back} ctx=${ctx} to="templates" />`;
  const dirty = draft !== null && draft !== content;
  const actions = html`
    <${Action} tone="view" disabled=${busy || content === null} onClick=${exportFile}>Экспорт в файл<//>
    <${Action} tone="change" disabled=${busy || content === null || !dirty} onClick=${save}>Сохранить<//>
    <${FileText} tone="change" label="Импорт из файла" accept=".yaml,.yml,text/*" disabled=${busy || content === null} onText=${importFile} />
    ${dirty && html`<${Action} tone="danger" disabled=${busy} onClick=${discard}>Отменить изменения<//>`}
    ${back}`;
  return html`<${Loaded} title=${title} state=${list} actions=${back}>${() => (row ? html`
    <${Card} title=${title} actions=${actions}>
      <${Context} lines=${templateContext(row)} />
      ${!shown.reply
        ? html`<p class="dim">Загрузка…</p>`
        : !shown.reply.ok || content === null
          ? html`<p class="tone-warn">Содержимое недоступно</p>
            <${Actions}><${Action} tone="view" disabled=${shown.loading} onClick=${() => shown.reload()}>Повторить чтение<//><//>`
          : html`
            <${Context} lines=${[
              { text: templatePath(shown.data), tone: 'dim' },
              rejected && dirty && { text: 'Изменения шаблона не сохранены. Рабочая копия сохранена до решения.', tone: 'warn' },
            ]} />
            <textarea class="code editor" rows="24" spellcheck=${false} aria-label=${`Содержимое: ${name}`}
              value=${draft !== null ? draft : content} disabled=${busy}
              onInput=${(event) => setDraft(event.target.value)}></textarea>`}
    <//>` : null)}<//>`;
}
