// Подписки (`tui/src/clients.rs::subscriptions`, `subscription_list`):
// `subscription host [--name N --domain D [--port P] | --remove]|list|publish-all`;
// потоки — `clients-model.js`, подписка клиента — вкладка карточки клиента.
import { html } from '../../vendor/preact-htm.js';
import { Page, Card, DataTable, MoreMenu, Facts, Badge, Empty, Button } from '../ui.js';
import { asList } from '../format.js';
import { useCommand, useBusy, Loaded } from './kit.js';
import { SUBSCRIPTION_HOST, SUBSCRIPTION_LIST, subscriptionHost, subscriptionRow } from './catalog-model.js';
import { subscriptionHostFlow, removeHostFlow, publishAllFlow, groupHeadersFlow } from './clients-model.js';

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

  const setHost = act(() => subscriptionHostFlow(ctx, host));
  const removeHost = act(() => removeHostFlow(ctx, host));
  const publishAll = act(() => publishAllFlow(ctx));
  const groupHeaders = act(() => groupHeadersFlow(ctx));

  // Действия — как в меню, и без хоста: сбой объясняет ядро. Сбой чтения
  // хоста ограничен его карточкой: список и действия остаются.
  const actions = html`
    <${Button} kind=${host ? 'primary' : 'neutral'} icon="refresh-cw" disabled=${busy} onClick=${publishAll}>Обновить все подписки<//>
    <${Button} kind=${host ? 'neutral' : 'primary'} icon="server" disabled=${busy} onClick=${setHost}>Хост подписок…<//>
    <${Button} icon="folders" disabled=${busy} onClick=${groupHeaders}>Заголовки группы<//>
    ${host && html`<${MoreMenu} items=${[{ label: 'Убрать хост', icon: 'trash-2', danger: true, disabled: busy, onClick: removeHost }]} />`}`;
  return html`<${Page} title="Подписки" actions=${actions}>
    <${Loaded} title="Хост подписок" state=${hostState} inline>
      ${() => html`<${Card}>
        ${host
          ? html`<${Facts} items=${[
              { label: 'Нода', value: html`<a class="link" href=${ctx.href('nodes', host.node)}>${host.node}</a>` },
              { label: 'Домен', value: html`<span class="mono">${host.hostname}</span>` },
              { label: 'Порт', value: host.port },
              { label: 'Базовый URL', value: html`<span class="mono">${host.baseUrl}</span>` },
            ]} />`
          : html`<${Empty} icon="rss" title="Хост подписок не задан" hint="Подписки публикуются на ноде с профилем: задайте её и домен кнопкой «Хост подписок…», затем примените ноду." />`}
      <//>`}
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
}
