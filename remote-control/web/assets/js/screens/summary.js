// Сводка `#/` — `tui/src/system.rs::dashboard_view`: показатели из `status`
// и `subscription list`, «Требует внимания» (`attentionItems`) и быстрые
// действия (добавить ноду или клиента, сгенерировать конфиги).
import { html } from '../../vendor/preact-htm.js';
import { Page, Card, Stats, Stat, Empty, Badge, Button } from '../ui.js';
import { useCommand, useBusy, Loaded, rows } from './kit.js';
import { dashboardView, attentionItems } from './system-model.js';
import { addNodeFlow, setNodePassword, setupSsh } from './nodes.js';
import { addClientFlow } from './clients.js';
import { generateFlow } from './generate.js';

const count = (value) => (Number.isInteger(value) && value >= 0 ? value : 0);

export function SummaryScreen({ ctx }) {
  const state = useCommand(ctx, ['status']);
  const subscriptions = useCommand(ctx, ['subscription', 'list'], [], { quiet: true });
  const [busy, run] = useBusy();
  const version = ctx.hello && typeof ctx.hello.version === 'string' ? ctx.hello.version : '';
  const reload = async () => {
    await Promise.all([state.reload(), subscriptions.reload()]);
    ctx.refreshStatus();
  };
  const act = (action) => run(async () => { await action(); await reload(); });
  const resolve = (item) => {
    const { action } = item;
    if (action.type === 'password') return act(() => setNodePassword(ctx, action.node));
    if (action.type === 'ssh-setup') return act(() => setupSsh(ctx));
    return ctx.navigate(action.route);
  };
  const actions = html`
    <${Button} kind="primary" icon="plus" disabled=${busy} onClick=${() => act(() => addNodeFlow(ctx))}>Добавить ноду<//>
    <${Button} icon="plus" disabled=${busy} onClick=${() => act(() => addClientFlow(ctx))}>Добавить клиента<//>
    <${Button} icon="wand-sparkles" disabled=${busy} onClick=${() => act(() => generateFlow(ctx))}>Сгенерировать конфиги<//>`;
  return html`<${Loaded} title="Сводка" state=${state}>${(data) => {
    const view = dashboardView(data, version);
    const counts = (data && data.counts) || {};
    const subs = subscriptions.reply === null ? '…' : subscriptions.reply.ok ? String(rows(subscriptions.data).length) : '—';
    const items = attentionItems(data, ctx.hello);
    return html`<${Page} title="Сводка" subtitle=${view.title} actions=${actions}>
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
