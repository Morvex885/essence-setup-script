// AmneziaWG: `#/awg` — выбор ноды (`nodes.rs::AmneziaWg`), `#/awg/<нода>` —
// клиенты AmneziaWG на ноде (`awg_node`). Команды над нодой — `ctx.nodeRequest`.
import { html, useEffect, useState } from '../../vendor/preact-htm.js';
import { Card } from '../ui.js';
import { nodeLabel } from './nodes.js';
import { useCommand, useBusy, Action, Actions, Context, Back, Loaded } from './kit.js';
import {
  EMPTY, NO_NODES, rows, nodeText, awgStatusArgv, awgSyncArgv, awgRemovePeerArgv, awgOrphansArgv, awgView,
  AWG_REMOVE_TITLE, AWG_ORPHANS_TITLE,
} from './nodeops-model.js';

export function AwgScreen({ ctx, param }) {
  return param === null || param === undefined
    ? html`<${AwgNodes} ctx=${ctx} />`
    : html`<${AwgNode} ctx=${ctx} name=${param} />`;
}

function AwgNodes({ ctx }) {
  const state = useCommand(ctx, ['node', 'list']);
  return html`<${Loaded} title="AmneziaWG" state=${state}>${(data) => html`<${Card} title="AmneziaWG">
    ${rows(data).length === 0 && html`<${Context} lines=${[{ text: NO_NODES, tone: 'dim' }]} />`}
    <${Actions} column>
      ${rows(data).map((node) => html`<${Action} key=${nodeText(node.name)} tone="view"
        onClick=${() => ctx.navigate('awg', nodeText(node.name))}>${nodeLabel(node)}<//>`)}
    <//>
    <${Actions}><${Back} ctx=${ctx} to="summary" /><//>
  <//>`}<//>`;
}

function AwgNode({ ctx, name }) {
  const [view, setView] = useState(null);
  const [busy, run] = useBusy();

  /** `awg status`; любой отказ возвращает к выбору ноды. */
  const load = async () => {
    const reply = await ctx.nodeRequest(name, awgStatusArgv(name), null);
    if (!reply.ok) {
      ctx.navigate('awg');
      return;
    }
    setView(awgView(reply.data));
  };

  useEffect(() => { run(load); }, [name]);

  const actions = {
    refresh: load,
    sync: async () => {
      await ctx.nodeRequest(name, awgSyncArgv(name), null);
      await load();
    },
    remove: async () => {
      const peer = await ctx.choose({
        title: AWG_REMOVE_TITLE,
        options: view.removable.map((item) => ({ value: item, label: item })),
        empty: EMPTY,
      });
      if (peer !== null) {
        await ctx.nodeRequest(name, awgRemovePeerArgv(name, peer), { title: AWG_REMOVE_TITLE, question: 'Удалить?' });
      }
      await load();
    },
    orphans: async () => {
      await ctx.nodeRequest(name, awgOrphansArgv(name), { title: AWG_ORPHANS_TITLE, question: 'Удалить?' });
      await load();
    },
  };

  const title = `AmneziaWG: ${name}`;
  if (!view) return html`<${Card} title=${title}><p class="dim">Загрузка…</p><//>`;
  return html`<${Card} title=${title}>
    <${Context} lines=${view.lines} />
    <${Actions} column>
      ${view.actions.map((action) => html`<${Action} key=${action.id} tone=${action.tone} disabled=${busy}
        onClick=${() => run(actions[action.id])}>${action.label}<//>`)}
      <${Back} ctx=${ctx} to="awg" />
    <//>
  <//>`;
}
