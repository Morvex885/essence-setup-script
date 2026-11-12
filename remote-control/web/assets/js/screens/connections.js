// Подключения нод: `#/connections` (`nodes.rs::Connections`) и
// `#/connections/<нода>` (`connection_node`, `assign_connections`).
// `conn sync` идёт по SSH и чистит устаревшее: обзор синхронизирует при входе
// и по кнопке, возврат из карточки ноды перечитывает только `conn list`.
import { html, useEffect, useRef, useState } from '../../vendor/preact-htm.js';
import { Card } from '../ui.js';
import { NODE_CODES } from '../flows.js';
import { aliases } from './nodes.js';
import { useBusy, Action, Actions, Context, Back, Loaded } from './kit.js';
import {
  EMPTY, NOTHING_SELECTED, NO_NODES, rows, nodeText, syncedNode, syncData, overviewNodes,
  connectionView, assignGroupsTitle, assignArgv, connSyncArgv, connListArgv, nodeCheckArgv, CONNECTION_ACTIONS,
} from './nodeops-model.js';

const TITLE = 'Подключения нод';

/** Данные последнего `conn sync` обзора и признак возврата из карточки ноды. */
const memory = { synced: undefined, resume: false };

export function ConnectionsScreen({ ctx, param }) {
  return param === null || param === undefined
    ? html`<${Overview} ctx=${ctx} />`
    : html`<${NodeConnections} ctx=${ctx} name=${param} />`;
}

/** Возврат к обзору без новой синхронизации (TUI: цикл обзора без `s`). */
function backToOverview(ctx) {
  memory.resume = true;
  ctx.navigate('connections');
}

function Overview({ ctx }) {
  const [state, setState] = useState({ synced: null, listed: null });
  const [busy, run] = useBusy();
  const current = useRef(state);
  current.current = state;

  const load = async (resync) => {
    let synced = current.current.synced;
    if (resync) {
      const reply = await ctx.call(...connSyncArgv());
      synced = syncData(reply);
      if (synced === null) {
        // `Connections::run`: сбой синхронизации — итог и выход из раздела.
        if (ctx.isFailure(reply)) ctx.failed();
        ctx.navigate('summary');
        return;
      }
      memory.synced = synced;
    }
    const listed = await ctx.call(...connListArgv());
    setState({ synced, listed });
  };

  useEffect(() => {
    const resume = memory.resume && memory.synced !== undefined;
    memory.resume = false;
    if (resume) current.current = { ...current.current, synced: memory.synced };
    run(() => load(!resume));
  }, []);

  const loaded = {
    reply: state.listed,
    data: state.listed && state.listed.ok ? state.listed.data : null,
    loading: busy,
    reload: () => run(() => load(false)),
  };
  return html`<${Loaded} title=${TITLE} state=${loaded}>${(data) => {
    const nodes = overviewNodes(data, state.synced);
    return html`<${Card} title=${TITLE}>
      ${nodes.length === 0 && html`<${Context} lines=${[{ text: NO_NODES, tone: 'dim' }]} />`}
      ${nodes.map((node) => html`<div key=${node.name} class="node-block">
        <${Action} tone="view" disabled=${busy} onClick=${() => ctx.navigate('connections', node.name)}>${node.name}<//>
        <${Context} lines=${node.problem ? [{ text: `${node.name}  ${node.problem}`, tone: 'warn' }] : node.groups} />
      </div>`)}
      <${Actions}>
        <${Action} tone="change" disabled=${busy} onClick=${() => run(() => load(true))}>Синхронизировать с нодами<//>
        <${Back} ctx=${ctx} to="summary" />
      <//>
    <//>`;
  }}<//>`;
}

function NodeConnections({ ctx, name }) {
  const [view, setView] = useState(null);
  const [busy, run] = useBusy();
  const synced = useRef(null);

  /** `conn sync --name`; при `partial` с кодом ноды — один раз `node check`. */
  const refresh = async () => {
    let resolve = true;
    for (;;) {
      const reply = await ctx.request(connSyncArgv(name), { expect: 'not_found' });
      if (reply.ok) {
        synced.current = syncedNode(reply.data, name);
        return true;
      }
      if (reply.error && reply.error.code === 'partial') {
        synced.current = syncedNode(reply.error, name);
        const code = synced.current && typeof synced.current.error === 'string' ? synced.current.error : '';
        if (resolve && NODE_CODES.includes(code)) {
          // Строка синхронизации называет только код; `node check` вернёт
          // состояние с подробностями (отпечатками) для обработчика.
          resolve = false;
          if ((await ctx.nodeRequest(name, nodeCheckArgv(name), null)).ok) continue;
        } else {
          ctx.failed();
        }
        return true;
      }
      if (reply.error && reply.error.code !== 'not_found' && ctx.isFailure(reply)) ctx.failed();
      backToOverview(ctx);
      return false;
    }
  };

  const list = async () => {
    const listed = await ctx.request(connListArgv(name), { expect: 'not_found' });
    if (!listed.ok) {
      if (listed.error && listed.error.code !== 'not_found' && ctx.isFailure(listed)) ctx.failed();
      backToOverview(ctx);
      return;
    }
    setView(connectionView(listed.data, synced.current, name));
  };

  const synchronize = async () => {
    if (await refresh()) await list();
  };

  useEffect(() => { run(synchronize); }, [name]);

  const actions = {
    assign: async () => {
      await assignConnections(ctx, name, view.proxies, view.assigned);
      await list();
    },
    aliases: async () => {
      await aliases(ctx, name);
      await list();
    },
    sync: synchronize,
  };

  const title = `Подключения ноды: ${name}`;
  if (!view) return html`<${Card} title=${title}><p class="dim">Загрузка…</p><//>`;
  return html`<${Card} title=${title}>
    <${Context} lines=${view.lines} />
    <${Actions} column>
      ${CONNECTION_ACTIONS.map((action) => html`<${Action} key=${action.id} tone=${action.tone} disabled=${busy}
        onClick=${() => run(actions[action.id])}>${action.label}<//>`)}
      <${Action} tone="plain" disabled=${busy} onClick=${() => backToOverview(ctx)}>Назад<//>
    <//>
  <//>`;
}

/**
 * Сначала подключения (отмечены назначенные), затем целевые группы (без
 * отметок). Подтверждённый пустой набор подключений снимает назначение
 * выбранных групп (`conn set` без `--proxy`); отмена любого выбора ничего не меняет.
 */
async function assignConnections(ctx, name, proxies, assigned) {
  const selected = await ctx.toggle({
    title: 'Подключения для групп',
    options: proxies.map((proxy) => ({ value: proxy, label: proxy })),
    selected: proxies.filter((_, index) => assigned[index].length > 0),
    empty: EMPTY,
    submit: 'Далее',
  });
  if (selected === null) return;
  const listed = await ctx.call('group', 'list');
  if (!listed.ok) {
    if (ctx.isFailure(listed)) ctx.failed();
    return;
  }
  const groups = rows(listed.data).map((row) => nodeText(row.name));
  const targets = await ctx.toggle({
    title: assignGroupsTitle(selected),
    options: groups.map((group) => ({ value: group, label: group })),
    selected: [],
    empty: EMPTY,
  });
  if (targets === null) return;
  if (targets.length === 0) {
    ctx.notify('warn', NOTHING_SELECTED);
    return;
  }
  const saved = await ctx.request(assignArgv(name, targets, selected));
  if (ctx.isFailure(saved)) ctx.failed();
}
