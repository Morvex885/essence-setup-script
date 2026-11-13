// Сводка `#/` — `tui/src/system.rs::dashboard_view`: показатели из `status`
// и `subscription list`, «Требует внимания» (`attentionItems`) и быстрые
// действия (добавить ноду или клиента, сгенерировать конфиги).
import { html } from '../../vendor/preact-htm.js';
import { Page, Card, Stats, Stat, Empty, Badge, Button } from '../ui.js';
import { asList } from '../format.js';
import { useCommand, useBusy, useMounted, Loaded } from './kit.js';
import { dashboardTitle, attentionItems } from './system-model.js';
import { addNodeFlow, setNodePassword, setupSsh } from './nodes-model.js';
import { addClientFlow, generateFlow } from './clients-model.js';

const count = (value) => (Number.isInteger(value) && value >= 0 ? value : 0);

export function SummaryScreen({ ctx }) {
  const state = useCommand(ctx, ['status']);
  const subscriptions = useCommand(ctx, ['subscription', 'list'], [], { quiet: true });
  const groups = useCommand(ctx, ['group', 'list'], [], { quiet: true });
  const nodes = useCommand(ctx, ['node', 'list'], [], { quiet: true });
  const [busy, run] = useBusy();
  const mounted = useMounted();
  const version = ctx.hello && typeof ctx.hello.version === 'string' ? ctx.hello.version : '';
  // Шапка перечитывает `status` сама по окончании изменяющей команды.
  const reload = () => Promise.all([state.reload(), subscriptions.reload(), groups.reload(), nodes.reload()]);
  const act = (action) => run(async () => { await action(); await reload(); });
  /** Переход к созданному объекту — только пока сводка открыта. */
  const go = (name) => (param) => { if (mounted.current) ctx.navigate(name, param); };
  const resolve = (item) => {
    const { action } = item;
    if (action.type === 'password') return act(() => setNodePassword(ctx, action.node));
    if (action.type === 'ssh-setup') return act(() => setupSsh(ctx));
    return ctx.navigate(action.route, action.param || null, action.tab || null);
  };
  const actions = html`
    <${Button} kind="primary" icon="plus" disabled=${busy} onClick=${() => act(() => addNodeFlow(ctx, go('nodes')))}>Добавить ноду<//>
    <${Button} icon="plus" disabled=${busy} onClick=${() => act(() => addClientFlow(ctx, go('clients')))}>Добавить клиента<//>
    <${Button} icon="wand-sparkles" disabled=${busy} onClick=${() => act(() => generateFlow(ctx))}>Сгенерировать конфиги<//>`;
  return html`<${Loaded} title="Сводка" state=${state}>${(data) => {
    const title = dashboardTitle(data, version);
    const counts = (data && data.counts) || {};
    const subs = subscriptions.reply === null ? '…' : subscriptions.reply.ok ? String(asList(subscriptions.data).length) : '—';
    const items = attentionItems(data, ctx.hello, { groups: groups.data, nodes: nodes.data });
    return html`<${Page} title="Сводка" subtitle=${title} actions=${actions}>
      <${Stats}>
        <${Stat} label="Ноды" value=${count(counts.nodes)} href=${ctx.href('nodes')} />
        <${Stat} label="Клиенты" value=${count(counts.clients)} href=${ctx.href('clients')} />
        <${Stat} label="Группы" value=${count(counts.groups)} href=${ctx.href('groups')} />
        <${Stat} label="Подписки" value=${subs} href=${ctx.href('subscriptions')} />
      <//>
      <${Card} title="Требует внимания">
        ${items.length === 0
          ? html`<${Empty} icon="circle-check" title="Всё в порядке" />`
          : html`<div class="attention">
              ${items.map((item) => html`<div key=${item.id} class="attention-row">
                <${Badge} tone=${item.tone}>${item.tone === 'info' ? 'совет' : 'внимание'}<//>
                <span class="attention-text">${item.text}</span>
                <${Button} disabled=${busy} onClick=${() => resolve(item)}>${item.action.label}<//>
              </div>`)}
            </div>`}
      <//>
    <//>`;
  }}<//>`;
}
