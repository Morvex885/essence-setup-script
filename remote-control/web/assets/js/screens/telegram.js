// Telegram Proxy: `#/telegram` (`nodes.rs::Telegram`, `telegram_batch`,
// `telegram_table`). Общий статус опрашивает все ноды по SSH, поэтому
// читается по кнопке. Пакетные действия: форма выбора нод (и способа
// доступа) → по одному `--name` на ноду → замороженный план ядра → таблица
// результатов. «Управление нодой» — `telegram menu` в терминальном оверлее.
import { html, useState } from '../../vendor/preact-htm.js';
import { Page, Card, DataTable, Badge, Empty, MoreMenu, Button } from '../ui.js';
import { interactive, nodeLabel } from './nodes.js';
import { useBusy, useMounted } from './kit.js';
import {
  EMPTY, rows, nodeText, telegramArgv, telegramResults,
  TELEGRAM_TITLE, TELEGRAM_RESULT_TITLE, TELEGRAM_SELECT_TITLE, TELEGRAM_STATUS_ARGV, TELEGRAM_COMPONENTS, TELEGRAM_BATCH,
} from './nodeops-model.js';

const COLUMNS = [
  { key: 'node', label: 'Нода', search: true },
  { key: 'status', label: 'Статус', render: (row) => html`<${Badge} tone=${row.tone}>${row.status}<//>` },
  { key: 'reason', label: 'Причина' },
];

function ResultTable({ table }) {
  return html`<${DataTable} columns=${COLUMNS} rows=${table} rowKey="node" empty="Нет нод" />`;
}

/** Список нод (`node list`) как варианты выбора; отказ — сообщение о сбое и `null`. */
async function listNodes(ctx) {
  const listed = await ctx.call('node', 'list');
  if (!listed.ok) {
    if (ctx.isFailure(listed)) ctx.failed();
    return null;
  }
  const nodes = rows(listed.data).map((row) => ({ value: nodeText(row.name), label: nodeLabel(row) }));
  if (nodes.length === 0) {
    ctx.notify('warn', EMPTY);
    return null;
  }
  return nodes;
}

/** «Управление нодой…»: выбор ноды → `telegram menu` в терминале. */
async function singleNode(ctx) {
  const nodes = await listNodes(ctx);
  if (nodes === null) return;
  const values = await ctx.form({
    title: TELEGRAM_SELECT_TITLE,
    fields: [{ name: 'node', label: 'Нода', type: 'select', options: nodes }],
    submit: 'Открыть',
  });
  if (values !== null) await interactive(ctx, values.node, true);
}

/** Пакетное действие (`telegram_batch`): ноды и способ доступа одной формой; `true` — команда отправлена. */
async function batch(ctx, action) {
  const nodes = await listNodes(ctx);
  if (nodes === null) return false;
  const fields = [{ name: 'nodes', label: 'Ноды', type: 'multi', options: nodes, required: true }];
  if (action.component) {
    fields.push({ name: 'component', label: 'Способ доступа', type: 'radio', options: TELEGRAM_COMPONENTS, required: true });
  }
  const values = await ctx.form({ title: action.title, fields, submit: 'Далее', tone: action.danger ? 'danger' : 'primary' });
  if (values === null) return false;
  const argv = telegramArgv(action.argv, values.nodes, action.component ? values.component : null);
  const reply = await ctx.runConfirmed(action.title, 'Выполнить?', argv);
  const table = telegramResults(reply);
  if (table !== null) {
    await ctx.show({ title: TELEGRAM_RESULT_TITLE, wide: true, body: html`<${ResultTable} table=${table} />` });
  } else if (ctx.isFailure(reply)) {
    ctx.failed();
  }
  // Отказ от плана ничего не менял.
  return reply.ok || ctx.isFailure(reply);
}

export function TelegramScreen({ ctx }) {
  const [busy, run] = useBusy();
  const [table, setTable] = useState(null);
  const mounted = useMounted();

  /** `telegram status --all`; сбой без таблицы — итог сбоя, прежняя таблица остаётся. */
  const readStatus = async () => {
    const reply = await ctx.call(...TELEGRAM_STATUS_ARGV);
    const result = telegramResults(reply);
    if (result === null && !reply.ok) {
      if (ctx.isFailure(reply)) ctx.failed();
      return;
    }
    if (mounted.current) setTable(result || []);
  };
  const load = () => run(readStatus);
  // После пакетного действия загруженный статус перечитывается: прежний устарел.
  const runBatch = (action) => run(async () => {
    if ((await batch(ctx, action)) && table !== null) await readStatus();
  });

  const actions = html`
    <${Button} icon="terminal" disabled=${busy} onClick=${() => run(() => singleNode(ctx))}>Управление нодой…<//>
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
