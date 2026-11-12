// Модель экранов «Шаблоны», «Генерация конфигов», «Подписки» — перенос
// подписей, строк контекста и argv из `tui/src/clients.rs` (`templates`,
// `template_card`, `edit_template`, `generation`, `subscriptions`,
// `subscription_list`, `summary`, `pick`). Без DOM и вендоренных модулей.
import { text, joined, templateSource } from '../format.js';

const rowsOf = (value) => (Array.isArray(value) ? value : []);

// ─── Шаблоны ────────────────────────────────────────────────────────────────

export const TEMPLATE_NAME_MISSING = 'Имя шаблона не указано.';
export const TEMPLATE_FILE_UNREADABLE = 'Файл недоступен или не в UTF-8.';

export const templateList = () => ['template', 'list'];
export const templateCreate = (name) => ['template', 'create', '--name', name];
export const templateShow = (name) => ['template', 'show', '--name', name];
/** Содержимое уходит полем `input.file`, путь к файлу ядру не передаётся. */
export const templateImport = (name) => ['template', 'import', '--name', name];
export const templateInput = (content) => ({ file: content });

/** Строка списка: `name  (встроенный|пользовательский)`. */
export function templateLabel(row) {
  return `${text(row && row.name)}  (${templateSource(row)})`;
}

/** Строка шаблона `name` из `template list` или `null`. */
export function findTemplate(data, name) {
  return rowsOf(data).find((row) => row && row.name === name) || null;
}

/** Контекст карточки шаблона. */
export function templateContext(row) {
  return [`Источник: ${templateSource(row)}`, `Группы: ${joined(row && row.groups)}`];
}

/** Строка пути из `template show`: встроенный шаблон пути не имеет. */
export function templatePath(shown) {
  const path = shown && typeof shown.path === 'string' ? shown.path : null;
  return `Путь: ${path || 'встроенный шаблон'}`;
}

/** Текст шаблона из `template show` (`content`) или `null`. */
export function templateContent(shown) {
  return shown && typeof shown.content === 'string' ? shown.content : null;
}

// Выбор объекта (`pick`) и итоги (`summaryLines`, `GENERATE_FIELDS`) —
// общие с клиентами: `clients-model.js`.

export const PUBLISH_FIELDS = [
  ['published', 'Опубликовано'], ['skipped', 'Пропущено'], ['failed', 'Ошибки'], ['removed', 'Удалено устаревших'],
];

// ─── Генерация ──────────────────────────────────────────────────────────────

export const GENERATE_ALL = ['--all'];
export const generateGroup = (group) => ['--group', group];
export const generateClient = (client) => ['--client', client];

/** Контекст экрана генерации: `группа → шаблон` либо «Нет групп». */
export function generationContext(groups) {
  const list = rowsOf(groups);
  if (list.length === 0) return [{ text: 'Нет групп', tone: 'dim' }];
  return list.map((row) => `${text(row.name)} → ${text(row.template)}`);
}

// ─── Подписки ───────────────────────────────────────────────────────────────

export const SUBSCRIPTION_HOST = ['subscription', 'host'];
export const subscriptionSetHost = (node) => ['subscription', 'host', '--name', node];
export const SUBSCRIPTION_LIST = ['subscription', 'list'];
export const SUBSCRIPTION_PUBLISH_ALL = ['subscription', 'publish-all'];
export const subscriptionMigrate = (node) => ['subscription', 'migrate', '--name', node];

/**
 * Хост-нода: `{ node, baseUrl }` при заданной ноде, иначе `null`
 * (экран пишет «Хост-нода подписок не задана»).
 */
export function subscriptionHost(host) {
  const node = host && typeof host.node === 'string' && host.node !== '' ? host.node : null;
  return node ? { node, baseUrl: `Базовый URL: ${text(host.base_url)}` } : null;
}

/** Состояние подписки из `subscription list`. */
export function subscriptionState(state) {
  switch (state) {
    case 'active': return { label: 'действует', tone: 'ok' };
    case 'expired': return { label: 'истекла', tone: 'warn' };
    case 'unlimited': return { label: 'без срока', tone: 'dim' };
    default: return { label: 'срок неизвестен', tone: 'dim' };
  }
}

/** Строка списка подписок: `{ prefix: "client  expires  ", state }`. */
export function subscriptionRow(row) {
  return { prefix: `${text(row.client)}  ${text(row.expires_at)}  `, state: subscriptionState(row.state) };
}

/** Итог `publish-all`: при неуспехе после загрузки сводка приходит в `error`. */
export function publishSummary(reply) {
  if (reply.ok) return reply.data;
  return reply.error && Object.prototype.hasOwnProperty.call(reply.error, 'published') ? reply.error : null;
}
