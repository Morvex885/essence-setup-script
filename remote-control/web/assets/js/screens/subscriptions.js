// Подписки (`tui/src/clients.rs::subscriptions`, `subscription_list`):
// `subscription host|list|publish-all|migrate`; заголовки группы — через
// `shared.js::showHeaders`, подписка клиента — вкладка карточки клиента.
import { html } from '../../vendor/preact-htm.js';
import { Page, Card, DataTable, MoreMenu, Facts, Badge, Empty } from '../ui.js';
import { useCommand, useBusy, Action, Context, Loaded, rows } from './kit.js';
import { fetchData, nameOptions, showHeaders } from './shared.js';
import {
  SUBSCRIPTION_HOST, SUBSCRIPTION_LIST, SUBSCRIPTION_PUBLISH_ALL, PUBLISH_FIELDS, subscriptionSetHost,
  subscriptionMigrate, subscriptionHost, subscriptionRow, publishSummary,
} from './catalog-model.js';
import { summaryLines, nodeLabel } from './clients-model.js';

const BADGE_TONES = { ok: 'ok', warn: 'warn', dim: 'neutral' };

/** Выбор ноды одной формой: `null` — сбой чтения (сообщён) или отмена. */
async function chooseNode(ctx, title, submit, current = null) {
  const read = await fetchData(ctx, ['node', 'list']);
  if (!read) return null;
  const values = await ctx.form({
    title, submit,
    fields: [{ name: 'node', label: 'Нода', type: 'select', value: current, options: nameOptions(read.data, nodeLabel), required: true }],
  });
  return values ? values.node : null;
}

export function SubscriptionsScreen({ ctx }) {
  const hostState = useCommand(ctx, SUBSCRIPTION_HOST);
  const host = hostState.data ? subscriptionHost(hostState.data) : null;
  const listState = useCommand(ctx, host ? SUBSCRIPTION_LIST : null, [host ? host.node : null]);
  const [busy, run] = useBusy();
  const act = (action) => () => run(async () => {
    await action();
    await Promise.all([hostState.reload(), host ? listState.reload() : null]);
  });

  const setHost = act(async () => {
    const node = await chooseNode(ctx, 'Хост-нода подписок', 'Выбрать', host ? host.node : null);
    // Сбой уже сообщил `nodeRequest` (`nodes.rs::outcome`).
    if (node !== null) await ctx.nodeRequest(node, subscriptionSetHost(node), null);
  });
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
    const node = await chooseNode(ctx, 'Перенос подписок на ноду', 'Далее');
    if (node === null) return;
    const reply = await ctx.runConfirmed('Перенос подписок', 'Перенести подписки?', subscriptionMigrate(node));
    if (ctx.isFailure(reply)) ctx.failed();
  });
  const groupHeaders = act(async () => {
    const read = await fetchData(ctx, ['group', 'list']);
    if (!read) return;
    const values = await ctx.form({
      title: 'Заголовки группы', submit: 'Открыть',
      fields: [{ name: 'group', label: 'Группа', type: 'select', options: nameOptions(read.data), required: true }],
    });
    if (values) await showHeaders(ctx, 'group', values.group);
  });

  return html`<${Loaded} title="Подписки" state=${hostState}>${() => {
    if (!host) {
      return html`<${Page} title="Подписки"><${Card}>
        <${Empty} icon="rss" title="Хост-нода подписок не задана"
          action=${html`<${Action} primary icon="server" disabled=${busy} onClick=${setHost}>Выбрать хост-ноду<//>`} />
      <//><//>`;
    }
    const actions = html`
      <${Action} primary icon="refresh-cw" disabled=${busy} onClick=${publishAll}>Обновить все подписки<//>
      <${Action} icon="server" disabled=${busy} onClick=${setHost}>Хост-нода…<//>
      <${Action} icon="folders" disabled=${busy} onClick=${groupHeaders}>Заголовки группы<//>
      <${MoreMenu} items=${[{ label: 'Перенос на другую ноду', icon: 'send', disabled: busy, onClick: migrate }]} />`;
    return html`<${Page} title="Подписки" actions=${actions}>
      <${Card}>
        <${Facts} items=${[
          { label: 'Хост-нода', value: html`<a class="link" href=${ctx.href('nodes', host.node)}>${host.node}</a>` },
          { label: 'Базовый URL', value: html`<span class="mono">${host.baseUrl}</span>` },
        ]} />
      <//>
      <${Loaded} title="Опубликованные подписки" state=${listState} inline>
        ${(data) => html`<${Card} title="Опубликованные подписки">
          <${DataTable} rows=${rows(data).map(subscriptionRow)} rowKey="client" empty="Нет опубликованных подписок"
            href=${(row) => ctx.href('clients', row.client, 'subscription')}
            columns=${[
              { key: 'client', label: 'Клиент', search: true },
              { key: 'expires', label: 'Срок' },
              { key: 'state', label: 'Состояние', render: (row) => html`<${Badge} tone=${BADGE_TONES[row.state.tone] || 'neutral'}>${row.state.label}<//>` },
            ]} />
        <//>`}
      <//>
    <//>`;
  }}<//>`;
}
