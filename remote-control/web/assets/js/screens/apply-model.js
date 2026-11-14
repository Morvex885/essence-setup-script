// Применение желаемого состояния на нодах (`node apply`) без DOM — паритет с
// TUI: состояние ноды в списке, argv, отчёт `applied|failed|unchanged`
// (успех или `partial`; сбой ноды — `имя: сообщение ядра`), домены нод,
// упавших с `domain_required`, коды нод из `failed[]` (`handleNodeCodes`) и
// предложение применения после правок клиентов и подключений (сразу план ядра).
import { asList, strings } from '../format.js';
import { handleNodeCodes, setNodeDomain } from '../flows.js';

/** Состояние применения (`node list .status`) → `{ tone, label }`. */
export const APPLY_STATES = {
  pending: { tone: 'warn', label: 'ожидает применения' },
  applied: { tone: 'ok', label: 'применено' },
  running: { tone: 'info', label: 'применяется…' },
  none: { tone: 'neutral', label: 'без профиля' },
};

export function applyState(node) {
  return APPLY_STATES[node && node.status] || { tone: 'neutral', label: '—' };
}

const text = (value) => (value === null || value === undefined ? '' : String(value));

export const applyNamesArgv = (names) => ['node', 'apply', ...strings(names).flatMap((name) => ['--name', name])];
export const applyProfileArgv = (profile) => ['node', 'apply', '--profile', profile];
export const APPLY_PENDING_ARGV = ['node', 'apply', '--pending'];

/** Отчёт: `data` при успехе, поля `error` при `partial`, иначе `null`. */
export function applyReport(reply) {
  if (reply.ok) return reply.data || {};
  if (reply.error && reply.error.code === 'partial') return reply.error;
  return null;
}

/** Строки итога: применено, без изменений, по строке на сбойную ноду. */
export function applyLines(report) {
  const lines = [];
  const applied = strings(report.applied);
  const unchanged = strings(report.unchanged);
  if (applied.length) lines.push(`Применено: ${applied.join(', ')}`);
  if (unchanged.length) lines.push(`Без изменений: ${unchanged.join(', ')}`);
  for (const entry of failedEntries(report)) lines.push({ text: `${text(entry.name)}: ${text(entry.message)}`, tone: 'error' });
  return lines.length ? lines : ['Нет нод для применения.'];
}

/** Имена нод, ожидающих применения (`node list`). */
export function pendingNodes(list) {
  return asList(list).filter((node) => node && node.status === 'pending' && typeof node.name === 'string').map((node) => node.name);
}

/**
 * Команды, после успеха которых ноды могут ждать применения (паритет с TUI);
 * чтения `client nodes|connections --name C` (без флага изменения) — нет.
 */
export function offersApply(argv) {
  const [group, verb] = argv;
  if (group === 'client') {
    if (['add', 'delete', 'set-group'].includes(verb)) return true;
    return ['nodes', 'connections'].includes(verb) && argv.some((word) => ['--node', '--inherit', '--reset'].includes(word));
  }
  return group === 'conn' && verb === 'set';
}

export const NOTHING_PENDING = 'Нет нод, ожидающих применения.';

/** Сбои нод `failed[]` отчёта: `{ name, stage, code, message, port? }`. */
function failedEntries(report) {
  return asList(report.failed).filter((entry) => entry && typeof entry === 'object');
}

/**
 * `node apply` под планом с окном операции; `name` — нода при `--name`
 * (коды нод и `domain_required` разрешаются и команда повторяется).
 * Итог — отчёт в окне; для нод из `failed[]` с кодом `domain_required`
 * спрашивается домен (`node domain`), прочие коды нод решает
 * `handleNodeCodes`; после принятого решения команда повторяется один раз.
 * Возвращает ответ ядра.
 */
export async function applyFlow(ctx, argv, name = null) {
  for (let repeated = false; ; repeated = true) {
    const reply = await ctx.nodeRequest(name || '', argv, { title: 'Применение на нодах', question: 'Применить?' },
      { expect: ['partial', 'nothing_pending'], operation: 'Применение' });
    if (!reply.ok && reply.error && reply.error.code === 'nothing_pending') {
      ctx.notify('info', NOTHING_PENDING);
      return reply;
    }
    const report = applyReport(reply);
    if (report === null) return reply;
    await ctx.show({ title: 'Итог применения', context: applyLines(report) });
    if (repeated) return reply;
    let resolved = false;
    const failed = failedEntries(report);
    for (const entry of failed.filter((item) => item.code === 'domain_required')) {
      if (await setNodeDomain(text(entry.name), ctx)) resolved = true;
    }
    for (const entry of failed.filter((item) => item.code !== 'domain_required')) {
      if (await handleNodeCodes({ ok: false, error: entry }, text(entry.name), ctx)) resolved = true;
    }
    if (!resolved) return reply;
  }
}

/**
 * Предложение применить после изменения клиентов и подключений: есть
 * ноды `pending` → сразу `node apply --pending` с планом ядра (его
 * подтверждение — единственный вопрос). Сбой чтения — молча.
 */
export async function offerApply(ctx) {
  const listed = await ctx.request(['node', 'list'], { quiet: true });
  if (!listed.ok || pendingNodes(listed.data).length === 0) return;
  await applyFlow(ctx, APPLY_PENDING_ARGV);
}
