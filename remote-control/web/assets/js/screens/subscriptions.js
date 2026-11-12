// Подписки (`tui/src/clients.rs::subscriptions`, `subscription_list`):
// `subscription host|list|publish-all|migrate`, подписка клиента и заголовки
// группы — через `shared.js` (`clientSubscription`, `showHeaders`).
import { html } from '../../vendor/preact-htm.js';
import { Card, Tone } from '../ui.js';
import { useCommand, useBusy, Action, Context, Back, Loaded, rows } from './kit.js';
import { clientSubscription, showHeaders } from './shared.js';
import {
  SUBSCRIPTION_HOST, SUBSCRIPTION_LIST, SUBSCRIPTION_PUBLISH_ALL, PUBLISH_FIELDS, subscriptionSetHost,
  subscriptionMigrate, subscriptionHost, subscriptionRow, publishSummary,
} from './catalog-model.js';
import { summaryLines, pick } from './clients-model.js';

/** `subscription_list`: только просмотр, без действий. */
async function showList(ctx) {
  const reply = await ctx.request(SUBSCRIPTION_LIST);
  if (!reply.ok) { ctx.failed(); return; }
  const list = rows(reply.data).map(subscriptionRow);
  const body = list.length === 0
    ? html`<${Context} lines=${[{ text: 'Нет опубликованных подписок', tone: 'dim' }]} />`
    : html`<div class="context">${list.map((row, index) => html`
        <div key=${index}>${row.prefix}<${Tone} tone=${row.state.tone}>${row.state.label}<//></div>`)}</div>`;
  await ctx.show({ title: 'Список подписок', body });
}

export function SubscriptionsScreen({ ctx }) {
  const state = useCommand(ctx, SUBSCRIPTION_HOST);
  const [busy, run] = useBusy();
  const act = (action) => () => run(async () => {
    await action();
    await state.reload();
  });

  const setHost = act(async () => {
    const node = await pick(ctx, 'node', 'Хост-нода подписок');
    if (node === null) return;
    // Сбой уже сообщил `nodeRequest` (`nodes.rs::outcome`).
    await ctx.nodeRequest(node, subscriptionSetHost(node), null);
  });
  const list = act(() => showList(ctx));
  const publishAll = act(async () => {
    const reply = await ctx.runConfirmed('Обновление подписок', 'Опубликовать подписки?', SUBSCRIPTION_PUBLISH_ALL);
    if (ctx.isFailure(reply)) ctx.failed();
    const data = publishSummary(reply);
    if (data) {
      await ctx.show({
        title: 'Итог публикации подписок',
        body: html`<${Context} lines=${summaryLines(data, PUBLISH_FIELDS, 'Нечего публиковать.')} />`,
      });
    }
  });
  const migrate = act(async () => {
    const node = await pick(ctx, 'node', 'Перенос подписок на ноду');
    if (node === null) return;
    const reply = await ctx.runConfirmed('Перенос подписок', 'Перенести подписки?', subscriptionMigrate(node));
    if (ctx.isFailure(reply)) ctx.failed();
  });
  const client = act(async () => {
    const name = await pick(ctx, 'client', 'Подписка клиента');
    if (name !== null) await clientSubscription(ctx, name);
  });
  const groupHeaders = act(async () => {
    const name = await pick(ctx, 'group', 'Заголовки группы');
    if (name !== null) await showHeaders(ctx, 'group', name);
  });

  const back = html`<${Back} ctx=${ctx} to="summary" />`;
  const actions = html`
    <${Action} tone="change" disabled=${busy} onClick=${setHost}>Хост-нода подписок<//>
    <${Action} tone="view" disabled=${busy} onClick=${list}>Список подписок<//>
    <${Action} tone="change" disabled=${busy} onClick=${publishAll}>Обновить все подписки<//>
    <${Action} tone="change" disabled=${busy} onClick=${migrate}>Перенос на другую ноду<//>
    <${Action} tone="view" disabled=${busy} onClick=${client}>Подписка клиента<//>
    <${Action} tone="change" disabled=${busy} onClick=${groupHeaders}>Заголовки группы<//>
    ${back}`;
  return html`<${Loaded} title="Подписки" state=${state} actions=${back}>${(data) => {
    const host = subscriptionHost(data);
    const lines = host
      ? [{ text: html`Хост-нода: <${Tone} tone="ok">${host.node}<//>` }, host.baseUrl]
      : [{ text: 'Хост-нода подписок не задана', tone: 'dim' }];
    return html`<${Card} title="Подписки" actions=${actions}><${Context} lines=${lines} /><//>`;
  }}<//>`;
}
