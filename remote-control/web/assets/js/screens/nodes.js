// Ноды (`#/nodes`) и карточка ноды (`#/nodes/<имя>/<вкладка>`) — перенос
// `tui/src/nodes.rs`: `Nodes`, `NodeCard`. Действия (`delete_node`,
// `add_node_with`, `harden`, `setup_ssh`, `interactive`, профиль, домен,
// порты) — `nodes-model.js`, применение — `apply-model.js`. Вкладки
// карточки: обзор, подключения (`connections.js`), AmneziaWG (`awg.js`),
// обслуживание.
import { html, useEffect, useState } from '../../vendor/preact-htm.js';
import { Page, Card, DataTable, MoreMenu, Facts, Badge, Chips, Empty, Button } from '../ui.js';
import { asList } from '../format.js';
import { useCommand, useBusy, useMounted, Loaded } from './kit.js';
import { NodeConnections } from './connections.js';
import { NodeAwg } from './awg.js';
import { syncAll, nodeCheckArgv } from './nodeops-model.js';
import { applyState, applyFlow, pendingNodes, APPLY_PENDING_ARGV } from './apply-model.js';
import * as model from './nodes-model.js';

// ─── Список нод ──────────────────────────────────────────────────────────────

/** Группы ноды в обзоре синхронизации: `группа назначено/всего` или проблема ноды. */
function OverviewGroups({ ctx, node }) {
  if (node.problem) return html`<${Badge} tone="warn">${node.problem}<//>`;
  if (node.groups.length === 0) return html`<span class="t-dim">нет групп</span>`;
  return html`<span class="chips">${node.groups.map((group) => html`<a key=${group.name} href=${ctx.href('groups', group.name)}
    class="badge badge-soft badge-sm chip ${group.tone === 'ok' ? 'badge-success' : group.tone === 'warn' ? 'badge-warning' : 'badge-ghost'}">
    ${group.name}: ${group.count}</a>`)}</span>`;
}

function ProfileLink({ ctx, profile }) {
  return profile ? html`<a class="link" href=${ctx.href('profiles', profile)}>${profile}</a>` : html`<span class="t-dim">—</span>`;
}

function NodeList({ ctx }) {
  const list = useCommand(ctx, ['node', 'list']);
  const [busy, run] = useBusy();
  const mounted = useMounted();
  // Обзор подключений всех нод — после «Синхронизировать все».
  const [overview, setOverview] = useState(null);
  const pending = Boolean(ctx.status && ctx.status.ssh_setup_pending === true);
  const reload = () => { list.reload(); ctx.refreshStatus(); };
  // Перечитывание и при сбое действия: сеанс терминала мог изменить ноду до обрыва.
  const then = (action) => run(async () => {
    try { await action(); } finally { reload(); }
  });
  const go = (name) => { if (mounted.current) ctx.navigate('nodes', name); };
  const add = () => run(async () => {
    if (!(await model.addNodeFlow(ctx, go))) reload();
  });
  const syncNodes = () => run(async () => {
    const nodes = await syncAll(ctx);
    if (nodes !== null && mounted.current) setOverview(nodes);
    reload();
  });
  const waiting = list.data ? pendingNodes(list.data).length : 0;
  const addButton = html`<${Button} kind="primary" icon="plus" disabled=${busy} onClick=${add}>Добавить ноду<//>`;
  const actions = html`
    ${pending && html`<${Button} icon="key-round" disabled=${busy} onClick=${() => then(() => model.setupSsh(ctx))}>Завершить SSH-настройку<//>`}
    <${Button} icon="check" disabled=${busy || waiting === 0} onClick=${() => then(() => applyFlow(ctx, APPLY_PENDING_ARGV))}>Применить на всех ожидающих<//>
    <${Button} icon="refresh-cw" disabled=${busy} onClick=${syncNodes}>Синхронизировать все<//>
    ${addButton}
  `;
  const columns = [
    { key: 'name', label: 'Название', search: true },
    { key: 'address', label: 'Адрес', search: true, render: (row) => html`<span class="mono">${row.address}</span>` },
    { key: 'tag', label: 'Тег', search: true },
    { key: 'profile', label: 'Профиль', search: true, render: (row) => html`<${ProfileLink} ctx=${ctx} profile=${row.profile} />` },
    { key: 'apply', label: 'Применение', render: (row) => html`<${Badge} tone=${row.apply.tone}>${row.apply.label}<//>` },
    { key: 'state', label: 'Состояние', render: (row) => html`<${Badge} tone=${row.state.tone}>${row.state.label}<//>` },
  ];
  const menu = (row) => [
    { label: 'Применить', icon: 'check', disabled: busy || !row.profile, onClick: () => then(() => model.applyNode(ctx, row.name)) },
    { label: 'Проверить подключение', icon: 'refresh-cw', disabled: busy, onClick: () => then(() => ctx.nodeRequest(row.name, nodeCheckArgv(row.name))) },
    { label: 'Изменить', icon: 'pencil', disabled: busy, onClick: () => then(() => model.editNode(ctx, row.node)) },
    { label: 'Удалить', icon: 'trash-2', danger: true, disabled: busy, onClick: () => then(() => model.deleteListed(ctx, row.name)) },
  ];
  return html`<${Loaded} title="Ноды" state=${list} actions=${actions}>${(data) => {
    const table = asList(data).map((node) => ({
      node,
      name: model.plain(node.name),
      address: `${model.plain(node.ip)}:${model.plain(node.port)}`,
      tag: model.plain(node.tag),
      profile: model.plain(node.profile),
      apply: applyState(node),
      auth: model.authLabel(node),
      state: model.nodeStatus(node),
    }));
    return html`<${Page} title="Ноды" actions=${actions}>
      <${Card}>
        ${table.length === 0
          ? html`<${Empty} icon="server" title="Нет нод" action=${addButton} />`
          : html`<${DataTable} columns=${columns} rows=${table} href=${(row) => ctx.href('nodes', row.name)} menu=${menu} />`}
      <//>
      ${overview && html`<${Card} title="Подключения по группам">
        <p class="t-dim">Назначено подключений группе / подключений профиля ноды при последней синхронизации.</p>
        <${DataTable} rows=${overview} empty="Нет нод" href=${(row) => ctx.href('nodes', row.name, 'connections')}
          columns=${[
            { key: 'name', label: 'Нода', search: true },
            { key: 'groups', label: 'Группы', render: (row) => html`<${OverviewGroups} ctx=${ctx} node=${row} />` },
          ]} />
      <//>`}
    <//>`;
  }}<//>`;
}

// ─── Карточка ноды ───────────────────────────────────────────────────────────

const TABS = [
  { id: 'overview', label: 'Обзор' },
  { id: 'connections', label: 'Подключения' },
  { id: 'awg', label: 'AmneziaWG' },
  { id: 'maintenance', label: 'Обслуживание' },
];

function Overview({ ctx, node }) {
  const password = model.passwordStatus(node);
  const issues = model.joinedPlain(node.issues);
  const apply = applyState(node);
  const ports = node.ports && typeof node.ports === 'object' ? Object.entries(node.ports) : [];
  return html`<${Card}>
    <${Facts} items=${[
      { label: 'Адрес', value: html`<span class="mono">${model.plain(node.ip)}:${model.plain(node.port)}</span>` },
      { label: 'Пользователь', value: model.plain(node.user) },
      { label: 'Вход', value: model.authLabel(node) },
      { label: 'Пароль SSH', value: password && html`<${Badge} tone=${password.tone}>${password.label}<//>` },
      { label: 'Тег', value: model.plain(node.tag) || '—' },
      { label: 'Профиль', value: html`<${ProfileLink} ctx=${ctx} profile=${model.plain(node.profile)} />` },
      { label: 'Домен', value: model.plain(node.domain) || '—' },
      { label: 'Порты ноды', value: ports.length ? ports.map(([key, value]) => `${key}: ${model.plain(value)}`).join(', ') : 'как в профиле' },
      { label: 'Применение', value: html`<${Badge} tone=${apply.tone}>${apply.label}<//>` },
      { label: 'Подключения', value: model.joinedPlain(node.proxies) || '—' },
      { label: 'WARP', value: model.warpLabel(node) },
      { label: 'Требует настройки', value: issues && html`<${Badge} tone="warn">${issues}<//>` },
      { label: 'Группы', value: html`<${Chips} items=${asList(node.groups).map((group) => ({ label: model.plain(group), href: ctx.href('groups', model.plain(group)) }))} />` },
      { label: 'Клиентов', value: model.plain(node.clients) },
    ]} />
  <//>`;
}

function OpRow({ title, desc, children }) {
  return html`<div class="op-row">
    <div class="op-text"><div class="op-title">${title}</div><div class="op-desc">${desc}</div></div>
    ${children}
  </div>`;
}

function Maintenance({ busy, act, remove }) {
  return html`
    <${Card} title="Обслуживание">
      <div class="op-list">
        <${OpRow} title="Проверить подключение" desc="Проверить SSH-подключение к ноде.">
          <${Button} icon="refresh-cw" disabled=${busy} onClick=${act.check}>Проверить<//>
        <//>
        <${OpRow} title="Усилить защиту SSH" desc="Перенести SSH на другой порт и закрыть вход по паролю — по плану ядра.">
          <${Button} icon="shield" disabled=${busy} onClick=${act.harden}>Усилить<//>
        <//>
        <${OpRow} title="Telegram Proxy на ноде" desc="Меню Telegram Proxy этой ноды в терминале.">
          <${Button} icon="send" disabled=${busy} onClick=${act.telegram}>Открыть<//>
        <//>
      </div>
    <//>
    <${Card} title="Опасная зона" className="danger-zone">
      <div class="danger-row">
        <span>Удалить ноду из remote-control и, по выбору, компоненты Essence на сервере.</span>
        <${Button} kind="danger" icon="trash-2" disabled=${busy} onClick=${remove}>Удалить ноду<//>
      </div>
    <//>
  `;
}

function NodeCard({ ctx, name, tab }) {
  const show = useCommand(ctx, ['node', 'show', '--name', name], [], { expect: 'not_found' });
  const [busy, run] = useBusy();
  const mounted = useMounted();
  useEffect(() => {
    if (show.reply && show.reply.error && show.reply.error.code === 'not_found') ctx.navigate('nodes');
  }, [show.reply]);
  const back = { href: ctx.href('nodes'), label: 'Ноды' };
  const active = TABS.some((item) => item.id === tab) ? tab : TABS[0].id;
  const tabs = TABS.map((item) => ({ ...item, href: ctx.href('nodes', name, item.id), active: item.id === active }));
  /** Действие и перечитывание карточки (и при сбое: терминал мог изменить ноду). */
  const then = (action) => run(async () => {
    try { await action(); } finally { show.reload(); }
  });
  const go = (...route) => { if (mounted.current) ctx.navigate(...route); };

  return html`<${Loaded} title=${name} back=${back} state=${show}>${(node) => {
    const password = node.auth === 'password';
    const status = model.nodeStatus(node);
    const hasProfile = Boolean(model.plain(node.profile));
    const act = {
      check: () => then(() => ctx.nodeRequest(name, nodeCheckArgv(name))),
      harden: () => then(() => model.harden(ctx, name)),
      telegram: () => then(() => model.interactive(ctx, name, true)),
    };
    const remove = () => run(async () => {
      if (await model.deleteNode(ctx, name, node)) { go('nodes'); return; }
      show.reload();
    });
    const edit = () => run(async () => {
      const current = await model.editNode(ctx, node);
      if (current !== null && current !== name) { go('nodes', current, active); return; }
      show.reload();
    });
    const actions = active === 'overview' && html`
      <${Button} kind="primary" icon="check" disabled=${busy || (!hasProfile && node.status !== 'pending')}
        onClick=${() => then(() => model.applyNode(ctx, name))}>Применить<//>
      <${Button} icon="layers" disabled=${busy} onClick=${() => then(() => model.nodeProfileFlow(ctx, name, node))}>Профиль<//>
      <${Button} icon="pencil" disabled=${busy} onClick=${() => then(() => model.nodeDomainFlow(ctx, name, node))}>Домен<//>
      <${Button} icon="terminal" disabled=${busy} onClick=${() => then(() => model.interactive(ctx, name, false))}>Оболочка<//>
      <${MoreMenu} items=${[
        { label: 'Порты', icon: 'settings', disabled: busy || !hasProfile, onClick: () => then(() => model.nodePortsFlow(ctx, name, node)) },
        { label: 'Изменить', icon: 'pencil', disabled: busy, onClick: edit },
        ...(password ? [{ label: 'Пароль SSH', icon: 'key-round', disabled: busy, onClick: () => then(() => model.setNodePassword(ctx, name)) }] : []),
        { label: 'Проверить подключение', icon: 'refresh-cw', disabled: busy, onClick: act.check },
        { label: 'Удалить ноду', icon: 'trash-2', danger: true, disabled: busy, onClick: remove },
      ]} />
    `;
    let body;
    switch (active) {
      case 'connections': body = html`<${NodeConnections} ctx=${ctx} name=${name} />`; break;
      case 'awg': body = html`<${NodeAwg} ctx=${ctx} name=${name} />`; break;
      case 'maintenance': body = html`<${Maintenance} busy=${busy} act=${act} remove=${remove} />`; break;
      default: body = html`<${Overview} ctx=${ctx} node=${node} />`;
    }
    const apply = applyState(node);
    return html`<${Page} title=${name} back=${back} tabs=${tabs} actions=${actions}
      subtitle=${`${model.plain(node.ip)}:${model.plain(node.port)}`}
      badge=${html`<span class="row"><${Badge} tone=${status.tone}>${status.label}<//><${Badge} tone=${apply.tone}>${apply.label}<//></span>`}>
      ${body}
    <//>`;
  }}<//>`;
}

/** `#/nodes` — список, `#/nodes/<имя>/<вкладка>` — карточка. */
export function NodesScreen({ ctx, param, tab }) {
  return param
    ? html`<${NodeCard} key=${param} ctx=${ctx} name=${param} tab=${tab} />`
    : html`<${NodeList} ctx=${ctx} />`;
}
