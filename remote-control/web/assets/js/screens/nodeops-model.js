// Модель обзора подключений нод, вкладок ноды «Подключения», «AmneziaWG» и
// экрана «Telegram Proxy» — перенос чистой логики `tui/src/nodes.rs`
// (`Connections::run`, `synced_node`, `sync_problem`, `assign_connections`,
// `awg_node`, argv команд, таблица `telegram_table`) и потоки Telegram
// (`telegram_batch`) поверх `ctx`. Без DOM и вендоренных файлов: окно
// результатов экран передаёт функцией. Тоны: `ok` (GREEN), `warn` (YELLOW),
// `error` (RED), `neutral` (DIM).
import { asList, proxyLabel, unlisted } from '../format.js';
import { refill } from '../form-model.js';
import { NODE_CODES, retryable } from '../flows.js';
import { interactive, nodeLabel } from './nodes-model.js';

/** Пустой выбор (`nodes.rs::EMPTY`). */
export const EMPTY = 'Нет объектов для выбора';

/** Значение как в `nodes.rs::text`: строка, `null` → пусто, прочее — JSON. */
export function nodeText(value) {
  if (typeof value === 'string') return value;
  if (value === null || value === undefined) return '';
  return JSON.stringify(value);
}

/** Строка ноды в ответе `conn sync` (`synced_node`). */
export function syncedNode(sync, name) {
  return asList(sync && sync.nodes).find((row) => row && row.name === name) || null;
}

/** Состояния строки `conn sync`, кроме `synced` (`sync_problem`). */
export function syncProblem(status) {
  switch (status) {
    case 'unreachable': return 'недоступна';
    case 'load_failed': return 'не загружена';
    case 'save_failed': return 'не сохранена';
    case 'skipped': return 'пропущена';
    default: return null;
  }
}

/** Данные синхронизации из ответа `conn sync`: `data`, при `partial` — `error`; иначе `null`. */
export function syncData(reply) {
  if (reply.ok) return reply.data;
  if (reply.error && reply.error.code === 'partial') return reply.error;
  return null;
}

/**
 * Обзор подключений всех нод (`Connections::run`): ноды `conn list` с
 * состоянием последней синхронизации. Группа: `назначено/всего`, тон — все
 * назначены (`ok`), часть (`warn`), всего неизвестно или 0 (`neutral`).
 */
export function overviewNodes(list, synced) {
  return asList(list).map((entry) => {
    const name = nodeText(entry.node);
    const state = syncedNode(synced, name);
    const problem = state ? syncProblem(state.status) : null;
    if (problem) return { name, problem, groups: [] };
    const total = state && Array.isArray(state.discovered) ? state.discovered.length : null;
    const groups = asList(entry.groups).map((group) => {
      const assigned = asList(group.proxies).length;
      const tone = total !== null && total > 0 ? (assigned >= total ? 'ok' : 'warn') : 'neutral';
      return { name: nodeText(group.name), count: `${assigned}/${total === null ? '?' : total}`, tone };
    });
    return { name, problem: null, groups };
  });
}

/**
 * «Синхронизировать все» (`Connections::run`, клавиша `s`): `conn sync` по
 * всем нодам, затем `conn list`. Итог — строки обзора или `null` (сбой уже
 * показан: текст ядра — `ctx.request`, итог — `ctx.failed`).
 */
export async function syncAll(ctx) {
  const reply = await ctx.call(...connSyncArgv());
  const synced = syncData(reply);
  if (synced === null) {
    if (ctx.isFailure(reply)) ctx.failed();
    return null;
  }
  const listed = await ctx.call(...connListArgv());
  if (!listed.ok) {
    ctx.failed();
    return null;
  }
  return overviewNodes(listed.data, synced);
}

/**
 * Подключения ноды (`connection_node`): обнаруженные подключения и
 * назначенные группам, но не найденные (в конце: клиенты AmneziaWG
 * `awg-<клиент>` и устаревшие `stale` — их можно снять и при недоступной
 * ноде; при изменении группы они сохраняются, если отмечены), группы каждого (`assigned[i]`),
 * строки таблицы и проблема синхронизации ноды. `checked` — нода прочитана
 * (`discovered` есть); без этого «не найдено на ноде» не отмечается.
 */
export function connectionView(listed, state, name) {
  const entry = asList(listed).find((row) => row && row.node === name);
  const groups = entry ? asList(entry.groups) : [];
  const checked = Boolean(state) && Array.isArray(state.discovered);
  const discovered = checked ? state.discovered.map(nodeText) : null;
  const { extra, stale } = unlisted(groups.flatMap((group) => asList(group.proxies).map(nodeText)), discovered);
  const proxies = [...(discovered || []), ...extra];
  const assigned = proxies.map((proxy) => [...new Set(groups
    .filter((group) => asList(group.proxies).includes(proxy))
    .map((group) => nodeText(group.name)))]);
  const problem = syncProblem(state && state.status);
  const table = proxies.map((proxy, index) => ({ proxy, groups: assigned[index], stale: stale.includes(proxy) }));
  return { proxies, assigned, stale, problem, checked, table };
}

/**
 * `conn set --name N --assign G=P1 --assign G=P2 …` (по флагу на подключение —
 * имя с запятой остаётся целым): полный набор подключений каждой
 * перечисленной группы на ноде (`G=` снимает назначение); какие группы
 * изменились, решает ядро. `assignments` — `[[группа, [подключения]]]`.
 */
export function assignArgv(name, assignments) {
  const argv = ['conn', 'set', '--name', name];
  for (const [group, proxies] of assignments) {
    if (proxies.length === 0) argv.push('--assign', `${group}=`);
    for (const proxy of proxies) argv.push('--assign', `${group}=${proxy}`);
  }
  return argv;
}

const proxyField = (index) => `proxy-${index}`;

/**
 * Изменённые группы формы «по подключению»: `assigned[i]` — группы
 * `proxies[i]` при открытии формы, `values[proxy-i]` — отмеченные.
 * Возвращает `[[группа, [подключения]]]` только для групп, чей набор
 * (среди найденных подключений) изменился, — назначения, сделанные другим
 * клиентом в других группах, форма не перезаписывает.
 */
export function assignmentChanges(proxies, assigned, values) {
  const order = [];
  const sets = (pick) => {
    const map = new Map();
    proxies.forEach((proxy, index) => {
      for (const group of asList(pick(index))) {
        if (!order.includes(group)) order.push(group);
        if (!map.has(group)) map.set(group, []);
        map.get(group).push(proxy);
      }
    });
    return map;
  };
  const before = sets((index) => assigned[index]);
  const after = sets((index) => values[proxyField(index)]);
  return order
    .map((group) => [group, after.get(group) || [], before.get(group) || []])
    .filter(([, next, old]) => next.length !== old.length || next.some((proxy) => !old.includes(proxy)))
    .map(([group, next]) => [group, next]);
}

/**
 * Назначение подключений (`assign_connections`) одной формой: по полю на
 * каждое найденное подключение со списком групп, текущие группы отмечены —
 * снятая отметка снимает назначение. Изменённые группы уходят одной
 * `conn set`; без изменений команды нет. Отмена ничего не меняет; сбой
 * `conn set` (например, `locked`) открывает форму снова с отмеченным.
 */
export async function assignConnections(ctx, name, proxies, assigned, stale = []) {
  if (proxies.length === 0) {
    ctx.notify('warn', NO_CONNECTIONS);
    return;
  }
  const listed = await ctx.call('group', 'list');
  if (!listed.ok) {
    if (ctx.isFailure(listed)) ctx.failed();
    return;
  }
  const groups = asList(listed.data).map((row) => nodeText(row.name));
  if (groups.length === 0) {
    ctx.notify('warn', EMPTY);
    return;
  }
  const options = groups.map((group) => ({ value: group, label: group }));
  const fields = proxies.map((proxy, index) => ({
    name: proxyField(index), label: proxyLabel(proxy, stale), type: 'multi', options,
    value: asList(assigned[index]).filter((group) => groups.includes(group)),
  }));
  let draft = null;
  for (;;) {
    const values = await ctx.form({
      title: 'Назначение подключений группам', context: [`Нода: ${name}`, 'Снятая отметка снимает назначение подключения группе.'],
      fields: refill(fields, draft), submit: 'Сохранить',
    });
    if (values === null || values === undefined) return;
    // Сравнение с начальными значениями формы: группа, удалённая после чтения
    // подключений (её нет в `group list`), не превращается в `--assign G=`.
    const changes = assignmentChanges(proxies, fields.map((field) => field.value), values);
    if (changes.length === 0) return;
    const saved = await ctx.request(assignArgv(name, changes));
    if (ctx.isFailure(saved)) ctx.failed();
    if (!retryable(saved)) return;
    draft = values;
  }
}

/** Назначать нечего: нода не прочитана или на ней нет подключений, назначений нет. */
export const NO_CONNECTIONS = 'Нет подключений для назначения: синхронизируйте ноду.';

export const connSyncArgv = (name = null) => (name === null ? ['conn', 'sync'] : ['conn', 'sync', '--name', name]);
export const connListArgv = (name = null) => (name === null ? ['conn', 'list'] : ['conn', 'list', '--name', name]);
export const nodeCheckArgv = (name) => ['node', 'check', '--name', name];

/**
 * Синхронизация вкладки «Подключения» (`connection_node`): `conn sync
 * --name`; при `partial` с кодом ноды (`NODE_CODES`) — один `node check`
 * через `ctx.nodeRequest` (вопросы о ключе и пароле) и повтор синхронизации,
 * при прочем `partial` — `ctx.failed()`. Итог: `{ synced }` — строка ноды из
 * ответа (`null`, если её нет), либо `{ failed: reply }` — сбой синхронизации
 * (`not_found` — нода исчезла; текст ошибки уже показан `ctx.request`).
 */
export async function syncConnections(ctx, name) {
  let resolve = true;
  for (;;) {
    const reply = await ctx.request(connSyncArgv(name), { expect: 'not_found' });
    if (reply.ok) return { synced: syncedNode(reply.data, name) };
    if (!reply.error || reply.error.code !== 'partial') return { failed: reply };
    const synced = syncedNode(reply.error, name);
    const code = synced && typeof synced.error === 'string' ? synced.error : '';
    if (resolve && NODE_CODES.includes(code)) {
      // Строка синхронизации называет только код; `node check` вернёт
      // состояние с подробностями (отпечатками) для обработчика.
      resolve = false;
      if ((await ctx.nodeRequest(name, nodeCheckArgv(name), null)).ok) continue;
    } else {
      ctx.failed();
    }
    return { synced };
  }
}

// ─── AmneziaWG ───────────────────────────────────────────────────────────────

export const AWG_REMOVE_TITLE = 'Удаление клиента AmneziaWG';
export const AWG_ORPHANS_TITLE = 'Удаление неиспользуемых клиентов AmneziaWG';

export const awgStatusArgv = (name) => ['awg', 'status', '--name', name];
export const awgSyncArgv = (name) => ['awg', 'sync', '--name', name];
export const awgRemovePeerArgv = (name, peer) => ['awg', 'remove', '--name', name, '--peer', peer];
export const awgOrphansArgv = (name) => ['awg', 'remove', '--name', name, '--orphans'];

/** Состояния клиентов AmneziaWG (`awg_node`). */
const AWG_STATES = {
  used: { tone: 'ok', label: 'используется' },
  orphan: { tone: 'warn', label: 'не используется' },
  missing: { tone: 'neutral', label: 'не создан' },
};

/**
 * Вкладка AmneziaWG ноды (`awg_node`) по ответу `awg status`: строки
 * клиентов, признаки недостающих и неиспользуемых. `removable` — клиент
 * существует на ноде (не `missing`).
 */
export function awgView(data) {
  const installed = Boolean(data) && data.installed === true;
  const peers = installed ? asList(data.peers) : [];
  const table = peers.map((peer) => {
    const state = AWG_STATES[peer.status] || AWG_STATES.missing;
    return { name: nodeText(peer.name), status: peer.status, tone: state.tone, label: state.label, removable: peer.status !== 'missing' };
  });
  return {
    installed,
    table,
    missing: table.some((row) => row.status === 'missing'),
    orphans: table.some((row) => row.status === 'orphan'),
  };
}

// ─── Telegram ────────────────────────────────────────────────────────────────

export const TELEGRAM_TITLE = 'Telegram Proxy';
export const TELEGRAM_RESULT_TITLE = 'Результат Telegram Proxy';
export const TELEGRAM_SELECT_TITLE = 'Управление Telegram Proxy';
export const TELEGRAM_STATUS_ARGV = ['telegram', 'status', '--all'];
export const TELEGRAM_COMPONENTS = [
  { value: 'web', label: 'Web Proxy' },
  { value: 'mtproto', label: 'MTProto Proxy' },
];

/**
 * Пакетные действия (меню «Действия») в порядке TUI: `title` — заголовок
 * формы выбора нод и плана, `argv` — команда без `--name`. `component` —
 * в форме ещё и способ доступа (`telegram remove --component`).
 */
export const TELEGRAM_BATCH = [
  { id: 'install', label: 'Включить MTProto Proxy', title: 'Включение MTProto Proxy', argv: ['telegram', 'install'] },
  { id: 'refresh-ip', label: 'Обновить IP-адрес MTProto', title: 'Обновление IP-адреса MTProto', argv: ['telegram', 'refresh-ip'] },
  { id: 'web-update', label: 'Обновить Web Proxy', title: 'Обновление Web Proxy', argv: ['telegram', 'web-update'] },
  { id: 'web-restart', label: 'Перезапустить Web Proxy', title: 'Перезапуск Web Proxy', argv: ['telegram', 'web-restart'] },
  { id: 'backend-restart', label: 'Перезапустить службу MTProxy', title: 'Перезапуск службы MTProxy', argv: ['telegram', 'backend-restart'] },
  { id: 'remove', label: 'Отключить способ доступа', danger: true, title: 'Отключение способа доступа', argv: ['telegram', 'remove'], component: true },
  { id: 'remove-all', label: 'Отключить Telegram Proxy полностью', danger: true, title: 'Полное отключение Telegram Proxy', argv: ['telegram', 'remove-all'] },
];

/** argv пакета: `telegram remove --component C` и по одному `--name` на ноду. */
export function telegramArgv(base, names, component = null) {
  const argv = [...base];
  if (component !== null) argv.push('--component', component);
  for (const name of names) argv.push('--name', name);
  return argv;
}

/** Строки таблицы `telegram_table` (`results` из данных или ошибки); `null` — таблицы нет. */
export function telegramResults(reply) {
  const source = reply.ok ? reply.data : reply.error;
  const results = asList(source && source.results);
  if (results.length === 0) return null;
  return results.map((row) => {
    const [status, tone] = row.status === 'ok' ? ['готово', 'ok']
      : row.status === 'not_installed' ? ['не установлено', 'warn']
        : row.status === 'partial' ? ['частично', 'warn'] : ['ошибка', 'error'];
    return { node: nodeText(row.node), status, reason: nodeText(row.reason), tone };
  });
}

/** Ноды (`node list`) как варианты формы; сбой или пустой список — сообщение и `null`. */
export async function telegramNodes(ctx) {
  const listed = await ctx.call('node', 'list');
  if (!listed.ok) {
    if (ctx.isFailure(listed)) ctx.failed();
    return null;
  }
  const nodes = asList(listed.data).map((row) => ({ value: nodeText(row.name), label: nodeLabel(row) }));
  if (nodes.length === 0) {
    ctx.notify('warn', EMPTY);
    return null;
  }
  return nodes;
}

/**
 * «Управление нодой…»: выбор ноды → `telegram menu` в терминале (`interactive`).
 * Сеанс меняет состояние ноды (перезапуск, секрет, отключение частей), поэтому
 * после открытого сеанса — и при его сбое — вызывается `after()` (экран
 * перечитывает статус); отмена выбора ничего не перечитывает.
 */
export async function telegramMenu(ctx, after = null) {
  const nodes = await telegramNodes(ctx);
  if (nodes === null) return;
  const values = await ctx.form({
    title: TELEGRAM_SELECT_TITLE,
    fields: [{ name: 'node', label: 'Нода', type: 'select', options: nodes }],
    submit: 'Открыть',
  });
  if (values === null || values === undefined) return;
  try {
    await interactive(ctx, values.node, true);
  } finally {
    if (after !== null) await after();
  }
}

/**
 * Пакетное действие (`telegram_batch`): ноды и способ доступа одной формой,
 * план ядра, таблица результатов — `present(строки)` (экран показывает окно).
 * Сбой команды без таблицы открывает форму снова с выбранным.
 * `true` — команда отправлена (отказ от плана и отмена формы ничего не меняли).
 */
export async function telegramBatch(ctx, action, present) {
  const nodes = await telegramNodes(ctx);
  if (nodes === null) return false;
  const fields = [{ name: 'nodes', label: 'Ноды', type: 'multi', options: nodes, required: true }];
  if (action.component) {
    fields.push({ name: 'component', label: 'Способ доступа', type: 'radio', options: TELEGRAM_COMPONENTS, required: true });
  }
  let draft = null;
  for (;;) {
    const values = await ctx.form({ title: action.title, fields: refill(fields, draft), submit: 'Далее', tone: action.danger ? 'danger' : 'primary' });
    if (values === null || values === undefined) return draft !== null;
    const argv = telegramArgv(action.argv, values.nodes, action.component ? values.component : null);
    const reply = await ctx.runConfirmed(action.title, 'Выполнить?', argv);
    const table = telegramResults(reply);
    if (table !== null) {
      await present(table);
      return true;
    }
    if (ctx.isFailure(reply)) ctx.failed();
    if (!retryable(reply)) return reply.ok || ctx.isFailure(reply) || draft !== null;
    draft = values;
  }
}

/** `telegram status --all`: строки таблицы или `null` — сбой без таблицы (сообщён). */
export async function telegramStatus(ctx) {
  const reply = await ctx.call(...TELEGRAM_STATUS_ARGV);
  const table = telegramResults(reply);
  if (table === null && !reply.ok) {
    if (ctx.isFailure(reply)) ctx.failed();
    return null;
  }
  return table || [];
}
