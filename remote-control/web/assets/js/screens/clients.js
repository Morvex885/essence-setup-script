// Клиенты (`#/clients`, `#/clients/<имя>`) — перенос `clients.rs::clients`,
// `delete_clients`, `client_card`, `show_client`, `client_nodes`,
// `client_connections`. Подписка клиента — `shared.js::clientSubscription`.
import { html, useEffect } from '../../vendor/preact-htm.js';
import { Card, Table, Button, downloadText } from '../ui.js';
import { useCommand, useBusy, Action, Actions, Context, Back, Loaded } from './kit.js';
import { execute, confirmed, fetchData, required, runGenerate, clientSubscription } from './shared.js';
import * as model from './clients-model.js';

export function ClientsScreen({ ctx, param }) {
  return param === null || param === undefined
    ? html`<${ClientList} ctx=${ctx} />`
    : html`<${ClientCard} ctx=${ctx} name=${param} key=${param} />`;
}

// ─── Список ─────────────────────────────────────────────────────────────────

function ClientList({ ctx }) {
  const state = useCommand(ctx, ['client', 'list']);
  const [busy, run] = useBusy();
  const act = (action) => run(async () => { await action(); await state.reload(); });

  const add = async () => {
    const name = await required(ctx, 'Добавить клиента', 'Имя клиента', 'Имя клиента не указано.');
    if (name === null) return;
    const group = await model.pick(ctx, 'group', 'Группа клиента');
    if (group === null || group === undefined) return;
    await execute(ctx, ['client', 'add', '--name', name, '--group', group]);
  };
  const remove = async () => {
    const targets = model.names(state.data);
    const selected = await ctx.toggle({
      title: 'Удаление клиентов', options: targets.map((name) => ({ value: name, label: name })), selected: [], empty: model.EMPTY, submit: 'Удалить',
    });
    if (selected === null || selected === undefined) return;
    if (selected.length === 0) { ctx.notify('warn', model.NOTHING_SELECTED); return; }
    await confirmed(ctx, 'Удаление клиентов', 'Удалить выбранных клиентов?', model.deleteClientsArgv(selected));
  };

  const actions = html`
    <${Action} tone="create" disabled=${busy || !state.data} onClick=${() => act(add)}>Добавить клиента<//>
    <${Action} tone="danger" disabled=${busy || !state.data} onClick=${() => act(remove)}>Удалить клиентов<//>`;
  return html`<${Loaded} title="Клиенты" state=${state} actions=${actions}>
    ${(data) => html`<${Card} title="Клиенты" actions=${actions}>
      <${Table} empty="Нет клиентов"
        columns=${[
          { key: 'name', label: 'Клиент', render: (row) => html`<${Button} kind="view" onClick=${() => ctx.navigate('clients', row.name)}>${model.str(row.name)}<//>` },
          { key: 'group', label: 'Группа', render: (row) => model.str(row.group) },
        ]}
        rows=${model.rowsOf(data)} />
    <//>`}
  <//>`;
}

// ─── Карточка ───────────────────────────────────────────────────────────────

function ClientCard({ ctx, name }) {
  const state = useCommand(ctx, ['client', 'list'], [name], { expect: 'not_found' });
  const [busy, run] = useBusy();
  const reply = state.reply;
  const back = html`<${Back} ctx=${ctx} to="clients" />`;
  const row = reply && reply.ok ? model.findRow(reply.data, name) : null;
  const vanished = Boolean(reply && (reply.ok ? !row : reply.error && reply.error.code === 'not_found'));
  useEffect(() => {
    if (!vanished) return;
    if (reply.ok) ctx.notify('warn', `Клиент «${name}» не найден.`);
    ctx.navigate('clients');
  }, [vanished, reply]);
  if (vanished) return null;
  const act = (action) => run(async () => { if ((await action()) !== 'left') await state.reload(); });
  const inherit = row ? model.inherits(row) : true;
  const nodes = row ? model.strings(row.nodes) : [];

  const rename = async () => {
    const next = await required(ctx, 'Переименование клиента', 'Новое имя клиента', 'Имя клиента не указано.');
    if (next === null) return undefined;
    const result = await confirmed(ctx, 'Переименование клиента', 'Переименовать клиента?', ['client', 'rename', '--name', name, '--new-name', next]);
    const renamed = model.renamedName(result);
    if (renamed !== null && renamed !== name) { ctx.navigate('clients', renamed); return 'left'; }
    return undefined;
  };
  const remove = async () => {
    const result = await confirmed(ctx, 'Удаление клиента', 'Удалить клиента?', ['client', 'delete', '--name', name]);
    if (model.clientDeleted(result, name)) { ctx.navigate('clients'); return 'left'; }
    return undefined;
  };
  const setGroup = async () => {
    const group = await model.pick(ctx, 'group', 'Новая группа клиента');
    if (group === null || group === undefined) return;
    await confirmed(ctx, 'Смена группы клиента', 'Сменить группу?', ['client', 'set-group', '--name', name, '--group', group]);
  };
  const connections = async () => {
    if (inherit) { ctx.notify('warn', 'Подключения настраиваются только для клиента со своими нодами.'); return; }
    await clientConnections(ctx, name, nodes);
  };

  return html`<${Loaded} title=${`Клиент: ${name}`} state=${state} actions=${back}>
    ${() => html`<${Card} title=${`Клиент: ${name}`} actions=${back}>
      <${Context} lines=${model.clientContext(row)} />
      <${Actions}>
        <${Action} tone="view" disabled=${busy} onClick=${() => act(() => showClient(ctx, name))}>Показать данные подключения<//>
        <${Action} tone="view" disabled=${busy} onClick=${() => act(() => clientSubscription(ctx, name))}>Подписка<//>
      <//>
      <${Actions}>
        <${Action} tone="change" disabled=${busy} onClick=${() => act(() => runGenerate(ctx, ['--client', name]))}>Сгенерировать конфиг<//>
        <${Action} tone="change" disabled=${busy} onClick=${() => act(() => clientNodes(ctx, name, inherit, nodes))}>Ноды клиента<//>
        <${Action} tone="change" disabled=${busy} onClick=${() => act(connections)}>Подключения по нодам<//>
        <${Action} tone="change" disabled=${busy} onClick=${() => act(setGroup)}>Сменить группу<//>
        <${Action} tone="change" disabled=${busy} onClick=${() => act(rename)}>Переименовать<//>
        <${Action} tone="danger" disabled=${busy} onClick=${() => act(remove)}>Удалить клиента<//>
      <//>
    <//>`}
  <//>`;
}

// ─── Данные подключения ─────────────────────────────────────────────────────

/** `client config`: `null` — сбой или конфиг не создан (сообщение показано). */
async function readConfig(ctx, name) {
  const read = await fetchData(ctx, ['client', 'config', '--name', name]);
  if (!read) return null;
  const data = read.data || {};
  if (data.exists === false || typeof data.content !== 'string') { ctx.notify('warn', 'Конфиг не создан'); return null; }
  return data.content;
}

async function viewConfig(ctx, name) {
  const content = await readConfig(ctx, name);
  if (content === null) return;
  await ctx.show({ title: `Конфиг: ${name}`, wide: true, body: html`<pre class="plan">${content}</pre>` });
}

async function downloadConfig(ctx, name) {
  const content = await readConfig(ctx, name);
  if (content !== null) downloadText(`${name}.yaml`, content);
}

/** Явный запрос: данные подключения показываются только здесь (`show_client`). */
async function showClient(ctx, name) {
  const read = await fetchData(ctx, ['client', 'show', '--name', name]);
  if (!read) return;
  const body = html`
    <${Context} lines=${model.clientDataLines(read.data || {})} />
    <${Actions}>
      <${Action} tone="view" onClick=${() => viewConfig(ctx, name)}>Показать конфиг<//>
      <${Action} tone="view" onClick=${() => downloadConfig(ctx, name)}>Скачать конфиг<//>
    <//>`;
  await ctx.show({ title: `Данные клиента: ${name}`, wide: true, body });
}

// ─── Ноды и подключения ─────────────────────────────────────────────────────

/** `clients.rs::client_nodes`: отметки — текущие ноды клиента. */
async function clientNodes(ctx, name, inherit, current) {
  const menu = model.clientNodesMenu(name, inherit);
  const choice = await ctx.choose({ title: menu.title, options: menu.options });
  if (choice === null || choice === undefined) return;
  if (choice === 'inherit') {
    await confirmed(ctx, 'Ноды клиента', 'Вернуть ноды от группы?', model.inheritNodesArgv(name));
    return;
  }
  const read = await fetchData(ctx, ['node', 'list']);
  if (!read) return;
  const list = model.rowsOf(read.data);
  const targets = model.names(list);
  const selected = await ctx.toggle({
    title: `Свои ноды клиента: ${name}`,
    options: list.map((row) => ({ value: model.str(row.name), label: model.nodeLabel(row) })),
    selected: targets.filter((node) => current.includes(node)),
    empty: model.EMPTY,
  });
  if (selected === null || selected === undefined) return;
  if (selected.length === 0) { ctx.notify('warn', model.NOTHING_SELECTED); return; }
  await execute(ctx, model.clientNodesArgv(name, selected));
}

/** `clients.rs::client_connections`: только для своих нод клиента. */
async function clientConnections(ctx, name, own) {
  if (own.length === 0) { ctx.notify('warn', 'У клиента нет своих нод.'); return; }
  const read = await fetchData(ctx, ['node', 'list']);
  if (!read) return;
  const available = model.availableNodes(read.data, own);
  if (available.length === 0) { ctx.notify('warn', 'Назначенные ноды больше недоступны.'); return; }
  const node = await ctx.choose({
    title: `Подключения клиента: ${name}`,
    options: available.map((row) => ({ value: model.str(row.name), label: model.nodeLabel(row), tone: 'view' })),
  });
  if (node === null || node === undefined) return;
  const action = await ctx.choose({
    title: `Подключения: ${name} на ${node}`,
    options: [{ value: 'set', label: 'Настроить подключения', tone: 'change' }, { value: 'reset', label: 'Сбросить на групповые', tone: 'danger' }],
  });
  if (action === null || action === undefined) return;
  if (action === 'reset') {
    await confirmed(ctx, 'Сброс подключений', 'Сбросить подключения ноды?', model.resetConnectionsArgv(name, node));
    return;
  }
  const assigned = await fetchData(ctx, ['client', 'connections', '--name', name]);
  if (!assigned) return;
  const current = model.assignedProxies(assigned.data, node);
  const found = await ctx.nodeRequest(node, ['conn', 'list', '--name', node, '--discover'], null);
  if (!found.ok) return;
  const proxies = model.discoveredProxies(found.data);
  const selected = await ctx.toggle({
    title: `Подключения клиента на ${node}`,
    options: proxies.map((proxy) => ({ value: proxy, label: proxy })),
    selected: proxies.filter((proxy) => current.includes(proxy)),
    empty: model.EMPTY,
  });
  if (selected === null || selected === undefined) return;
  if (selected.length === 0) { ctx.notify('warn', model.NOTHING_SELECTED); return; }
  await execute(ctx, model.clientConnectionsArgv(name, node, selected));
}
