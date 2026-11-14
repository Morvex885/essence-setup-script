// Клиенты (`#/clients`, `#/clients/<имя>/<вкладка>`) — перенос
// `clients.rs::clients`, `delete_clients`, `client_card`, `show_client`,
// `client_nodes`, `client_connections`, `client_subscription`; argv и
// действия — `clients-model.js`.
import { html, useEffect, useState } from '../../vendor/preact-htm.js';
import { Page, Card, DataTable, MoreMenu, Facts, Badge, Chips, Empty, Button, downloadText } from '../ui.js';
import { asList, strings } from '../format.js';
import { useCommand, useBusy, useMounted, Context, Loaded } from './kit.js';
import { showShare } from './share.js';
import * as model from './clients-model.js';
import { confirmed, fetchData } from './clients-model.js';

export function ClientsScreen({ ctx, param, tab }) {
  return param === null || param === undefined
    ? html`<${ClientList} ctx=${ctx} />`
    : html`<${ClientCard} ctx=${ctx} name=${param} tab=${tab} key=${param} />`;
}

/** Отметка подписки клиента (`subscriptionBadge`). */
function SubscriptionBadge({ row }) {
  const badge = model.subscriptionBadge(row);
  return html`<${Badge} tone=${badge.tone}>${badge.label}<//>`;
}

/** Ссылка на группу клиента. */
function GroupLink({ ctx, group }) {
  return typeof group === 'string' ? html`<a class="link" href=${ctx.href('groups', group)}>${group}</a>` : '—';
}

// ─── Список ─────────────────────────────────────────────────────────────────

function ClientList({ ctx }) {
  const state = useCommand(ctx, ['client', 'list']);
  const [busy, run] = useBusy();
  const mounted = useMounted();
  const [selected, setSelected] = useState([]);
  const act = (action) => run(async () => { await action(); await state.reload(); });
  const present = model.names(state.data);
  const chosen = selected.filter((name) => present.includes(name));

  const removeSelected = () => act(async () => {
    const reply = await confirmed(ctx, 'Удаление клиентов', 'Удалить выбранных клиентов?', model.deleteClientsArgv(chosen));
    if (reply.ok || (reply.error && reply.error.code === 'partial')) setSelected([]);
  });
  const remove = (name) => act(() => confirmed(ctx, 'Удаление клиента', 'Удалить клиента?', model.clientDeleteArgv(name)));
  const add = () => run(() => model.addClientFlow(ctx, (name) => { if (mounted.current) ctx.navigate('clients', name); }));

  const actions = html`
    ${chosen.length > 0 && html`<${Button} kind="danger" icon="trash-2" disabled=${busy} onClick=${removeSelected}>
      Удалить выбранных (${chosen.length})<//>`}
    <${Button} icon="file-code" disabled=${busy || !state.data} onClick=${() => act(() => model.generateFlow(ctx))}>Сгенерировать конфиги<//>
    <${Button} kind="primary" icon="plus" disabled=${busy || !state.data} onClick=${add}>Добавить клиента<//>`;
  const menu = (row) => [
    { label: 'Подписка', icon: 'rss', onClick: () => ctx.navigate('clients', row.name, 'subscription') },
    { label: 'Сгенерировать конфиг', icon: 'file-code', disabled: busy, onClick: () => act(() => model.generateFlow(ctx, { client: row.name })) },
    { label: 'Удалить', icon: 'trash-2', danger: true, disabled: busy, onClick: () => remove(row.name) },
  ];

  return html`<${Loaded} title="Клиенты" state=${state} actions=${actions}>
    ${(data) => {
      const list = asList(data).filter((row) => row && typeof row.name === 'string');
      return html`<${Page} title="Клиенты" actions=${actions}>
        <${Card}>
          ${list.length === 0
            ? html`<${Empty} icon="users" title="Нет клиентов"
                action=${html`<${Button} kind="primary" icon="plus" disabled=${busy} onClick=${add}>Добавить клиента<//>`} />`
            : html`<${DataTable} rows=${list} empty="Нет клиентов"
                href=${(row) => ctx.href('clients', row.name)}
                menu=${menu}
                selection=${{ selected: chosen, onChange: setSelected }}
                columns=${[
                  { key: 'name', label: 'Клиент', search: true },
                  { key: 'group', label: 'Группа', search: true, render: (row) => html`<${GroupLink} ctx=${ctx} group=${row.group} />` },
                  { key: 'nodes', label: 'Ноды', render: (row) => (model.inherits(row) ? 'от группы' : `свои: ${strings(row.nodes).length}`) },
                  { key: 'subscription', label: 'Подписка', render: (row) => html`<${SubscriptionBadge} row=${row} />` },
                ]} />`}
        <//>
      <//>`;
    }}
  <//>`;
}

// ─── Карточка ───────────────────────────────────────────────────────────────

const TABS = [
  { id: 'overview', label: 'Обзор' },
  { id: 'access', label: 'Доступ' },
  { id: 'subscription', label: 'Подписка' },
];

function ClientCard({ ctx, name, tab }) {
  const state = useCommand(ctx, ['client', 'list'], [name], { expect: 'not_found' });
  const [busy, run] = useBusy();
  const mounted = useMounted();
  const reply = state.reply;
  const row = reply && reply.ok ? model.findRow(reply.data, name) : null;
  const vanished = Boolean(reply && (reply.ok ? !row : reply.error && reply.error.code === 'not_found'));
  useEffect(() => {
    if (!vanished) return;
    if (reply.ok) ctx.notify('warn', `Клиент «${name}» не найден.`);
    ctx.navigate('clients');
  }, [vanished, reply]);
  if (vanished) return null;

  const current = TABS.some((item) => item.id === tab) ? tab : TABS[0].id;
  const back = { href: ctx.href('clients'), label: 'Клиенты' };
  const act = (action) => run(async () => { if ((await action()) !== 'left') await state.reload(); });
  /** Переход по ответу — только пока карточка открыта. */
  const leave = (...route) => { if (mounted.current) ctx.navigate(...route); return 'left'; };
  const tabs = TABS.map((item) => ({ ...item, href: ctx.href('clients', name, item.id), active: item.id === current }));
  const props = { ctx, name, row, busy, act, leave };

  return html`<${Loaded} title=${name} back=${back} state=${state}>
    ${() => html`<${Page} title=${name} back=${back} badge=${html`<${SubscriptionBadge} row=${row} />`} tabs=${tabs}>
      ${current === 'overview' && html`<${ClientOverview} ...${props} />`}
      ${current === 'access' && html`<${ClientAccess} ...${props} />`}
      ${current === 'subscription' && html`<${ClientSubscription} ...${props} />`}
    <//>`}
  <//>`;
}

// ─── Обзор ──────────────────────────────────────────────────────────────────

function ClientOverview({ ctx, name, row, busy, act, leave }) {
  const inherit = model.inherits(row);
  const nodes = strings(row.nodes);

  /** Имя и группа одной формой (`editClientFlow`); переименованный — в новую карточку. */
  const edit = async () => {
    const renamed = await model.editClientFlow(ctx, name, row);
    return renamed === null ? undefined : leave('clients', renamed);
  };
  const remove = async () => {
    const result = await confirmed(ctx, 'Удаление клиента', 'Удалить клиента?', model.clientDeleteArgv(name));
    return model.clientDeleted(result, name) ? leave('clients') : undefined;
  };

  const actions = html`
    <${Button} kind="primary" icon="file-code" disabled=${busy} onClick=${() => act(() => model.generateFlow(ctx, { client: name }))}>Сгенерировать конфиг<//>
    <${Button} icon="pencil" disabled=${busy} onClick=${() => act(edit)}>Изменить<//>
    <${Button} icon="key-round" disabled=${busy} onClick=${() => act(() => showClient(ctx, name))}>Данные подключения<//>
    <${MoreMenu} items=${[{ label: 'Удалить клиента', icon: 'trash-2', danger: true, disabled: busy, onClick: () => act(remove) }]} />`;
  return html`<${Card} title="Обзор" actions=${actions}>
    <${Facts} items=${[
      { label: 'Группа', value: html`<${GroupLink} ctx=${ctx} group=${row.group} />` },
      { label: 'Ноды', value: html`${inherit ? 'от группы' : 'свои'} <${Chips} items=${nodes.map((node) => ({ label: node, href: ctx.href('nodes', node) }))} />` },
      { label: 'Подписка', value: model.subscriptionState(row) },
    ]} />
  <//>`;
}

// ─── Данные подключения ─────────────────────────────────────────────────────

async function viewConfig(ctx, name) {
  const content = await model.readClientConfig(ctx, name);
  if (content === null) return;
  await ctx.show({ title: `Конфиг: ${name}`, wide: true, body: html`<pre class="plan">${content}</pre>` });
}

async function downloadConfig(ctx, name) {
  const content = await model.readClientConfig(ctx, name);
  if (content !== null) downloadText(`${name}.yaml`, content);
}

/** Явный запрос: данные подключения показываются только здесь (`show_client`). */
async function showClient(ctx, name) {
  const read = await fetchData(ctx, ['client', 'show', '--name', name]);
  if (!read) return;
  const body = html`
    <${Context} lines=${model.clientDataLines(read.data || {})} />
    <div class="row">
      <${Button} icon="file-code" onClick=${() => viewConfig(ctx, name)}>Показать конфиг<//>
      <${Button} icon="download" onClick=${() => downloadConfig(ctx, name)}>Скачать конфиг<//>
    </div>`;
  await ctx.show({ title: `Данные клиента: ${name}`, wide: true, body });
}

// ─── Доступ: ноды и подключения ─────────────────────────────────────────────

function ClientAccess({ ctx, name, row, busy, act }) {
  const inherit = model.inherits(row);
  const nodes = strings(row.nodes);
  const assigned = useCommand(ctx, inherit ? null : ['client', 'connections', '--name', name], [nodes.join('\n')]);
  // Список нод — только чтобы отметить назначенные ноды, которых больше нет;
  // перечитывается вместе с назначениями: нода, добавленная после открытия
  // вкладки и назначенная клиенту, не считается удалённой.
  const known = useCommand(ctx, inherit ? null : ['node', 'list'], [], { quiet: true });
  const change = (action) => act(async () => {
    await action();
    if (!inherit) await Promise.all([assigned.reload(), known.reload()]);
  });

  const reset = (node) => confirmed(ctx, 'Сброс подключений', 'Сбросить подключения ноды?', model.resetConnectionsArgv(name, node));

  const actions = html`<${Button} kind="primary" icon="pencil" disabled=${busy} onClick=${() => change(() => model.clientNodesFlow(ctx, name, row))}>Изменить ноды<//>`;
  return html`
    <${Card} title="Доступ" actions=${actions}>
      <${Facts} items=${[
        { label: 'Режим', value: inherit ? 'от группы' : 'свои' },
        { label: 'Ноды', value: html`<${Chips} items=${nodes.map((node) => ({ label: node, href: ctx.href('nodes', node) }))} />` },
      ]} />
    <//>
    ${!inherit && html`<${Loaded} title="Подключения по нодам" state=${assigned} inline>
      ${(data) => html`<${Card} title="Подключения по нодам">
        <${DataTable} rows=${model.ownNodeRows(nodes, known.data)} empty="Нет своих нод"
          href=${(item) => ctx.href('nodes', item.name)}
          menu=${(item) => [
            { label: 'Настроить', icon: 'settings', disabled: busy || item.missing,
              onClick: () => change(() => model.clientConnectionsFlow(ctx, name, item.name, assigned.data)) },
            { label: 'Сбросить', icon: 'refresh-cw', danger: true, disabled: busy, onClick: () => change(() => reset(item.name)) },
          ]}
          columns=${[
            { key: 'name', label: 'Нода', render: (item) => html`${item.name}${item.missing && html` <${Badge} tone="warn">ноды больше нет<//>`}` },
            { key: 'proxies', label: 'Подключения', render: (item) => {
              const proxies = model.assignedProxies(data, item.name);
              return proxies.length === 0 ? html`<span class="t-dim">групповые</span>` : proxies.join(', ');
            } },
          ]} />
      <//>`}
    <//>`}`;
}

// ─── Подписка ───────────────────────────────────────────────────────────────

function ClientSubscription({ ctx, name, row, busy, act }) {
  // Нечитаемый хост не мешает действиям (v1 `sub host || true`): строка «не удалось прочитать», причина — в журнале.
  const host = useCommand(ctx, ['subscription', 'host'], [], { quiet: true });
  const isPublished = Boolean(row.subscription && row.subscription.published === true);

  const publish = () => model.publishFlow(ctx, name, row, (client) => showShare(ctx, client));
  const rotate = async () => {
    const reply = await confirmed(ctx, 'Смена токена подписки', 'Сменить токен?', model.subscriptionRotateArgv(name));
    if (model.published(reply)) await showShare(ctx, name);
  };
  const revoke = () => confirmed(ctx, 'Отзыв подписки', 'Отозвать подписку?', model.subscriptionRevokeArgv(name));

  const actions = html`
    <${Button} kind="primary" icon="send" disabled=${busy} onClick=${() => act(publish)}>${isPublished ? 'Продлить' : 'Опубликовать'}<//>
    ${isPublished && html`<${Button} icon="external-link" disabled=${busy} onClick=${() => act(() => showShare(ctx, name))}>Показать ссылку<//>`}
    <${Button} disabled=${busy} onClick=${() => act(() => model.resolvedHeaders(ctx, name))}>Итоговые заголовки<//>
    <${Button} disabled=${busy} onClick=${() => act(() => model.showHeaders(ctx, 'client', name))}>Заголовки клиента<//>
    <${MoreMenu} items=${[
      { label: 'Сменить токен', icon: 'key-round', danger: true, disabled: busy, onClick: () => act(rotate) },
      { label: 'Отозвать', icon: 'x', danger: true, disabled: busy, onClick: () => act(revoke) },
    ]} />`;
  const line = host.reply ? model.hostLine(host.reply) : null;
  return html`<${Card} title="Подписка" actions=${actions}>
    <${Facts} items=${[
      { label: 'Подписка', value: model.subscriptionState(row) },
      { label: 'Хост', value: line && html`<span class=${line.tone ? `t-${line.tone}` : ''}>${line.text}</span>` },
    ]} />
  <//>`;
}
