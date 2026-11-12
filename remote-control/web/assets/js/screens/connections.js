// Подключения нод: `#/connections` (`nodes.rs::Connections`) и
// `#/connections/<нода>` (`connection_node`, `assign_connections`).
// `conn sync` идёт по SSH и чистит устаревшее: обзор синхронизирует при входе
// и по кнопке, возврат из карточки ноды перечитывает только `conn list`.
import { html, useEffect, useRef, useState } from '../../vendor/preact-htm.js';
import { Card } from '../ui.js';
import { NODE_CODES } from '../flows.js';
import { aliases } from './nodes.js';
import { useBusy, useMounted, Action, Actions, Context, Back, Loaded } from './kit.js';
import {
  NO_NODES, syncedNode, syncData, overviewNodes, connectionView, assignConnections,
  connSyncArgv, connListArgv, nodeCheckArgv, CONNECTION_ACTIONS,
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
  const mounted = useMounted();

  /** `resync` — сначала `conn sync`; список показывается с последним снимком синхронизации. */
  const load = async (resync) => {
    if (resync) {
      const reply = await ctx.call(...connSyncArgv());
      const synced = syncData(reply);
      if (synced === null) {
        // `Connections::run`: сбой синхронизации — итог и выход из раздела.
        if (ctx.isFailure(reply)) ctx.failed();
        if (mounted.current) ctx.navigate('summary');
        return;
      }
      memory.synced = synced;
    }
    const listed = await ctx.call(...connListArgv());
    setState({ synced: memory.synced === undefined ? null : memory.synced, listed });
  };

  useEffect(() => {
    const resume = memory.resume && memory.synced !== undefined;
    memory.resume = false;
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
  const mounted = useMounted();
  /** Поздний отказ ушедшей карточки не уводит из выбранного раздела. */
  const leave = () => { if (mounted.current) backToOverview(ctx); };

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
      leave();
      return false;
    }
  };

  const list = async () => {
    const listed = await ctx.request(connListArgv(name), { expect: 'not_found' });
    if (!listed.ok) {
      if (listed.error && listed.error.code !== 'not_found' && ctx.isFailure(listed)) ctx.failed();
      leave();
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
