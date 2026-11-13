// Подписки (`tui/src/clients.rs::subscriptions`, `subscription_list`):
// `subscription host|list|publish-all|migrate`; потоки — `clients-model.js`,
// подписка клиента — вкладка карточки клиента.
import { html } from '../../vendor/preact-htm.js';
import { Page, Card, DataTable, MoreMenu, Facts, Badge, Empty, Button } from '../ui.js';
import { asList } from '../format.js';
import { useCommand, useBusy, Loaded } from './kit.js';
import { SUBSCRIPTION_HOST, SUBSCRIPTION_LIST, subscriptionHost, subscriptionRow } from './catalog-model.js';
import { subscriptionHostFlow, publishAllFlow, migrateFlow, groupHeadersFlow } from './clients-model.js';

const BADGE_TONES = { ok: 'ok', warn: 'warn', dim: 'neutral' };

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

  const setHost = act(() => subscriptionHostFlow(ctx, host ? host.node : null));
  const publishAll = act(() => publishAllFlow(ctx));
  const migrate = act(() => migrateFlow(ctx));
  const groupHeaders = act(() => groupHeadersFlow(ctx));

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
