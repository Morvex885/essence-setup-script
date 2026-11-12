// Группы (`#/groups`, `#/groups/<имя>`) — перенос `clients.rs::groups`,
// `group_card`, `group_template`. Редактор созданного шаблона — экран
// «Шаблоны» (`#/templates/<имя>`).
import { html, useEffect } from '../../vendor/preact-htm.js';
import { Card, Table, Button } from '../ui.js';
import { useCommand, useBusy, Action, Actions, Context, Back, Loaded } from './kit.js';
import { execute, confirmed, fetchData, required, runGenerate, showHeaders } from './shared.js';
import * as model from './clients-model.js';

export function GroupsScreen({ ctx, param }) {
  return param === null || param === undefined
    ? html`<${GroupList} ctx=${ctx} />`
    : html`<${GroupCard} ctx=${ctx} name=${param} key=${param} />`;
}

function GroupList({ ctx }) {
  const state = useCommand(ctx, ['group', 'list']);
  const [busy, run] = useBusy();
  const add = () => run(async () => {
    const name = await required(ctx, 'Добавить группу', 'Название группы', 'Название не указано.');
    if (name !== null) await execute(ctx, ['group', 'add', '--name', name]);
    await state.reload();
  });
  const actions = html`<${Action} tone="create" disabled=${busy || !state.data} onClick=${add}>Добавить группу<//>`;
  return html`<${Loaded} title="Группы" state=${state} actions=${actions}>
    ${(data) => html`<${Card} title="Группы" actions=${actions}>
      <${Table} empty="Нет групп"
        columns=${[
          { key: 'name', label: 'Группа', render: (row) => html`<${Button} kind="view" onClick=${() => ctx.navigate('groups', row.name)}>${model.str(row.name)}<//>` },
          { key: 'template', label: 'Шаблон', render: (row) => model.str(row.template) },
        ]}
        rows=${model.rowsOf(data)} />
    <//>`}
  <//>`;
}

function GroupCard({ ctx, name }) {
  const state = useCommand(ctx, ['group', 'list'], [name], { expect: 'not_found' });
  const [busy, run] = useBusy();
  const reply = state.reply;
  const back = html`<${Back} ctx=${ctx} to="groups" />`;
  const row = reply && reply.ok ? model.findRow(reply.data, name) : null;
  // Исчезновение объекта возвращает к списку.
  const vanished = Boolean(reply && (reply.ok ? !row : reply.error && reply.error.code === 'not_found'));
  useEffect(() => {
    if (!vanished) return;
    if (reply.ok) ctx.notify('warn', `Группа «${name}» не найдена.`);
    ctx.navigate('groups');
  }, [vanished, reply]);
  if (vanished) return null;

  const act = (action) => run(async () => { if ((await action()) !== 'left') await state.reload(); });
  const template = row ? model.str(row.template) : '—';
  const remove = async () => {
    const result = await confirmed(ctx, 'Удаление группы', 'Удалить группу?', ['group', 'delete', '--name', name]);
    if (result.ok) { ctx.navigate('groups'); return 'left'; }
    return undefined;
  };

  return html`<${Loaded} title=${`Группа: ${name}`} state=${state} actions=${back}>
    ${() => html`<${Card} title=${`Группа: ${name}`} actions=${back}>
      <${Context} lines=${model.groupContext(row)} />
      <${Actions}>
        <${Action} tone="change" disabled=${busy} onClick=${() => act(() => groupTemplate(ctx, name, template))}>Шаблон<//>
        <${Action} tone="change" disabled=${busy} onClick=${() => act(() => showHeaders(ctx, 'group', name))}>Заголовки подписки группы<//>
        <${Action} tone="change" disabled=${busy} onClick=${() => act(() => runGenerate(ctx, ['--group', name]))}>Сгенерировать конфиги группы<//>
        <${Action} tone="danger" disabled=${busy} onClick=${() => act(remove)}>Удалить группу<//>
      <//>
    <//>`}
  <//>`;
}

/**
 * `clients.rs::group_template`: выбор шаблона или новый шаблон группы. Новый
 * шаблон открывается в редакторе экрана «Шаблоны» (в TUI — `edit_template`).
 */
async function groupTemplate(ctx, name, current) {
  const read = await fetchData(ctx, ['template', 'list']);
  if (!read) return undefined;
  const menu = model.groupTemplateMenu(name, current, read.data);
  const choice = await ctx.choose({ title: menu.title, options: menu.options });
  if (choice === null || choice === undefined) return undefined;
  if (choice !== model.NEW_TEMPLATE) {
    await execute(ctx, ['group', 'set-template', '--name', name, '--template', choice]);
    return undefined;
  }
  const created = await required(ctx, 'Новый шаблон группы', 'Имя нового шаблона', 'Имя шаблона не указано.');
  if (created === null) return undefined;
  const reply = await execute(ctx, ['template', 'create', '--name', created, '--group', name]);
  if (reply.ok && reply.data && typeof reply.data.name === 'string') {
    ctx.navigate('templates', reply.data.name);
    return 'left';
  }
  return undefined;
}
