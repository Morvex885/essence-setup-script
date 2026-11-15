// Модель обзора подключений нод, вкладки ноды «Подключения» и
// экрана «Telegram Proxy» — перенос чистой логики `tui/src/nodes.rs`
// (`Connections::run`, `synced_node`, `sync_problem`, `assign_connections`,
// argv команд, таблица `telegram status`) и потоки роли Telegram Web Proxy
// поверх `ctx`. Без DOM и вендоренных файлов: окна с разметкой экран
// передаёт функцией. Тоны: `ok` (GREEN), `warn` (YELLOW), `error` (RED),
// `neutral` (DIM).
import { asList, proxyLabel, strings, unlisted } from '../format.js';
import { refill } from '../form-model.js';
import { NODE_CODES, retryable } from '../flows.js';
import { nodeLabel } from './nodes-model.js';
import { applyState, offerApply, offerApplyNodes, profiledNodes } from './apply-model.js';

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
    else if (saved.ok) await offerApply(ctx);
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

// ─── Telegram ────────────────────────────────────────────────────────────────

export const TELEGRAM_TITLE = 'Telegram Proxy';
export const TELEGRAM_RESULT_TITLE = 'Статус Telegram Proxy';

/** `telegram status` без флагов — все ноды с ролью. */
export const TELEGRAM_STATUS_ARGV = ['telegram', 'status'];
export const telegramSetArgv = (name, domain) => ['telegram', 'set', '--name', name, '--domain', domain];
export const telegramRemoveArgv = (name) => ['telegram', 'remove', '--name', name];
export const telegramLinkArgv = (name) => ['telegram', 'link', '--name', name];
export const telegramRotateArgv = (name) => ['telegram', 'rotate-secret', '--name', name];
/** Спонсорский тег — секретом `password`, в argv его нет. */
export const telegramTagArgv = (name) => ['telegram', 'tag', '--name', name];
export const telegramTagClearArgv = (name) => ['telegram', 'tag', '--name', name, '--clear'];
export const telegramRestartArgv = (name) => ['telegram', 'restart', '--name', name];
export const telegramDiagnosticsArgv = (name) => ['telegram', 'diagnostics', '--name', name];

/** Спонсорский тег: ровно 32 шестнадцатеричных символа. */
export const TELEGRAM_TAG = /^[0-9a-fA-F]{32}$/;
export const TAG_HINT = '32 шестнадцатеричных символа (от @MTProxybot).';

/** Ошибка поля тега или `null`. */
export function tagError(value) {
  return TELEGRAM_TAG.test(String(value || '').trim()) ? null : TAG_HINT;
}

/** Ноды с ролью (`node list .telegram` не `null`): имя, хост, тег и состояние применения. */
export function telegramRows(list) {
  return asList(list)
    .filter((node) => node && typeof node.name === 'string' && node.telegram && typeof node.telegram === 'object')
    .map((node) => ({
      name: node.name,
      hostname: nodeText(node.telegram.hostname),
      tag: node.telegram.tag === true,
      state: applyState(node),
    }));
}

/** Ноды с профилем без роли — варианты формы «Включить на ноде». */
export function telegramCandidates(list) {
  return profiledNodes(list)
    .filter((node) => !node.telegram)
    .map((node) => ({ value: node.name, label: nodeLabel(node) }));
}

/** Строки таблицы `telegram status` (`results` из данных или ошибки); `null` — таблицы нет. */
export function telegramResults(reply) {
  const source = reply.ok ? reply.data : reply.error;
  const results = asList(source && source.results);
  if (results.length === 0) return null;
  return results.map((row) => {
    const [status, tone] = row.status === 'ok' ? ['готово', 'ok']
      : row.status === 'not_installed' ? ['не установлено', 'warn']
        : row.status === 'partial' ? ['частично', 'warn'] : ['ошибка', 'error'];
    return {
      node: nodeText(row.node), hostname: nodeText(row.hostname), status, tone,
      reason: nodeText(row.reason), summary: strings(row.summary),
    };
  });
}

/** `telegram status`: строки таблицы или `null` — сбой без таблицы (сообщён). */
export async function telegramStatus(ctx) {
  const reply = await ctx.call(...TELEGRAM_STATUS_ARGV);
  const table = telegramResults(reply);
  if (table === null && !reply.ok) {
    if (ctx.isFailure(reply)) ctx.failed();
    return null;
  }
  return table || [];
}

/** Итог правки роли: успех — предложение `node apply --name N`, сбой — `failed`. `true` — сохранено. */
async function changed(ctx, name, reply) {
  if (ctx.isFailure(reply)) ctx.failed();
  if (!reply.ok) return false;
  await offerApplyNodes(ctx, [name]);
  return true;
}

const domainField = (value = '') => ({
  name: 'domain', label: 'Домен', type: 'text', value, required: true, placeholder: 'tg.example.com',
  hint: 'Домен, указывающий на ноду.',
});

/**
 * «Включить на ноде»: нода с профилем без роли и домен одной формой →
 * `telegram set`, затем предложение применить. `list` — `node list`.
 */
export async function enableTelegram(ctx, list) {
  const nodes = telegramCandidates(list);
  if (nodes.length === 0) {
    ctx.notify('warn', 'Нет нод с профилем без Telegram Proxy.');
    return false;
  }
  const values = await ctx.form({
    title: 'Включение Telegram Proxy',
    fields: [{ name: 'node', label: 'Нода', type: 'select', options: nodes }, domainField()],
    submit: 'Включить',
  });
  if (values === null || values === undefined) return false;
  return changed(ctx, values.node, await ctx.request(telegramSetArgv(values.node, values.domain.trim())));
}

/** «Сменить домен»: форма с текущим доменом → `telegram set`, затем предложение применить. */
export async function telegramDomainFlow(ctx, name, current = '') {
  const values = await ctx.form({
    title: `Домен Telegram Proxy: ${name}`, fields: [{ ...domainField(current), autofocus: true }], submit: 'Сохранить',
  });
  if (values === null || values === undefined) return false;
  const domain = values.domain.trim();
  if (domain === current) return false;
  return changed(ctx, name, await ctx.request(telegramSetArgv(name, domain)));
}

/** «Сменить секрет» по плану ядра, затем предложение применить. */
export async function rotateTelegramSecret(ctx, name) {
  return changed(ctx, name, await ctx.runConfirmed('Смена секрета Telegram Proxy', 'Сменить секрет?', telegramRotateArgv(name)));
}

/** «Убрать» роль по плану ядра, затем предложение применить. */
export async function removeTelegram(ctx, name) {
  return changed(ctx, name, await ctx.runConfirmed('Отключение Telegram Proxy', 'Убрать Telegram Proxy с ноды?', telegramRemoveArgv(name)));
}

/** «Спонсорский тег»: скрытый ввод (32 hex) → `telegram tag` с секретом `password`, затем предложение применить. */
export async function telegramTagFlow(ctx, name) {
  const values = await ctx.form({
    title: `Спонсорский тег: ${name}`,
    fields: [{ name: 'password', label: 'Спонсорский тег', type: 'secret', required: true, autofocus: true, hint: TAG_HINT, validate: tagError }],
    submit: 'Сохранить',
  });
  if (values === null || values === undefined) return false;
  return changed(ctx, name, await ctx.request(telegramTagArgv(name), { secrets: { password: values.password.trim() } }));
}

/** «Убрать тег» → `telegram tag --clear`, затем предложение применить. */
export async function clearTelegramTag(ctx, name) {
  return changed(ctx, name, await ctx.request(telegramTagClearArgv(name)));
}

/** «Ссылка»: `telegram link` → строка `tg://…` или `null` (сбой сообщён). Ссылка с секретом нигде не пишется. */
export async function telegramLink(ctx, name) {
  const reply = await ctx.request(telegramLinkArgv(name));
  if (!reply.ok) {
    if (ctx.isFailure(reply)) ctx.failed();
    return null;
  }
  const link = reply.data && typeof reply.data.link === 'string' ? reply.data.link : '';
  return link === '' ? null : link;
}

/** «Перезапустить» (SSH, коды нод разрешаются). `true` — перезапущено. */
export async function restartTelegram(ctx, name) {
  const reply = await ctx.nodeRequest(name, telegramRestartArgv(name), null, { operation: `Перезапуск Telegram Proxy: ${name}` });
  return reply.ok;
}

/** «Диагностика»: журнал служб — строками окна операции. */
export async function telegramDiagnostics(ctx, name) {
  const reply = await ctx.nodeRequest(name, telegramDiagnosticsArgv(name), null, { operation: `Диагностика Telegram Proxy: ${name}` });
  return reply.ok;
}
