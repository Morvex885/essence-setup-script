// Модель экранов клиентов и групп — перенос подписей, строк контекста и argv
// из `remote-control/tui/src/clients.rs`. Без DOM и вендоренных файлов.

/** Пустое состояние мультивыбора (`clients.rs::EMPTY`). */
export const EMPTY = 'Нет вариантов для выбора';

/** Строка или «—» (`clients.rs::text`). */
export function str(value) {
  return typeof value === 'string' ? value : '—';
}

/** Скаляр: строка как есть, `null` — «—», иначе JSON (`clients.rs::scalar`). */
export function scalar(value) {
  if (typeof value === 'string') return value;
  if (value === null || value === undefined) return '—';
  return JSON.stringify(value);
}

export function rowsOf(value) {
  return Array.isArray(value) ? value : [];
}

/** Строковые элементы массива (`clients.rs::strings`). */
export function strings(value) {
  return rowsOf(value).filter((item) => typeof item === 'string');
}

/** Имена строк (`clients.rs::names`). */
export function names(value) {
  return rowsOf(value).map((row) => row && row.name).filter((name) => typeof name === 'string');
}

/** Через запятую или «нет» (`clients.rs::joined`). */
export function joined(value) {
  const items = strings(value);
  return items.length === 0 ? 'нет' : items.join(', ');
}

export function findRow(data, name) {
  return rowsOf(data).find((row) => row && row.name === name) || null;
}

/** `name  ip:port` (`clients.rs::node_label`). */
export function nodeLabel(row) {
  return `${str(row.name)}  ${str(row.ip)}:${scalar(row.port)}`;
}

// ─── Клиенты ────────────────────────────────────────────────────────────────

/** Подпись клиента в списке: `name  (group)`. */
export function clientLabel(row) {
  return `${str(row.name)}  (${str(row.group)})`;
}

export function deleteClientsArgv(selected) {
  const argv = ['client', 'delete'];
  for (const name of selected) argv.push('--name', name);
  return argv;
}

/** `clients.rs::subscription_state`. */
export function subscriptionState(row) {
  const sub = (row && row.subscription) || {};
  if (sub.published !== true) return 'нет';
  if (typeof sub.expires_at === 'string' && sub.expires_at !== '') return `опубликована до ${sub.expires_at}`;
  return 'опубликована, без срока';
}

/** Ноды наследуются от группы, пока `inherit_nodes` не `false`. */
export function inherits(row) {
  return row.inherit_nodes !== false;
}

/** Отметка подписки в списках: `{ tone, label }`. */
export function subscriptionBadge(row) {
  const sub = (row && row.subscription) || {};
  if (sub.published !== true) return { tone: 'neutral', label: 'нет' };
  const until = currentExpiry(row);
  return { tone: 'ok', label: until === null ? 'без срока' : `до ${until}` };
}

/**
 * Шаги формы «Изменить клиента» (`client set-group`, затем `client rename`):
 * смена группы идёт под старым именем, переименование — последним.
 */
export function editSteps(name, row, values) {
  const steps = [];
  if (values.group !== str(row.group)) {
    steps.push({ title: 'Смена группы клиента', question: 'Сменить группу?', argv: ['client', 'set-group', '--name', name, '--group', values.group] });
  }
  if (values.name !== name) {
    steps.push({ title: 'Переименование клиента', question: 'Переименовать клиента?', argv: ['client', 'rename', '--name', name, '--new-name', values.name], rename: true });
  }
  return steps;
}

/** Имя после `client rename`: из `data` при успехе, из `error` при `partial`. */
export function renamedName(reply) {
  const source = reply.ok ? reply.data : (reply.error && reply.error.code === 'partial' ? reply.error : null);
  return source && typeof source.name === 'string' ? source.name : null;
}

/** Клиент удалён: успех или `partial` с ним в `deleted`. */
export function clientDeleted(reply, name) {
  if (reply.ok) return true;
  return Boolean(reply.error && reply.error.code === 'partial' && strings(reply.error.deleted).includes(name));
}

/** Строки «Данные клиента» (`clients.rs::show_client`): `{ text, tone }`. */
export function clientDataLines(data) {
  const subscription = data.subscription;
  const link = subscription === null || subscription === undefined
    ? 'нет'
    : (typeof subscription.url === 'string' ? subscription.url : 'ссылка недоступна');
  const credentials = data.credentials || {};
  const config = data.config || {};
  const lines = [
    `Группа: ${str(data.group)}`,
    `Ноды: ${joined(data.nodes)}`,
    `VLESS UUID: ${str(credentials.vless_uuid)}`,
    `Hysteria2 пароль: ${str(credentials.hy2_password)}`,
    `Конфиг: ${str(config.path)} (${config.exists === true ? 'создан' : 'не создан'})`,
    `Подписка: ${link}`,
  ].map((text) => ({ text, tone: null }));
  const connections = rowsOf(data.connections);
  if (connections.length > 0) {
    lines.push({ text: 'Подключения по нодам:', tone: 'info' });
    for (const row of connections) {
      const mode = row.mode === 'own' ? 'свои' : 'от группы';
      lines.push({ text: `  ${str(row.node)} (${mode}): ${joined(row.proxies)}`, tone: null });
    }
  }
  return lines;
}

/**
 * Изменение нод из формы (`mode`: `inherit|own`, `nodes`): `null` — нечего
 * делать (наследование уже включено), иначе `{ kind, argv }`; `inherit` — по плану.
 */
export function nodesChange(name, inherit, values) {
  if (values.mode === 'inherit') return inherit ? null : { kind: 'inherit', argv: inheritNodesArgv(name) };
  return { kind: 'own', argv: clientNodesArgv(name, values.nodes) };
}

export function clientNodesArgv(name, nodes) {
  const argv = ['client', 'nodes', '--name', name];
  for (const node of nodes) argv.push('--node', node);
  return argv;
}

export function inheritNodesArgv(name) {
  return ['client', 'nodes', '--name', name, '--inherit'];
}

/** Прокси клиента на ноде из `client connections --name`. */
export function assignedProxies(assigned, node) {
  return rowsOf(assigned).filter((row) => row && row.node === node).flatMap((row) => strings(row.proxies));
}

/** Найденные на ноде прокси из `conn list --discover`. */
export function discoveredProxies(found) {
  return strings(rowsOf(found)[0] && rowsOf(found)[0].discovered);
}

export function clientConnectionsArgv(name, node, proxies) {
  const argv = ['client', 'connections', '--name', name, '--node', node];
  for (const proxy of proxies) argv.push('--proxy', proxy);
  return argv;
}

export function resetConnectionsArgv(name, node) {
  return ['client', 'connections', '--name', name, '--node', node, '--reset'];
}

// ─── Подписка клиента ───────────────────────────────────────────────────────

/** Текущий срок опубликованной подписки или `null`. */
export function currentExpiry(row) {
  const sub = (row && row.subscription) || {};
  if (sub.published !== true) return null;
  return typeof sub.expires_at === 'string' && sub.expires_at !== '' ? sub.expires_at : null;
}

/**
 * Меню срока (`clients.rs::ttl`): значение `keep` — без `--ttl`, `custom` —
 * спросить свой срок, иначе — значение `--ttl`.
 */
export function ttlOptions(current) {
  return [
    { value: 'keep', label: current === null ? 'Без срока' : `Оставить текущий срок (до ${current})` },
    { value: '12h', label: '12 часов (12h)' },
    { value: '30d', label: '30 дней (30d)' },
    { value: '2w', label: '2 недели (2w)' },
    { value: 'custom', label: 'Другой срок' },
  ];
}

/** Значение `--ttl` из формы публикации: `keep` — `null` (без `--ttl`), `custom` — свой срок. */
export function ttlValue(values) {
  if (values.ttl === 'keep') return null;
  return values.ttl === 'custom' ? values.custom : values.ttl;
}

/** Проверка своего срока: число и `h`, `d` или `w`. */
export function ttlError(value) {
  return /^[0-9]+[hdw]$/.test(value) ? null : 'Срок: число и h, d или w, например 7d';
}

/** `ttl === null` — без `--ttl` (ядро сохраняет текущий срок). */
export function publishArgv(name, ttl) {
  const argv = ['subscription', 'publish', '--name', name];
  if (ttl !== null) argv.push('--ttl', ttl);
  return argv;
}

/** Опубликовано (успех или `partial`: сохранено, не прошла только проверка HTTP). */
export function published(reply) {
  return reply.ok || Boolean(reply.error && reply.error.code === 'partial');
}

/** Строка хоста подписок; `null` — хост не задан. */
export function hostLine(reply) {
  const node = reply && reply.ok && reply.data && typeof reply.data.node === 'string' && reply.data.node !== '' ? reply.data.node : null;
  return node === null
    ? { text: 'Хост подписок не задан — раздел «Подписки»', tone: 'dim' }
    : { text: `Хост подписок: ${node}`, tone: null };
}

/** `curl` со ссылкой в одинарных кавычках (`clients.rs::share_view`). */
export function curlLine(url) {
  return `curl '${url.replace(/'/g, "'\\''")}'`;
}

/** Окно ссылки (`clients.rs::share_view`) из `subscription show`. */
export function shareModel(data) {
  const url = str(data.url);
  const expires = typeof data.expires_at === 'string' && data.expires_at !== '' ? data.expires_at : null;
  return {
    title: `Подписка: ${str(data.client)}`,
    url,
    qr: typeof data.url === 'string' ? data.url : null,
    expires,
    headers: rowsOf(data.headers).map((row) => `${str(row.name)}: ${str(row.value)}`),
    curl: curlLine(url),
    json: JSON.stringify({ url }),
  };
}

const SOURCES = { default: 'по умолчанию', group: 'группа', client: 'клиент' };

/** Строка заголовка; с источником — для клиента (`clients.rs::header_line`). */
export function headerLine(row, withSource) {
  let source = '';
  if (withSource) {
    const value = row.source;
    const label = typeof value === 'string' ? (SOURCES[value] || value) : '—';
    source = `  [${label}]`;
  }
  return `${str(row.name)}: ${str(row.value)}${source}`;
}

export function headerLines(data, withSource) {
  const list = rowsOf(data);
  if (list.length === 0) return ['Нет заголовков'];
  return list.map((row) => headerLine(row, withSource));
}

/** Удаляемые заголовки: клиент удаляет только свои. */
export function removableHeaders(data, client) {
  return rowsOf(data).filter((row) => !client || row.source === 'client').map((row) => str(row.name));
}

export function headersArgv(kind, name, ...tail) {
  return ['subscription', 'headers', `--${kind}`, name, ...tail];
}

// ─── Генерация ──────────────────────────────────────────────────────────────

export const GENERATE_FIELDS = [
  ['ok', 'Готово'], ['skipped', 'Пропущено'], ['failed', 'Ошибки'], ['nodes_failed', 'Ноды с ошибкой'], ['dir', 'Каталог'],
];

/** Данные итога: `data` при успехе, `error` при `partial`, иначе `null`. */
export function generateResult(reply) {
  if (reply.ok) return reply.data || {};
  if (reply.error && reply.error.code === 'partial') return reply.error;
  return null;
}

/** Кадр итога (`clients.rs::summary`): пустые поля пропускаются, сбои — `warn`. */
export function summaryLines(data, fields, empty) {
  const lines = [];
  for (const [field, label] of fields) {
    const raw = data ? data[field] : undefined;
    let value = '';
    if (Array.isArray(raw)) value = strings(raw).join(', ');
    else if (typeof raw === 'string') value = raw;
    else if (typeof raw === 'number' && raw !== 0) value = String(raw);
    if (value === '') continue;
    lines.push({ text: `${label}: ${value}`, tone: field.includes('failed') ? 'warn' : null });
  }
  if (lines.length === 0) lines.push({ text: empty, tone: 'dim' });
  return lines;
}

// ─── Группы ─────────────────────────────────────────────────────────────────

/** Пункт «Создать новый…»: `/` не бывает в имени файла шаблона. */
export const NEW_TEMPLATE = '/new';

/**
 * Выбор шаблона группы (`clients.rs::group_template`): `null` — без изменений,
 * `{ kind: 'set', template }` или `{ kind: 'create', name }`.
 */
export function templateChange(current, values) {
  if (values.template === NEW_TEMPLATE) return { kind: 'create', name: values.name };
  return values.template === current ? null : { kind: 'set', template: values.template };
}
