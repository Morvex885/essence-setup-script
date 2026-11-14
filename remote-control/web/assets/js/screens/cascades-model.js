// Модель экрана «Каскады» без DOM: argv `cascade list|add|delete`, варианты
// входа и выхода из `node list` (ноды с профилем и их подключения), форма
// добавления и потоки поверх `ctx`. URI внешнего сервера уходит полем
// `input.file` (как `template import`), в argv его нет.
import { asList, strings } from '../format.js';
import { offerApplyNodes, profiledNodes } from './apply-model.js';

/** Слушатели входа: значение `--listener` → имя подключения ноды. */
export const LISTENERS = [
  { value: 'vless-tcp', proxy: 'VLESS TCP' },
  { value: 'vless-xhttp', proxy: 'VLESS xHTTP' },
  { value: 'vless-grpc', proxy: 'VLESS gRPC' },
  { value: 'hysteria2', proxy: 'Hysteria2' },
];
/** Подключения выходной ноды (`--exit-proxy`). */
export const EXIT_PROXIES = LISTENERS.map((listener) => listener.proxy);

/** Вид выхода в форме. */
export const EXIT_NODE = 'node';
export const EXIT_URI = 'uri';

export const NO_ENTRY_NODES = 'Нет нод с профилем и включёнными VLESS или Hysteria2 — сначала назначьте ноде профиль.';
export const EXIT_SAME = 'Выходная нода совпадает со входной.';
export const URI_INVALID = 'Нужна ссылка vless:// или hysteria2://.';

export const CASCADE_LIST = ['cascade', 'list'];
export const NODE_LIST = ['node', 'list'];
export const cascadeDeleteArgv = (name) => ['cascade', 'delete', '--name', name];

/**
 * `cascade add --name C --entry N --listener L (--exit-node M --exit-proxy P | …)`;
 * выход URI — без флагов выхода, ссылка уходит `cascadeInput`.
 */
export function cascadeAddArgv(choice) {
  const argv = ['cascade', 'add', '--name', choice.name, '--entry', choice.entry, '--listener', choice.listener];
  if (choice.uri === null) argv.push('--exit-node', choice.exitNode, '--exit-proxy', choice.exitProxy);
  return argv;
}

/** URI внешнего сервера — входом `file` запроса (`cascade add --file`). */
export const cascadeInput = (uri) => ({ file: uri });

/** Каскады из `cascade list` (`{ cascades: [...] }`). */
export function cascadeRows(data) {
  return asList(data && data.cascades).filter((row) => row && typeof row.name === 'string');
}

/** Ноды, на которых каскад рендерится: вход и управляемый выход. */
export function cascadeNodes(row) {
  const nodes = typeof row.entry === 'string' ? [row.entry] : [];
  const exit = row.exit;
  if (exit && typeof exit.node === 'string') nodes.push(exit.node);
  return nodes;
}

/** Подпись слушателя входа: имя подключения. */
export function listenerLabel(value) {
  const found = LISTENERS.find((listener) => listener.value === value);
  return found ? found.proxy : String(value ?? '');
}

/** Подпись выхода: внешний сервер или `нода · подключение`. */
export function exitLabel(exit) {
  if (exit && exit.uri === true) return 'Внешний сервер (URI)';
  if (exit && typeof exit.node === 'string') return `${exit.node} · ${String(exit.proxy ?? '')}`;
  return '—';
}

/** Слушатели входа, включённые на ноде (`proxies` из `node list`). */
export function listenerOptions(node) {
  const proxies = strings(node && node.proxies);
  return LISTENERS.filter((listener) => proxies.includes(listener.proxy)).map((listener) => ({ value: listener.value, label: listener.proxy }));
}

/** Подключения ноды, через которые возможен выход. */
export function exitProxyOptions(node) {
  const proxies = strings(node && node.proxies);
  return EXIT_PROXIES.filter((proxy) => proxies.includes(proxy)).map((proxy) => ({ value: proxy, label: proxy }));
}

/** Ноды входа: с профилем и хотя бы одним слушателем. */
export const entryNodes = (list) => profiledNodes(list).filter((node) => listenerOptions(node).length > 0);
/** Ноды выхода: с профилем и хотя бы одним подключением выхода. */
export const exitNodes = (list) => profiledNodes(list).filter((node) => exitProxyOptions(node).length > 0);

/** URI внешнего сервера: `vless://…` или `hysteria2://…` (разбор — в ядре). */
export function uriError(value) {
  const uri = String(value ?? '').trim();
  return uri === '' || /^(vless|hysteria2):\/\/\S+$/.test(uri) ? null : URI_INVALID;
}

const options = (nodes) => nodes.map((node) => ({ value: node.name, label: node.name }));

/**
 * Поля формы «Добавить каскад» по `node list`: имя → нода входа → её
 * слушатель (поле на каждую ноду, видно при её выборе) → выход: нода из
 * списка и её подключение (поле на каждую ноду) или URI (скрытый ввод).
 * `previous` — ввод прошлой попытки (секретное поле всегда пусто).
 */
export function cascadeFields(list, previous = {}) {
  const entries = entryNodes(list);
  const exits = exitNodes(list);
  // Выход на ноду возможен, только если есть пара «вход ≠ выход».
  const nodeExit = exits.some((exit) => entries.some((entry) => entry.name !== exit.name));
  return [
    { name: 'name', label: 'Имя каскада', type: 'text', value: previous.name ?? '', required: 'Имя каскада не указано.', autofocus: true,
      hint: 'Станет подключением входной ноды' },
    { name: 'entry', label: 'Входная нода', type: 'select', value: previous.entry ?? null, options: options(entries), required: true },
    ...entries.map((node, index) => ({
      name: `listener_${index}`, label: 'Вход', type: 'select', value: previous[`listener_${index}`] ?? null,
      options: listenerOptions(node), required: true, when: (v) => v.entry === node.name,
    })),
    { name: 'exit', label: 'Выход', type: 'radio', value: previous.exit ?? (nodeExit ? EXIT_NODE : EXIT_URI),
      options: [
        { value: EXIT_NODE, label: 'Нода из списка', disabled: !nodeExit },
        { value: EXIT_URI, label: 'URI внешнего сервера' },
      ] },
    { name: 'exit_node', label: 'Выходная нода', type: 'select', value: previous.exit_node ?? null, options: options(exits), required: true,
      validate: (value, values) => (value === values.entry ? EXIT_SAME : null), when: (v) => v.exit === EXIT_NODE },
    ...exits.map((node, index) => ({
      name: `exit_proxy_${index}`, label: 'Подключение выхода', type: 'select', value: previous[`exit_proxy_${index}`] ?? null,
      options: exitProxyOptions(node), required: true, when: (v) => v.exit === EXIT_NODE && v.exit_node === node.name,
    })),
    { name: 'uri', label: 'URI внешнего сервера', type: 'secret', placeholder: 'vless://… или hysteria2://…', required: 'URI не указан.',
      validate: uriError, when: (v) => v.exit === EXIT_URI },
  ];
}

/** Выбор формы → `{ name, entry, listener, exitNode, exitProxy, uri }` (`uri: null` — выход на ноду). */
export function cascadeChoice(values, list) {
  const entry = entryNodes(list).findIndex((node) => node.name === values.entry);
  const base = { name: String(values.name).trim(), entry: values.entry, listener: values[`listener_${entry}`] };
  if (values.exit === EXIT_URI) return { ...base, exitNode: null, exitProxy: null, uri: String(values.uri).trim() };
  const exit = exitNodes(list).findIndex((node) => node.name === values.exit_node);
  return { ...base, exitNode: values.exit_node, exitProxy: values[`exit_proxy_${exit}`], uri: null };
}

/**
 * «Добавить каскад» одной формой; сбой ядра (`exists`, `invalid`) возвращает
 * форму с прежним вводом. После добавления — предложение `node apply` на
 * входной и выходной ноде. `true` — каскад добавлен.
 */
export async function addCascadeFlow(ctx) {
  const listed = await ctx.request(NODE_LIST);
  if (!listed.ok) { ctx.failed(); return false; }
  const list = listed.data;
  if (entryNodes(list).length === 0) { ctx.notify('warn', NO_ENTRY_NODES); return false; }
  let previous = {};
  for (;;) {
    const values = await ctx.form({ title: 'Добавить каскад', fields: cascadeFields(list, previous), submit: 'Добавить' });
    if (values === null || values === undefined) return false;
    previous = values;
    const choice = cascadeChoice(values, list);
    const reply = await ctx.request(cascadeAddArgv(choice), choice.uri === null ? {} : { input: cascadeInput(choice.uri) });
    if (reply.ok) {
      const nodes = reply.data ? cascadeNodes(reply.data) : [];
      await offerApplyNodes(ctx, nodes.length ? nodes : [choice.entry, choice.exitNode].filter(Boolean));
      return true;
    }
    ctx.failed();
  }
}

/** Удаление по плану ядра, затем предложение `node apply` на нодах каскада. `true` — удалён. */
export async function deleteCascade(ctx, row) {
  const reply = await ctx.runConfirmed('Удаление каскада', 'Удалить каскад?', cascadeDeleteArgv(row.name));
  if (ctx.isFailure(reply)) ctx.failed();
  if (!reply.ok) return false;
  await offerApplyNodes(ctx, cascadeNodes(row));
  return true;
}
