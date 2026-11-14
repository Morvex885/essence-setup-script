// Telegram Proxy: `#/telegram` — роль Telegram Web Proxy нод. Список — ноды
// `node list` с ролью (без SSH); статус опрашивает ноды по SSH, поэтому
// читается по кнопке. Потоки (включение, домен, секрет, тег, удаление,
// перезапуск, диагностика) — `nodeops-model.js`, окно ссылки — `share.js`;
// здесь — разметка и привязка к кнопкам.
import { html, useState } from '../../vendor/preact-htm.js';
import { Page, Card, DataTable, Badge, Empty, Button } from '../ui.js';
import { useBusy, useCommand, useMounted, Loaded } from './kit.js';
import { showTelegramLink } from './share.js';
import * as model from './nodeops-model.js';

const STATUS_COLUMNS = [
  { key: 'node', label: 'Нода', search: true },
  { key: 'hostname', label: 'Домен' },
  { key: 'status', label: 'Статус', render: (row) => html`<${Badge} tone=${row.tone}>${row.status}<//>` },
  { key: 'summary', label: 'Сводка', render: (row) => html`<div class="vstack">
    ${row.reason && html`<div class="t-dim">${row.reason}</div>`}
    ${row.summary.map((line, index) => html`<div key=${index}>${line}</div>`)}
  </div>` },
];

export function TelegramScreen({ ctx }) {
  const list = useCommand(ctx, ['node', 'list']);
  const [busy, run] = useBusy();
  const [table, setTable] = useState(null);
  const mounted = useMounted();

  /** Сбой без таблицы — итог сбоя, прежняя таблица остаётся. */
  const readStatus = async () => {
    const rows = await model.telegramStatus(ctx);
    if (rows !== null && mounted.current) setTable(rows);
  };
  /** Действие и перечитывание списка (правки меняют роль и состояние применения). */
  const act = (action) => run(async () => { await action(); await list.reload(); });
  const enable = () => act(() => model.enableTelegram(ctx, list.data));

  const enableButton = (kind = 'primary') => html`<${Button} kind=${kind} icon="plus"
    disabled=${busy || !list.data} onClick=${enable}>Включить на ноде<//>`;

  return html`<${Loaded} title=${model.TELEGRAM_TITLE} state=${list} actions=${enableButton()}>
    ${(data) => {
      const rows = model.telegramRows(data);
      const nodeLink = (name) => html`<a class="link" href=${ctx.href('nodes', name)}>${name}</a>`;
      const menu = (row) => [
        { label: 'Ссылка', icon: 'external-link', disabled: busy, onClick: () => run(() => showTelegramLink(ctx, row.name)) },
        { label: 'Сменить домен', icon: 'pencil', disabled: busy, onClick: () => act(() => model.telegramDomainFlow(ctx, row.name, row.hostname)) },
        { label: 'Сменить секрет', icon: 'key-round', disabled: busy, onClick: () => act(() => model.rotateTelegramSecret(ctx, row.name)) },
        { label: 'Спонсорский тег', icon: 'key-round', disabled: busy, onClick: () => act(() => model.telegramTagFlow(ctx, row.name)) },
        ...(row.tag ? [{ label: 'Убрать тег', icon: 'x', disabled: busy, onClick: () => act(() => model.clearTelegramTag(ctx, row.name)) }] : []),
        { label: 'Перезапустить', icon: 'refresh-cw', disabled: busy, onClick: () => run(() => model.restartTelegram(ctx, row.name)) },
        { label: 'Диагностика', icon: 'scroll-text', disabled: busy, onClick: () => run(() => model.telegramDiagnostics(ctx, row.name)) },
        { label: 'Убрать', icon: 'trash-2', danger: true, disabled: busy, onClick: () => act(() => model.removeTelegram(ctx, row.name)) },
      ];
      const actions = html`
        <${Button} icon="refresh-cw" disabled=${busy || rows.length === 0} onClick=${() => run(readStatus)}>Проверить статус<//>
        ${enableButton()}
      `;
      return html`<${Page} title=${model.TELEGRAM_TITLE} actions=${actions}>
        <${Card}>
          ${rows.length === 0
            ? html`<${Empty} icon="send" title="Telegram Proxy не включён"
                hint="Telegram Web Proxy включается на ноде с профилем и разворачивается командой «Применить»."
                action=${enableButton()} />`
            : html`<${DataTable} rows=${rows} empty="Нет нод" menu=${menu}
                columns=${[
                  { key: 'name', label: 'Нода', search: true, render: (row) => nodeLink(row.name) },
                  { key: 'hostname', label: 'Домен', search: true },
                  { key: 'tag', label: 'Тег', render: (row) => (row.tag
                    ? html`<${Badge} tone="ok">задан<//>` : html`<${Badge} tone="neutral">нет<//>`) },
                  { key: 'state', label: 'Состояние', render: (row) => html`<${Badge} tone=${row.state.tone}>${row.state.label}<//>` },
                ]} />`}
        <//>
        ${table !== null && rows.length > 0 && html`<${Card} title=${model.TELEGRAM_RESULT_TITLE}
          actions=${html`<${Button} icon="refresh-cw" disabled=${busy} onClick=${() => run(readStatus)}>Обновить<//>`}>
          <${DataTable} columns=${STATUS_COLUMNS} rows=${table} rowKey="node" empty="Нет нод" />
        <//>`}
      <//>`;
    }}
  <//>`;
}
