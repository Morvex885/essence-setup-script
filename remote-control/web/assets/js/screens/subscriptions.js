// Подписки (`tui/src/clients.rs::subscriptions`, `subscription_list`):
// `subscription host|list|publish-all|migrate`; заголовки группы — через
// `clients-model.js::showHeaders`, подписка клиента — вкладка карточки клиента.
import { html } from '../../vendor/preact-htm.js';
import { Page, Card, DataTable, MoreMenu, Facts, Badge, Empty, Button } from '../ui.js';
import { asList } from '../format.js';
import { useCommand, useBusy, Loaded } from './kit.js';
import {
  SUBSCRIPTION_HOST, SUBSCRIPTION_LIST, SUBSCRIPTION_PUBLISH_ALL, PUBLISH_FIELDS, subscriptionSetHost,
  subscriptionMigrate, subscriptionHost, subscriptionRow, publishSummary,
} from './catalog-model.js';
import { summaryLines, nodeLabel, fetchData, nameOptions, showHeaders } from './clients-model.js';

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
  // Список подписок не зависит от хоста (`subscription list` читает конфигурацию).
  const listState = useCommand(ctx, SUBSCRIPTION_LIST);
  const [busy, run] = useBusy();
  const act = (action) => () => run(async () => {
    await action();
    await Promise.all([hostState.reload(), listState.reload()]);
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
      await ctx.show({ title: 'Итог публикации подписок', context: summaryLines(data, PUBLISH_FIELDS, 'Нечего публиковать.') });
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
    // Действия — как в меню, и без хоста: сбой объясняет ядро.
    const actions = html`
      <${Button} kind=${host ? 'primary' : 'neutral'} icon="refresh-cw" disabled=${busy} onClick=${publishAll}>Обновить все подписки<//>
      <${Button} kind=${host ? 'neutral' : 'primary'} icon="server" disabled=${busy} onClick=${setHost}>Хост-нода…<//>
      <${Button} icon="folders" disabled=${busy} onClick=${groupHeaders}>Заголовки группы<//>
      <${MoreMenu} items=${[{ label: 'Перенос на другую ноду', icon: 'send', disabled: busy, onClick: migrate }]} />`;
    return html`<${Page} title="Подписки" actions=${actions}>
      <${Card}>
        ${host
          ? html`<${Facts} items=${[
              { label: 'Хост-нода', value: html`<a class="link" href=${ctx.href('nodes', host.node)}>${host.node}</a>` },
              { label: 'Базовый URL', value: html`<span class="mono">${host.baseUrl}</span>` },
            ]} />`
          : html`<${Empty} icon="rss" title="Хост-нода подписок не задана" hint="Подписки публикуются на хост-ноде: выберите её кнопкой «Хост-нода…»." />`}
      <//>
      <${Loaded} title="Опубликованные подписки" state=${listState} inline>
        ${(data) => html`<${Card} title="Опубликованные подписки">
          <${DataTable} rows=${asList(data).map(subscriptionRow)} rowKey="client" empty="Нет опубликованных подписок"
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
