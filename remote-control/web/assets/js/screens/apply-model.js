// Применение желаемого состояния на нодах (`node apply`) без DOM — паритет с
// TUI: состояние ноды в списке, argv, отчёт `applied|failed|unchanged`
// (успех или `partial`), подписи этапов и причин сбоя и предложение
// «Применить изменения на N нодах?» после правок клиентов и подключений.
import { asList, strings } from '../format.js';

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

/** Подписи этапов исполнителя (`node-agent/apply.sh`), как в журнале ядра. */
export const STAGE_LABELS = {
  packages: 'установка пакетов',
  system: 'системные настройки',
  mihomo: 'установка mihomo',
  dns: 'проверка DNS',
  site: 'сайт-заглушка',
  certificate: 'сертификаты',
  prepare: 'подготовка компонентов',
  config: 'конфигурация и проверка',
  firewall: 'правила UFW',
  cleanup: 'очистка',
};

/** Подписи причин сбоя ноды, не связанных с этапом. */
export const REASON_LABELS = {
  unsupported_os: 'не Debian/Ubuntu с systemd',
  timeout: 'нет ответа',
  start: 'не удалось запустить',
  missing_secret: 'нет ключа ноды',
  warp: 'не удалось зарегистрировать WARP',
};

const text = (value) => (value === null || value === undefined ? '' : String(value));

/** Подпись сбоя ноды из `failed[]`: `{ name, stage, reason, port? }`. */
export function failureLabel(entry) {
  const reason = text(entry && entry.reason);
  const stage = text(entry && entry.stage);
  if (reason === 'port_busy') return entry.port !== undefined && entry.port !== null ? `порт ${text(entry.port)} занят` : 'порт занят';
  if (REASON_LABELS[reason]) return REASON_LABELS[reason];
  if (REASON_LABELS[stage]) return REASON_LABELS[stage];
  const label = STAGE_LABELS[stage];
  if (label) return reason === 'rolled_back' ? `откат на этапе «${label}»` : `ошибка на этапе «${label}»`;
  return reason || stage || 'ошибка';
}

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
  for (const entry of asList(report.failed)) {
    if (entry && typeof entry === 'object') lines.push({ text: `${text(entry.name)}: ${failureLabel(entry)}`, tone: 'error' });
  }
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

/**
 * `node apply` под планом с окном операции; `name` — нода при `--name`
 * (коды нод и `domain_required` разрешаются и команда повторяется).
 * Итог — отчёт в окне. Возвращает ответ ядра.
 */
export async function applyFlow(ctx, argv, name = null) {
  const reply = await ctx.nodeRequest(name || '', argv, { title: 'Применение на нодах', question: 'Применить?' },
    { expect: ['partial', 'nothing_pending'], operation: 'Применение' });
  if (!reply.ok && reply.error && reply.error.code === 'nothing_pending') {
    ctx.notify('info', NOTHING_PENDING);
    return reply;
  }
  const report = applyReport(reply);
  if (report !== null) await ctx.show({ title: 'Итог применения', context: applyLines(report) });
  return reply;
}

/**
 * Предложение применить после изменения клиентов и подключений: есть
 * ноды `pending` → вопрос → `node apply --pending`. Сбой чтения — молча.
 */
export async function offerApply(ctx) {
  const listed = await ctx.request(['node', 'list'], { quiet: true });
  if (!listed.ok) return;
  const count = pendingNodes(listed.data).length;
  if (count === 0) return;
  const yes = await ctx.confirm({ title: 'Применение на нодах', plan: [], question: `Применить изменения на ${count} нодах?` });
  if (yes) await applyFlow(ctx, APPLY_PENDING_ARGV);
}
