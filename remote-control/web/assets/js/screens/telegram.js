// Telegram Proxy: `#/telegram` (`nodes.rs::Telegram`, `telegram_batch`,
// `telegram_table`). Пакетные действия: выбор нод без отметок → по одному
// `--name` на ноду → замороженный план ядра → таблица результатов.
// «Управление одной нодой» — `telegram menu` в терминальном оверлее.
import { html } from '../../vendor/preact-htm.js';
import { Card, Table, Tone } from '../ui.js';
import { interactive, nodeLabel } from './nodes.js';
import { useBusy, Action, Actions, Back } from './kit.js';
import {
  EMPTY, NOTHING_SELECTED, rows, nodeText, telegramArgv, telegramResults,
  TELEGRAM_TITLE, TELEGRAM_RESULT_TITLE, TELEGRAM_SELECT_TITLE, TELEGRAM_STATUS_ARGV,
  TELEGRAM_COMPONENT_TITLE, TELEGRAM_COMPONENTS, TELEGRAM_VIEW, TELEGRAM_BATCH,
} from './nodeops-model.js';

const COLUMNS = [
  { key: 'node', label: 'Нода' },
  { key: 'status', label: 'Статус', render: (row) => html`<${Tone} tone=${row.tone}>${row.status}<//>` },
  { key: 'reason', label: 'Причина' },
];

/** Таблица «нода  статус  причина»; `false` — в ответе нет `results`. */
async function telegramTable(ctx, reply) {
  const table = telegramResults(reply);
  if (table === null) return false;
  await ctx.show({ title: TELEGRAM_RESULT_TITLE, wide: true, body: html`<${Table} columns=${COLUMNS} rows=${table} />` });
  return true;
}

/** Список нод (`node list`); отказ — сообщение о сбое и `null`. */
async function listNodes(ctx) {
  const listed = await ctx.call('node', 'list');
  if (!listed.ok) {
    if (ctx.isFailure(listed)) ctx.failed();
    return null;
  }
  return rows(listed.data).map((row) => ({ value: nodeText(row.name), label: nodeLabel(row) }));
}

async function telegramBatch(ctx, title, base, component = null) {
  const nodes = await listNodes(ctx);
  if (nodes === null) return;
  const selected = await ctx.toggle({ title, options: nodes, selected: [], empty: EMPTY, submit: 'Далее' });
  if (selected === null) return;
  if (selected.length === 0) {
    ctx.notify('warn', NOTHING_SELECTED);
    return;
  }
  const reply = await ctx.runConfirmed(title, 'Выполнить?', telegramArgv(base, selected, component));
  if (!(await telegramTable(ctx, reply)) && ctx.isFailure(reply)) ctx.failed();
}

async function singleNode(ctx) {
  const nodes = await listNodes(ctx);
  if (nodes === null) return;
  const name = await ctx.choose({ title: TELEGRAM_SELECT_TITLE, options: nodes.map((node) => ({ ...node, tone: 'view' })), empty: EMPTY });
  if (name !== null) await interactive(ctx, name, true);
}

async function status(ctx) {
  const reply = await ctx.call(...TELEGRAM_STATUS_ARGV);
  if (!(await telegramTable(ctx, reply)) && ctx.isFailure(reply)) ctx.failed();
}

async function batch(ctx, action) {
  if (!action.component) {
    await telegramBatch(ctx, action.title, action.argv);
    return;
  }
  const component = await ctx.choose({ title: TELEGRAM_COMPONENT_TITLE, options: TELEGRAM_COMPONENTS.map((item) => ({ ...item, tone: 'view' })) });
  if (component !== null) await telegramBatch(ctx, action.title, action.argv, component);
}

export function TelegramScreen({ ctx }) {
  const [busy, run] = useBusy();
  const view = { node: () => singleNode(ctx), status: () => status(ctx) };
  return html`<${Card} title=${TELEGRAM_TITLE}>
    <${Actions} column>
      ${TELEGRAM_VIEW.map((action) => html`<${Action} key=${action.id} tone=${action.tone} disabled=${busy}
        onClick=${() => run(view[action.id])}>${action.label}<//>`)}
    <//>
    <${Actions} column>
      ${TELEGRAM_BATCH.map((action) => html`<${Action} key=${action.id} tone=${action.tone} disabled=${busy}
        onClick=${() => run(() => batch(ctx, action))}>${action.label}<//>`)}
      <${Back} ctx=${ctx} to="summary" />
    <//>
  <//>`;
}
