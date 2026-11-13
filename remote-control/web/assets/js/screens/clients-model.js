// Модель экранов клиентов, групп и генерации — перенос подписей, строк
// контекста, argv и действий из `remote-control/tui/src/clients.rs`. Без DOM:
// действия (`fetch`, `load`, `generate`, `headers`, добавление и перенос) —
// формы и диалоги `ctx` (`app.js::makeContext`).
import { asList, strings } from '../format.js';
import { isFailure } from '../flows.js';
import { DEFAULT_TEMPLATE, generateGroup, generateClient, generateScope } from './catalog-model.js';

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

/** Имена строк (`clients.rs::names`). */
export function names(value) {
  return asList(value).map((row) => row && row.name).filter((name) => typeof name === 'string');
}

/** Через запятую или «нет» (`clients.rs::joined`). */
export function joined(value) {
  const items = strings(value);
  return items.length === 0 ? 'нет' : items.join(', ');
}

export function findRow(data, name) {
  return asList(data).find((row) => row && row.name === name) || null;
}

/** `name  ip:port` (`clients.rs::node_label`). */
export function nodeLabel(row) {
  return `${str(row.name)}  ${str(row.ip)}:${scalar(row.port)}`;
}

// ─── Клиенты ────────────────────────────────────────────────────────────────

export const clientAddArgv = (values) => ['client', 'add', '--name', values.name, '--group', values.group];
export const clientDeleteArgv = (name) => ['client', 'delete', '--name', name];
export const clientSetGroupArgv = (name, group) => ['client', 'set-group', '--name', name, '--group', group];
export const discoverArgv = (node) => ['conn', 'list', '--name', node, '--discover'];
export const subscriptionRotateArgv = (name) => ['subscription', 'rotate', '--name', name];
export const subscriptionRevokeArgv = (name) => ['subscription', 'revoke', '--name', name];

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
  const connections = asList(data.connections);
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
  return asList(assigned).filter((row) => row && row.node === node).flatMap((row) => strings(row.proxies));
}

/**
 * Свои ноды клиента для таблицы «Подключения по нодам»: `missing` — ноды нет
 * в `node list` (удалена). Пока список не прочитан (`null`), отметок нет.
 */
export function ownNodeRows(nodes, nodeList) {
  const known = nodeList === null || nodeList === undefined ? null : names(nodeList);
  return strings(nodes).map((name) => ({ name, missing: known !== null && !known.includes(name) }));
}

/** Найденные на ноде прокси из `conn list --discover`. */
export function discoveredProxies(found) {
  return strings(asList(found)[0] && asList(found)[0].discovered);
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

export const TTL_INVALID = 'Срок: число от 1 до 999999 без ведущего нуля и h, d или w, например 7d';

/** Проверка своего срока по правилу ядра (`subscription::ttl_expiry`): 1–6 цифр без ведущего 0 и `h|d|w`. */
export function ttlError(value) {
  return /^[1-9][0-9]{0,5}[hdw]$/.test(String(value || '')) ? null : TTL_INVALID;
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

/** Строка хоста подписок: задан, не задан или не прочитан (сбой чтения — не «не задан»). */
export function hostLine(reply) {
  if (!reply || !reply.ok) return { text: 'Хост подписок: не удалось прочитать', tone: 'warn' };
  const node = reply.data && typeof reply.data.node === 'string' && reply.data.node !== '' ? reply.data.node : null;
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
    headers: asList(data.headers).map((row) => `${str(row.name)}: ${str(row.value)}`),
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
  const list = asList(data);
  if (list.length === 0) return ['Нет заголовков'];
  return list.map((row) => headerLine(row, withSource));
}

/** Удаляемые заголовки: клиент удаляет только свои. */
export function removableHeaders(data, client) {
  return asList(data).filter((row) => !client || row.source === 'client').map((row) => str(row.name));
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

export const groupDeleteArgv = (name) => ['group', 'delete', '--name', name];
export const groupSetTemplateArgv = (name, template) => ['group', 'set-template', '--name', name, '--template', template];
/** Новый шаблон группы — копия её текущего (`template create --group`). */
export const groupTemplateCreateArgv = (template, group) => ['template', 'create', '--name', template, '--group', group];

// ─── Действия поверх ctx ────────────────────────────────────────────────────

/** Команда действия; неуспех — предупреждение (`clients.rs::execute`). */
export async function execute(ctx, argv, options) {
  const reply = await ctx.request(argv, options);
  if (!reply.ok) ctx.failed();
  return reply;
}

/** Опасное действие по плану; отказ от плана — не сбой (`clients.rs::confirmed_with`). */
export async function confirmed(ctx, title, question, argv, options) {
  const reply = await ctx.runConfirmed(title, question, argv, options);
  if (isFailure(reply)) ctx.failed();
  return reply;
}

/** Чтение внутри действия: `{ data }` или `null` после предупреждения (`fetch`). */
export async function fetchData(ctx, argv) {
  const reply = await execute(ctx, argv);
  return reply.ok ? { data: reply.data } : null;
}

/**
 * Чтение подменю (`clients.rs::load`): `not_found` — выход, прочие сбои —
 * явный «Повторить». Возвращает `{ data }` или `null`.
 */
export async function loadData(ctx, title, argv) {
  for (;;) {
    const reply = await ctx.request(argv, { expect: 'not_found' });
    if (reply.ok) return { data: reply.data };
    if (reply.error && reply.error.code === 'not_found') return null;
    ctx.failed();
    const choice = await ctx.choose({
      title, context: ['Данные недоступны'], options: [{ value: 'retry', label: 'Повторить' }], cancel: 'Назад',
    });
    if (choice !== 'retry') return null;
  }
}

/** Варианты поля `select` из строк списка: подпись — `label(row)` или имя. */
export function nameOptions(data, label = null) {
  return asList(data)
    .filter((row) => row && typeof row.name === 'string')
    .map((row) => ({ value: row.name, label: label ? label(row) : row.name }));
}

/** Имя из ответа команды (`data.name`, ядро может его нормализовать) или `fallback`. */
export function replyName(reply, fallback) {
  return reply.ok && reply.data && typeof reply.data.name === 'string' && reply.data.name ? reply.data.name : fallback;
}

/**
 * Добавление клиента: имя и группа одной формой → `client add`; успех —
 * `go(имя)`: экран открывает карточку, только пока смонтирован.
 */
export async function addClientFlow(ctx, go) {
  const read = await fetchData(ctx, ['group', 'list']);
  if (!read) return;
  const values = await ctx.form({
    title: 'Добавить клиента',
    submit: 'Добавить',
    fields: [
      { name: 'name', label: 'Имя клиента', type: 'text', required: 'Имя клиента не указано.', autofocus: true },
      { name: 'group', label: 'Группа', type: 'select', options: nameOptions(read.data), required: true },
    ],
  });
  if (values === null || values === undefined) return;
  const reply = await execute(ctx, clientAddArgv(values));
  if (reply.ok) go(replyName(reply, values.name));
}

/**
 * Добавление группы: имя и шаблон одной формой → `group add`, затем
 * `group set-template` для не встроенного шаблона (по имени из ответа: ядро
 * нормализует имя группы).
 */
export async function addGroupFlow(ctx) {
  const read = await fetchData(ctx, ['template', 'list']);
  if (!read) return;
  const values = await ctx.form({
    title: 'Добавить группу',
    submit: 'Добавить',
    fields: [
      { name: 'name', label: 'Название группы', type: 'text', required: 'Название не указано.', autofocus: true },
      { name: 'template', label: 'Шаблон', type: 'select', value: DEFAULT_TEMPLATE, options: nameOptions(read.data) },
    ],
  });
  if (values === null || values === undefined) return;
  const reply = await execute(ctx, ['group', 'add', '--name', values.name]);
  if (reply.ok && values.template !== DEFAULT_TEMPLATE) {
    await execute(ctx, groupSetTemplateArgv(replyName(reply, values.name), values.template));
  }
}

/**
 * Шаблон группы (`clients.rs::group_template`): выбор шаблона или новый
 * шаблон группы. Возвращает имя созданного шаблона (экран открывает его
 * редактор) или `null`.
 */
export async function groupTemplateFlow(ctx, name, current) {
  const read = await fetchData(ctx, ['template', 'list']);
  if (!read) return null;
  const values = await ctx.form({
    title: `Шаблон группы: ${name}`,
    fields: [
      { name: 'template', label: 'Шаблон', type: 'select', value: current,
        options: [...nameOptions(read.data), { value: NEW_TEMPLATE, label: 'Создать новый…' }] },
      { name: 'name', label: 'Имя нового шаблона', type: 'text', required: 'Имя шаблона не указано.',
        when: (v) => v.template === NEW_TEMPLATE },
    ],
  });
  if (values === null || values === undefined) return null;
  const plan = templateChange(current, values);
  if (plan === null) return null;
  if (plan.kind === 'set') {
    await execute(ctx, groupSetTemplateArgv(name, plan.template));
    return null;
  }
  const created = await execute(ctx, groupTemplateCreateArgv(plan.name, name));
  return created.ok ? replyName(created, null) : null;
}

/** Перенос клиента группы `group` в другую из `groups` (`group list`) по плану. */
export async function moveClientFlow(ctx, group, groups, client) {
  const others = nameOptions(groups).filter((option) => option.value !== group);
  if (others.length === 0) { ctx.notify('warn', EMPTY); return; }
  const values = await ctx.form({
    title: `Перенос клиента: ${client}`,
    submit: 'Перенести',
    fields: [{ name: 'group', label: 'Новая группа', type: 'select', options: others, required: true }],
  });
  if (values === null || values === undefined) return;
  await confirmed(ctx, 'Смена группы клиента', 'Сменить группу?', clientSetGroupArgv(client, values.group));
}

/** Окно итога (`clients.rs::summary`): строки `summaryLines` контекстом окна. */
export function showSummary(ctx, title, data, fields, empty) {
  return ctx.show({ title, context: summaryLines(data, fields, empty) });
}

/**
 * `generate …` (`clients.rs::generate`): итог при успехе и при `partial`
 * (поля в `error`). `scope` — хвост argv: `['--all']`, `['--group', G]`, `['--client', C]`.
 */
export async function runGenerate(ctx, scope) {
  const reply = await ctx.request(['generate', ...scope]);
  const data = generateResult(reply);
  if (data === null) { ctx.failed(); return; }
  await showSummary(ctx, 'Итог генерации', data, GENERATE_FIELDS, 'Нет результатов');
}

const GENERATE_SCOPES = [
  { value: 'all', label: 'Всем клиентам' },
  { value: 'group', label: 'Группе' },
  { value: 'client', label: 'Одному клиенту' },
];

/**
 * Генерация конфигов (`clients.rs::generation`): `preset` — `{ group }` или
 * `{ client }` — сразу без формы; иначе списки групп и клиентов читаются до
 * формы «Кому» (сбой — `ctx.failed`).
 */
export async function generateFlow(ctx, preset = null) {
  if (preset && typeof preset.group === 'string') { await runGenerate(ctx, generateGroup(preset.group)); return; }
  if (preset && typeof preset.client === 'string') { await runGenerate(ctx, generateClient(preset.client)); return; }
  const [groups, clients] = await Promise.all([ctx.request(['group', 'list']), ctx.request(['client', 'list'])]);
  if (!groups.ok || !clients.ok) { ctx.failed(); return; }
  const values = await ctx.form({
    title: 'Генерация конфигов',
    submit: 'Сгенерировать',
    fields: [
      { name: 'scope', label: 'Кому', type: 'radio', value: 'all', options: GENERATE_SCOPES },
      { name: 'group', label: 'Группа', type: 'select', options: nameOptions(groups.data), required: true, when: (v) => v.scope === 'group' },
      { name: 'client', label: 'Клиент', type: 'select', options: nameOptions(clients.data), required: true, when: (v) => v.scope === 'client' },
    ],
  });
  if (values === null || values === undefined) return;
  await runGenerate(ctx, generateScope(values));
}

/** Заголовки подписки клиента или группы (`clients.rs::headers`); `kind`: `client|group`. */
export async function showHeaders(ctx, kind, name) {
  const client = kind === 'client';
  for (;;) {
    const read = await loadData(ctx, 'Заголовки подписки', headersArgv(kind, name));
    if (!read) return;
    const choice = await ctx.choose({
      title: `Заголовки подписки: ${name}`,
      context: headerLines(read.data, client),
      options: [{ value: 'set', label: 'Установить' }, { value: 'unset', label: 'Удалить', tone: 'danger' }],
      cancel: 'Назад',
    });
    if (choice === null || choice === undefined) return;
    if (choice === 'set') {
      const values = await ctx.form({
        title: 'Установить заголовок',
        fields: [
          { name: 'header', label: 'Имя заголовка', type: 'text', required: true, autofocus: true },
          { name: 'value', label: 'Значение', type: 'text', required: true },
        ],
        submit: 'Установить',
      });
      if (values === null || values === undefined) continue;
      await execute(ctx, headersArgv(kind, name, '--set', `${values.header}=${values.value}`));
    } else {
      const own = removableHeaders(read.data, client);
      const target = await ctx.choose({ title: 'Удаление заголовка', options: own.map((item) => ({ value: item, label: item, tone: 'danger' })) });
      if (target !== null && target !== undefined) await execute(ctx, headersArgv(kind, name, '--unset', target));
    }
  }
}

/** Итоговые заголовки клиента с источником (`clients.rs::resolved_headers`). */
export async function resolvedHeaders(ctx, name) {
  const read = await fetchData(ctx, ['subscription', 'headers', '--client', name]);
  if (!read) return;
  await ctx.show({ title: `Итоговые заголовки: ${name}`, lines: headerLines(read.data, true) });
}
