// Модель экранов «Подключения», «AmneziaWG», «Telegram Proxy» — перенос
// чистой логики `tui/src/nodes.rs` (`synced_node`, `sync_problem`, строки
// контекста, argv команд, таблица `telegram_table`). Без DOM и вендоренных
// файлов. Тоны строк: `null` — обычный (NC), `ok` (GREEN), `warn` (YELLOW),
// `error` (RED), `dim` (DIM). Тоны действий — правила скилла essence-menus.

/** Пустой мультивыбор (`nodes.rs::EMPTY`). */
export const EMPTY = 'Нет объектов для выбора';
export const NOTHING_SELECTED = 'Ничего не выбрано.';
export const NO_NODES = 'Нет нод';

/** Строки массива (`rows`). */
export function rows(value) {
  return Array.isArray(value) ? value : [];
}

/** Значение как в `nodes.rs::text`: строка, `null` → пусто, прочее — JSON. */
export function nodeText(value) {
  if (typeof value === 'string') return value;
  if (value === null || value === undefined) return '';
  return JSON.stringify(value);
}

/** Строка ноды в ответе `conn sync` (`synced_node`). */
export function syncedNode(sync, name) {
  return rows(sync && sync.nodes).find((row) => row && row.name === name) || null;
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
 * Обзор подключений (`Connections::run`): ноды `conn list` с состоянием
 * последней синхронизации. Группа: `назначено/всего`, тон — все назначены
 * (`ok`), часть (`warn`), всего неизвестно или 0 (`dim`).
 */
export function overviewNodes(list, synced) {
  return rows(list).map((entry) => {
    const name = nodeText(entry.node);
    const state = syncedNode(synced, name);
    const problem = state ? syncProblem(state.status) : null;
    if (problem) return { name, problem, groups: [] };
    const total = state && Array.isArray(state.discovered) ? state.discovered.length : null;
    const groups = rows(entry.groups).map((group) => {
      const assigned = rows(group.proxies).length;
      const tone = total !== null && total > 0 ? (assigned >= total ? 'ok' : 'warn') : 'dim';
      return { text: `  ${nodeText(group.name)}: ${assigned}/${total === null ? '?' : total}`, tone };
    });
    return { name, problem: null, groups };
  });
}

/** Строки контекста обзора в порядке TUI. */
export function overviewLines(nodes) {
  if (nodes.length === 0) return [{ text: NO_NODES, tone: 'dim' }];
  const lines = [];
  for (const node of nodes) {
    if (node.problem) {
      lines.push({ text: `${node.name}  ${node.problem}`, tone: 'warn' });
      continue;
    }
    lines.push({ text: node.name, tone: null });
    lines.push(...node.groups);
  }
  return lines;
}

/**
 * Карточка подключений ноды (`connection_node`): обнаруженные подключения,
 * группы каждого и строки контекста.
 */
export function connectionView(listed, state, name) {
  const entry = rows(listed).find((row) => row && row.node === name);
  const groups = entry ? rows(entry.groups) : [];
  const proxies = rows(state && state.discovered).map(nodeText);
  const assigned = proxies.map((proxy) => groups
    .filter((group) => rows(group.proxies).includes(proxy))
    .map((group) => nodeText(group.name)));
  const lines = [];
  const problem = syncProblem(state && state.status);
  if (problem) lines.push({ text: `Нода ${problem}`, tone: 'warn' });
  else if (proxies.length === 0) lines.push({ text: 'Подключения не найдены', tone: 'dim' });
  proxies.forEach((proxy, index) => lines.push({ text: `${proxy}  [${assigned[index].join(', ')}]`, tone: null }));
  return { proxies, assigned, lines };
}

/** Заголовок выбора групп (`assign_connections`). */
export function assignGroupsTitle(proxies) {
  return proxies.length === 0 ? 'Группы: снять назначение подключений' : 'Группы для подключений';
}

/** `conn set`: пустой набор подключений снимает назначение групп (без `--proxy`). */
export function assignArgv(name, groups, proxies) {
  const argv = ['conn', 'set', '--name', name];
  for (const group of groups) argv.push('--group', group);
  for (const proxy of proxies) argv.push('--proxy', proxy);
  return argv;
}

/**
 * Назначение подключений (`assign_connections`): сначала подключения
 * (отмечены назначенные), затем целевые группы (без отметок). Без
 * обнаруженных подключений их выбор пропускается: пустой набор снимает
 * назначение выбранных групп (`conn set` без `--proxy`). Отмена любого
 * выбора ничего не меняет.
 */
export async function assignConnections(ctx, name, proxies, assigned) {
  let selected = [];
  if (proxies.length > 0) {
    selected = await ctx.toggle({
      title: 'Подключения для групп',
      options: proxies.map((proxy) => ({ value: proxy, label: proxy })),
      selected: proxies.filter((_, index) => assigned[index].length > 0),
      empty: EMPTY,
      submit: 'Далее',
    });
    if (selected === null) return;
  }
  const listed = await ctx.call('group', 'list');
  if (!listed.ok) {
    if (ctx.isFailure(listed)) ctx.failed();
    return;
  }
  const groups = rows(listed.data).map((row) => nodeText(row.name));
  const targets = await ctx.toggle({
    title: assignGroupsTitle(selected),
    options: groups.map((group) => ({ value: group, label: group })),
    selected: [],
    empty: EMPTY,
  });
  if (targets === null) return;
  if (targets.length === 0) {
    ctx.notify('warn', NOTHING_SELECTED);
    return;
  }
  const saved = await ctx.request(assignArgv(name, targets, selected));
  if (ctx.isFailure(saved)) ctx.failed();
}

export const connSyncArgv = (name = null) => (name === null ? ['conn', 'sync'] : ['conn', 'sync', '--name', name]);
export const connListArgv = (name = null) => (name === null ? ['conn', 'list'] : ['conn', 'list', '--name', name]);
export const nodeCheckArgv = (name) => ['node', 'check', '--name', name];

/** Действия карточки подключений ноды. */
export const CONNECTION_ACTIONS = [
  { id: 'assign', label: 'Назначить подключения группам', tone: 'change' },
  { id: 'aliases', label: 'Псевдонимы подключений', tone: 'change' },
  { id: 'sync', label: 'Синхронизировать с нодой', tone: 'change' },
];

// ─── AmneziaWG ───────────────────────────────────────────────────────────────

export const AWG_REMOVE_TITLE = 'Удаление клиента AmneziaWG';
export const AWG_ORPHANS_TITLE = 'Удаление неиспользуемых клиентов AmneziaWG';

export const awgStatusArgv = (name) => ['awg', 'status', '--name', name];
export const awgSyncArgv = (name) => ['awg', 'sync', '--name', name];
export const awgRemovePeerArgv = (name, peer) => ['awg', 'remove', '--name', name, '--peer', peer];
export const awgOrphansArgv = (name) => ['awg', 'remove', '--name', name, '--orphans'];

/** Карточка AmneziaWG ноды (`awg_node`) по ответу `awg status`. */
export function awgView(data) {
  const installed = Boolean(data) && data.installed === true;
  const peers = rows(data && data.peers);
  const lines = [];
  if (!installed) lines.push({ text: 'AmneziaWG на ноде не установлен', tone: 'dim' });
  else if (peers.length === 0) lines.push({ text: 'Нет клиентов', tone: 'dim' });
  if (installed) {
    for (const peer of peers) {
      const [suffix, tone] = peer.status === 'used' ? ['', 'ok']
        : peer.status === 'orphan' ? ['  не используется', 'warn'] : ['  не создан', 'dim'];
      lines.push({ text: `${nodeText(peer.name)}${suffix}`, tone });
    }
  }
  const removable = peers.filter((peer) => peer.status !== 'missing').map((peer) => nodeText(peer.name));
  const actions = [{ id: 'refresh', label: 'Обновить', tone: 'view' }];
  if (installed) {
    actions.push(
      { id: 'sync', label: 'Создать недостающих', tone: 'create' },
      { id: 'remove', label: 'Удалить клиента', tone: 'danger' },
      { id: 'orphans', label: 'Удалить неиспользуемых', tone: 'danger' },
    );
  }
  return { installed, lines, removable, actions };
}

// ─── Telegram ────────────────────────────────────────────────────────────────

export const TELEGRAM_TITLE = 'Telegram Proxy';
export const TELEGRAM_RESULT_TITLE = 'Результат Telegram Proxy';
export const TELEGRAM_SELECT_TITLE = 'Управление Telegram Proxy';
export const TELEGRAM_STATUS_ARGV = ['telegram', 'status', '--all'];
export const TELEGRAM_COMPONENT_TITLE = 'Отключение способа доступа';
export const TELEGRAM_COMPONENTS = [
  { value: 'web', label: 'Web Proxy' },
  { value: 'mtproto', label: 'MTProto Proxy' },
];

/** Просмотр (первая секция меню `Telegram::run`). */
export const TELEGRAM_VIEW = [
  { id: 'node', label: 'Управление одной нодой', tone: 'view' },
  { id: 'status', label: 'Общий статус нод', tone: 'view' },
];

/**
 * Пакетные действия (вторая секция) в порядке TUI: `title` — заголовок
 * выбора нод и плана, `argv` — команда без `--name`. `component` — сначала
 * выбрать способ доступа (`telegram remove --component`).
 */
export const TELEGRAM_BATCH = [
  { id: 'install', label: 'Включить MTProto Proxy', tone: 'create', title: 'Включение MTProto Proxy', argv: ['telegram', 'install'] },
  { id: 'refresh-ip', label: 'Обновить IP-адрес MTProto', tone: 'change', title: 'Обновление IP-адреса MTProto', argv: ['telegram', 'refresh-ip'] },
  { id: 'web-update', label: 'Обновить Web Proxy', tone: 'change', title: 'Обновление Web Proxy', argv: ['telegram', 'web-update'] },
  { id: 'web-restart', label: 'Перезапустить Web Proxy', tone: 'change', title: 'Перезапуск Web Proxy', argv: ['telegram', 'web-restart'] },
  { id: 'backend-restart', label: 'Перезапустить службу MTProxy', tone: 'change', title: 'Перезапуск службы MTProxy', argv: ['telegram', 'backend-restart'] },
  { id: 'remove', label: 'Отключить способ доступа', tone: 'danger', title: TELEGRAM_COMPONENT_TITLE, argv: ['telegram', 'remove'], component: true },
  { id: 'remove-all', label: 'Отключить Telegram Proxy полностью', tone: 'danger', title: 'Полное отключение Telegram Proxy', argv: ['telegram', 'remove-all'] },
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
  const results = rows(source && source.results);
  if (results.length === 0) return null;
  return results.map((row) => {
    const [status, tone] = row.status === 'ok' ? ['готово', 'ok']
      : row.status === 'not_installed' ? ['не установлено', 'warn']
        : row.status === 'partial' ? ['частично', 'warn'] : ['ошибка', 'error'];
    return { node: nodeText(row.node), status, reason: nodeText(row.reason), tone };
  });
}
