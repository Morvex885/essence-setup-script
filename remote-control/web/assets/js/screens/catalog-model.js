// Модель экранов «Шаблоны», «Подписки» и формы генерации конфигов — перенос
// подписей, строк контекста и argv из `tui/src/clients.rs` (`templates`,
// `template_card`, `check_view`, `template_groups`, `generation`,
// `subscriptions`, `subscription_list`, `summary`). Без DOM и вендоренных модулей.
import { text } from '../format.js';

const rowsOf = (value) => (Array.isArray(value) ? value : []);
const count = (value) => (Number.isInteger(value) && value >= 0 ? value : 0);

// ─── Шаблоны ────────────────────────────────────────────────────────────────

export const TEMPLATE_NAME_MISSING = 'Имя шаблона не указано.';
export const TEMPLATE_FILE_UNREADABLE = 'Файл недоступен или не в UTF-8.';
/** Шаблон групп без своего шаблона (`templates.rs::DEFAULT`). */
export const DEFAULT_TEMPLATE = 'default.yaml';
/** Выбор варианта «без группы» в редакторе (`variant: ''` у проблем, `tag: null` у вариантов). */
export const NO_GROUP = 'no-group';

export const templateList = () => ['template', 'list'];
/** `template create --name N [--from T]`: копия шаблона `from`. */
export const templateCreate = (name, from = null) => (from ? ['template', 'create', '--name', name, '--from', from] : ['template', 'create', '--name', name]);
export const templateShow = (name) => ['template', 'show', '--name', name];
/** Содержимое уходит полем `input.file`, путь к файлу ядру не передаётся. */
export const templateImport = (name) => ['template', 'import', '--name', name];
export const templateInput = (content) => ({ file: content });
/** Проверка черновика: текст — полем `input.file` (`templateInput`), имя — для отчёта. */
export const templateCheck = (name) => ['template', 'check', '--name', name];
export const templateDelete = (name) => ['template', 'delete', '--name', name];
/** Группы шаблона: остальные его группы ядро возвращает к `default.yaml`. */
export function templateGroups(name, groups) {
  const argv = ['template', 'groups', '--name', name];
  for (const group of groups) argv.push('--group', group);
  return argv;
}

/** Строка шаблона `name` из `template list` или `null`. */
export function findTemplate(data, name) {
  return rowsOf(data).find((row) => row && row.name === name) || null;
}

/** Вид шаблона: `builtin`, `custom` или `override` (пользовательский поверх встроенного). */
export function templateKind(row) {
  if (!row || row.source === 'builtin') return 'builtin';
  return row.overrides === true ? 'override' : 'custom';
}

/** Подпись и тон отметки вида шаблона. */
export const TEMPLATE_KINDS = {
  builtin: { label: 'встроенный', tone: 'neutral' },
  custom: { label: 'пользовательский', tone: 'info' },
  override: { label: 'изменённый встроенный', tone: 'warn' },
};

/** Текст шаблона из `template show` (`content`) или `null`. */
export function templateContent(shown) {
  return shown && typeof shown.content === 'string' ? shown.content : null;
}

/** Подсказка у групп `default.yaml`: снять их здесь нельзя (`template groups` ничего не сбрасывает с `default.yaml`). */
export const DEFAULT_GROUP_HINT = '— назначьте группе другой шаблон';

/**
 * Выбор групп шаблона (`clients.rs::template_groups`) из `group list`:
 * `options` — «группа — сейчас: шаблон», `selected` — группы этого шаблона.
 * У `default.yaml` его группы отмечены и недоступны: снятая отметка ничего бы
 * не изменила.
 */
export function groupOptions(groupList, name) {
  const groups = rowsOf(groupList).filter((row) => row && typeof row.name === 'string');
  const fixed = name === DEFAULT_TEMPLATE;
  return {
    options: groups.map((row) => {
      const option = { value: row.name, label: `${row.name} — сейчас: ${text(row.template)}` };
      return fixed && row.template === name ? { ...option, disabled: true, hint: DEFAULT_GROUP_HINT } : option;
    }),
    selected: groups.filter((row) => row.template === name).map((row) => row.name),
  };
}

/** Число ошибок и предупреждений отчёта `template check` (до обрезки списка). */
export function problemCounts(data) {
  return { errors: count(data && data.errors), warnings: count(data && data.warnings) };
}

/** Вариант проблемы для выбора: `null` — общая, `''` → `NO_GROUP`, иначе тег. */
export function problemVariant(problem) {
  if (!problem || problem.variant === null || problem.variant === undefined) return null;
  return problem.variant === '' ? NO_GROUP : problem.variant;
}

/** Проблема относится к выбранному варианту: общая (`null`) или того же варианта. */
export function inVariant(problem, variant) {
  const own = problemVariant(problem);
  return own === null || own === variant;
}

/** Отметки Ace (строки и столбцы с нуля) для выбранного варианта. */
export function annotations(problems, variant) {
  return rowsOf(problems).filter((problem) => problem && inVariant(problem, variant)).map((problem) => ({
    row: Math.max(0, count(problem.line) - 1),
    column: Math.max(0, count(problem.column) - 1),
    text: text(problem.message),
    type: problem.level === 'error' ? 'error' : 'warning',
  }));
}

/** Строки `[от, до]` (с единицы), выпадающие из варианта: `NO_GROUP` — вариант `tag: null`. */
export function droppedRanges(variants, tag) {
  const wanted = tag === NO_GROUP || tag === null || tag === undefined ? null : tag;
  const variant = rowsOf(variants).find((item) => item && (item.tag ?? null) === wanted);
  return variant ? rowsOf(variant.dropped).filter((range) => Array.isArray(range) && range.length === 2) : [];
}

/** Варианты для выбора: «без группы» и теги отчёта. */
export function variantOptions(variants) {
  const options = [{ value: NO_GROUP, label: 'Без группы' }];
  for (const item of rowsOf(variants)) {
    if (item && typeof item.tag === 'string' && item.tag !== '') options.push({ value: item.tag, label: item.tag });
  }
  return options;
}

/** Выбранный вариант, если он ещё есть в отчёте; иначе «без группы». */
export function effectiveVariant(variants, variant) {
  return variantOptions(variants).some((option) => option.value === variant) ? variant : NO_GROUP;
}

// Итоги (`summaryLines`, `GENERATE_FIELDS`) — общие с клиентами: `clients-model.js`.

export const PUBLISH_FIELDS = [
  ['published', 'Опубликовано'], ['skipped', 'Пропущено'], ['failed', 'Ошибки'], ['removed', 'Удалено устаревших'],
];

// ─── Генерация ──────────────────────────────────────────────────────────────

export const GENERATE_ALL = ['--all'];
export const generateGroup = (group) => ['--group', group];
export const generateClient = (client) => ['--client', client];

/** Хвост argv `generate` из формы: `scope` — `all|group|client`. */
export function generateScope(values) {
  if (values.scope === 'group') return generateGroup(values.group);
  if (values.scope === 'client') return generateClient(values.client);
  return GENERATE_ALL;
}

// ─── Подписки ───────────────────────────────────────────────────────────────

export const SUBSCRIPTION_HOST = ['subscription', 'host'];
export const subscriptionSetHost = (node) => ['subscription', 'host', '--name', node];
export const SUBSCRIPTION_LIST = ['subscription', 'list'];
export const SUBSCRIPTION_PUBLISH_ALL = ['subscription', 'publish-all'];
export const subscriptionMigrate = (node) => ['subscription', 'migrate', '--name', node];

/** Хост-нода: `{ node, baseUrl }` при заданной ноде, иначе `null` (хост не задан). */
export function subscriptionHost(host) {
  const node = host && typeof host.node === 'string' && host.node !== '' ? host.node : null;
  return node ? { node, baseUrl: text(host.base_url) } : null;
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

/** Строка списка подписок: `{ client, expires, state }`. */
export function subscriptionRow(row) {
  return { client: text(row.client), expires: text(row.expires_at), state: subscriptionState(row.state) };
}

/** Итог `publish-all`: при неуспехе после загрузки сводка приходит в `error`. */
export function publishSummary(reply) {
  if (reply.ok) return reply.data;
  return reply.error && Object.prototype.hasOwnProperty.call(reply.error, 'published') ? reply.error : null;
}
