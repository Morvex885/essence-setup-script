// Группы (`#/groups`, `#/groups/<имя>`) — перенос `clients.rs::groups`,
// `group_card`, `group_template`; действия — `clients-model.js`. Редактор
// созданного шаблона — экран «Шаблоны» (`#/templates/<имя>`).
import { html, useEffect } from '../../vendor/preact-htm.js';
import { Page, Card, DataTable, MoreMenu, Facts, Badge, Chips, Empty, Button } from '../ui.js';
import { asList, strings } from '../format.js';
import { useCommand, useBusy, useMounted, Loaded } from './kit.js';
import * as model from './clients-model.js';

export function GroupsScreen({ ctx, param }) {
  return param === null || param === undefined
    ? html`<${GroupList} ctx=${ctx} />`
    : html`<${GroupCard} ctx=${ctx} name=${param} key=${param} />`;
}

function TemplateLink({ ctx, template }) {
  return typeof template === 'string' ? html`<a class="link" href=${ctx.href('templates', template)}>${template}</a>` : '—';
}

function NodeChips({ ctx, nodes }) {
  return html`<${Chips} items=${strings(nodes).map((node) => ({ label: node, href: ctx.href('nodes', node) }))} />`;
}

/** Ноды группы; без нод — кнопка назначения подключений вместо «нет». */
function GroupNodes({ ctx, nodes, busy, onAdd }) {
  return strings(nodes).length > 0
    ? html`<${NodeChips} ctx=${ctx} nodes=${nodes} />`
    : html`<${Button} icon="plus" disabled=${busy} onClick=${onAdd}>Добавить подключения<//>`;
}

// ─── Список ─────────────────────────────────────────────────────────────────

function GroupList({ ctx }) {
  const state = useCommand(ctx, ['group', 'list']);
  const [busy, run] = useBusy();
  const mounted = useMounted();
  const act = (action) => run(async () => { await action(); await state.reload(); });

  /** Новая группа открывается карточкой (имя — из ответа), пока список на экране. */
  const add = () => run(async () => {
    let opened = false;
    await model.addGroupFlow(ctx, (name) => { opened = true; if (mounted.current) ctx.navigate('groups', name); });
    if (!opened) await state.reload();
  });
  const remove = (name) => act(() => model.confirmed(ctx, 'Удаление группы', 'Удалить группу?', model.groupDeleteArgv(name)));

  const actions = html`<${Button} kind="primary" icon="plus" disabled=${busy || !state.data} onClick=${add}>Добавить группу<//>`;
  const menu = (row) => [
    { label: 'Сгенерировать конфиги', icon: 'file-code', disabled: busy, onClick: () => act(() => model.generateFlow(ctx, { group: row.name })) },
    { label: 'Подключения нод…', icon: 'server', disabled: busy, onClick: () => act(() => model.groupConnectionsFlow(ctx, row.name)) },
    { label: 'Удалить', icon: 'trash-2', danger: true, disabled: busy, onClick: () => remove(row.name) },
  ];
  return html`<${Loaded} title="Группы" state=${state} actions=${actions}>
    ${(data) => {
      const list = asList(data).filter((row) => row && typeof row.name === 'string');
      return html`<${Page} title="Группы" actions=${actions}>
        <${Card}>
          ${list.length === 0
            ? html`<${Empty} icon="folders" title="Нет групп" action=${actions} />`
            : html`<${DataTable} rows=${list} empty="Нет групп" href=${(row) => ctx.href('groups', row.name)} menu=${menu}
                columns=${[
                  { key: 'name', label: 'Группа', search: true },
                  { key: 'template', label: 'Шаблон', render: (row) => html`<${TemplateLink} ctx=${ctx} template=${row.template} />` },
                  { key: 'clients', label: 'Клиентов', render: (row) => model.scalar(row.clients) },
                  { key: 'nodes', label: 'Ноды', render: (row) => html`<${GroupNodes} ctx=${ctx} nodes=${row.nodes} busy=${busy}
                    onAdd=${() => act(() => model.groupConnectionsFlow(ctx, row.name))} />` },
                ]} />`}
        <//>
      <//>`;
    }}
  <//>`;
}

// ─── Карточка ───────────────────────────────────────────────────────────────

function GroupCard({ ctx, name }) {
  const state = useCommand(ctx, ['group', 'list'], [name], { expect: 'not_found' });
  const clients = useCommand(ctx, ['client', 'list', '--group', name], [name], { expect: 'not_found' });
  const [busy, run] = useBusy();
  const mounted = useMounted();
  const reply = state.reply;
  const row = reply && reply.ok ? model.findRow(reply.data, name) : null;
  // Исчезновение объекта возвращает к списку.
  const vanished = Boolean(reply && (reply.ok ? !row : reply.error && reply.error.code === 'not_found'));
  useEffect(() => {
    if (!vanished) return;
    if (reply.ok) ctx.notify('warn', `Группа «${name}» не найдена.`);
    ctx.navigate('groups');
  }, [vanished, reply]);
  if (vanished) return null;

  const back = { href: ctx.href('groups'), label: 'Группы' };
  const act = (action) => run(async () => {
    if ((await action()) === 'left') return;
    await Promise.all([state.reload(), clients.reload()]);
  });
  const leave = (...route) => { if (mounted.current) ctx.navigate(...route); return 'left'; };
  const template = row ? model.str(row.template) : '—';

  const remove = async () => {
    const result = await model.confirmed(ctx, 'Удаление группы', 'Удалить группу?', model.groupDeleteArgv(name));
    return result.ok ? leave('groups') : undefined;
  };
  const chooseTemplate = async () => {
    const created = await model.groupTemplateFlow(ctx, name, template);
    return created === null ? undefined : leave('templates', created);
  };
  const move = (client) => model.moveClientFlow(ctx, name, state.data, client);

  const actions = html`
    <${Button} kind="primary" icon="file-code" disabled=${busy} onClick=${() => act(() => model.generateFlow(ctx, { group: name }))}>Сгенерировать конфиги группы<//>
    <${Button} icon="scroll-text" disabled=${busy} onClick=${() => act(chooseTemplate)}>Шаблон…<//>
    <${Button} icon="rss" disabled=${busy} onClick=${() => act(() => model.showHeaders(ctx, 'group', name))}>Заголовки подписки<//>
    <${MoreMenu} items=${[
      { label: 'Подключения нод…', icon: 'server', disabled: busy, onClick: () => act(() => model.groupConnectionsFlow(ctx, name)) },
      { label: 'Удалить группу', icon: 'trash-2', danger: true, disabled: busy, onClick: () => act(remove) },
    ]} />`;

  return html`<${Loaded} title=${name} back=${back} state=${state}>
    ${() => html`<${Page} title=${name} back=${back} actions=${actions}>
      <${Card}>
        <${Facts} items=${[
          { label: 'Шаблон', value: html`<${TemplateLink} ctx=${ctx} template=${row.template} />` },
          { label: 'Клиентов', value: model.scalar(row.clients) },
          { label: 'Ноды', value: html`<${GroupNodes} ctx=${ctx} nodes=${row.nodes} busy=${busy}
            onAdd=${() => act(() => model.groupConnectionsFlow(ctx, name))} />` },
        ]} />
      <//>
      <${Loaded} title="Клиенты группы" state=${clients} inline>
        ${(data) => html`<${Card} title="Клиенты группы">
          <${DataTable} rows=${asList(data).filter((item) => item && typeof item.name === 'string')} empty="Нет клиентов"
            href=${(item) => ctx.href('clients', item.name)}
            menu=${(item) => [{ label: 'Перенести в группу…', icon: 'folders', disabled: busy, onClick: () => act(() => move(item.name)) }]}
            columns=${[
              { key: 'name', label: 'Клиент', search: true },
              { key: 'subscription', label: 'Подписка', render: (item) => {
                const badge = model.subscriptionBadge(item);
                return html`<${Badge} tone=${badge.tone}>${badge.label}<//>`;
              } },
            ]} />
        <//>`}
      <//>
    <//>`}
  <//>`;
}
