// Telegram Proxy: `#/telegram` (`nodes.rs::Telegram`, `telegram_batch`,
// `telegram_table`). Общий статус опрашивает все ноды по SSH, поэтому
// читается по кнопке. Потоки (выбор нод, план, результаты) —
// `nodeops-model.js`; здесь — разметка и привязка к кнопкам.
import { html, useState } from '../../vendor/preact-htm.js';
import { Page, Card, DataTable, Badge, Empty, MoreMenu, Button } from '../ui.js';
import { useBusy, useMounted } from './kit.js';
import {
  TELEGRAM_TITLE, TELEGRAM_RESULT_TITLE, TELEGRAM_BATCH, telegramMenu, telegramBatch, telegramStatus,
} from './nodeops-model.js';

const COLUMNS = [
  { key: 'node', label: 'Нода', search: true },
  { key: 'status', label: 'Статус', render: (row) => html`<${Badge} tone=${row.tone}>${row.status}<//>` },
  { key: 'reason', label: 'Причина' },
];

function ResultTable({ table }) {
  return html`<${DataTable} columns=${COLUMNS} rows=${table} rowKey="node" empty="Нет нод" />`;
}

export function TelegramScreen({ ctx }) {
  const [busy, run] = useBusy();
  const [table, setTable] = useState(null);
  const mounted = useMounted();

  /** Сбой без таблицы — итог сбоя, прежняя таблица остаётся. */
  const readStatus = async () => {
    const rows = await telegramStatus(ctx);
    if (rows !== null && mounted.current) setTable(rows);
  };
  const load = () => run(readStatus);
  const present = (rows) => ctx.show({ title: TELEGRAM_RESULT_TITLE, wide: true, body: html`<${ResultTable} table=${rows} />` });
  // После пакетного действия и сеанса меню загруженный статус перечитывается:
  // прежний устарел (сеанс меню — и при его сбое).
  const runBatch = (action) => run(async () => {
    if ((await telegramBatch(ctx, action, present)) && table !== null) await readStatus();
  });
  const openMenu = () => run(() => telegramMenu(ctx, () => (table !== null ? readStatus() : null)));

  const actions = html`
    <${Button} icon="terminal" disabled=${busy} onClick=${openMenu}>Управление нодой…<//>
    <${MoreMenu} label="Действия" items=${TELEGRAM_BATCH.map((action) => ({
      label: action.label,
      danger: action.danger === true,
      disabled: busy,
      onClick: () => runBatch(action),
    }))} />
  `;
  return html`<${Page} title=${TELEGRAM_TITLE} actions=${actions}>
    ${table === null
      ? html`<${Card}>
          <${Empty} icon="send" title="Статус не загружен" hint="Статус опрашивает все ноды по SSH."
            action=${html`<${Button} kind="primary" icon="refresh-cw" disabled=${busy} onClick=${load}>Загрузить статус<//>`} />
        <//>`
      : html`<${Card} title="Статус нод"
          actions=${html`<${Button} icon="refresh-cw" disabled=${busy} onClick=${load}>Обновить<//>`}>
          <${ResultTable} table=${table} />
        <//>`}
  <//>`;
}
