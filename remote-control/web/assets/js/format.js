// Подписи и форматирование значений ответов ядра — те же слова, что в TUI
// (`remote-control/tui/src`). Чистые функции: без DOM и вендоренных файлов.

/** Значение ячейки: `null`/`undefined`/пустая строка → «—», объекты — JSON. */
export function text(value) {
  if (value === null || value === undefined || value === '') return '—';
  if (typeof value === 'string') return value;
  if (typeof value === 'number' || typeof value === 'boolean') return String(value);
  return JSON.stringify(value);
}

/** Список через запятую; пустой или отсутствующий — «нет». */
export function joined(list) {
  if (!Array.isArray(list) || list.length === 0) return 'нет';
  return list.map((item) => (typeof item === 'string' ? item : text(item))).join(', ');
}

/** Префикс `v` ровно один раз (`system.rs::version_label`). */
export function versionLabel(version) {
  const value = typeof version === 'string' ? version : '';
  return `v${value.startsWith('v') ? value.slice(1) : value}`;
}

/**
 * Состояние синхронизации источника GitHub (`system.rs::sync_state`).
 * `tone` — класс оформления: `ok` (зелёный), `warn` (жёлтый).
 */
export function syncState(sync) {
  if (sync === 'clean') return { label: 'синхронизировано', tone: 'ok' };
  if (sync === 'pending') return { label: 'ожидает отправки', tone: 'warn' };
  return { label: 'нет связи', tone: 'warn' };
}

/** Строка источника конфигурации из `status.source` для шапки и сводки. */
export function sourceLabel(source) {
  if (source && source.type === 'github') {
    const repo = typeof source.repo === 'string' && source.repo ? ` ${source.repo}` : '';
    return { label: `GitHub${repo}`, sync: syncState(source.sync) };
  }
  return { label: 'локальная', sync: null };
}

/** Состояние скриптов на ноде (`nodes.rs::offer_upload`). */
export function scriptsState(state) {
  switch (state) {
    case 'missing': return 'скрипты отсутствуют';
    case 'outdated': return 'скрипты устарели';
    case 'broken': return 'установка повреждена';
    default: return 'версия скриптов неизвестна';
  }
}

/** Строка выполняющейся операции по argv (`app.rs::activity`). */
export function activity(argv) {
  const [noun = '', verb = ''] = Array.isArray(argv) ? argv : [];
  const nodeNouns = ['node', 'conn', 'awg', 'telegram'];
  if (noun === 'session' && verb === 'open') return 'Открытие сессии…';
  if (noun === 'status') return 'Загрузка состояния…';
  if (noun === 'source') {
    switch (verb) {
      case 'github-accounts': return 'Проверка аккаунтов GitHub…';
      case 'github-login': return 'Вход в GitHub: следуйте инструкциям в журнале и браузере…';
      case 'github-connect': return 'Подключение к GitHub…';
      case 'github-change-account': return 'Смена аккаунта GitHub…';
      case 'github-fetch': return 'Загрузка конфигурации из GitHub…';
      case 'github-push': case 'github-replace-with-local': case 'github-migrate-format':
      case 'github-rewrap-password': case 'github-rotate-key':
        return 'Отправка конфигурации в GitHub…';
      case 'github-delete-repo': return 'Удаление репозитория GitHub…';
      default: if (verb.startsWith('github-')) return 'Обмен данными с GitHub…';
    }
  }
  if (nodeNouns.includes(noun)) {
    return ['list', 'show', 'aliases', 'rename', 'tag'].includes(verb) ? 'Выполняется…' : 'Подключение к серверам…';
  }
  if (noun === 'subscription' && ['publish', 'publish-all', 'rotate', 'revoke', 'migrate', 'host'].includes(verb)) {
    return 'Публикация подписок на серверах…';
  }
  if (noun === 'self' && (verb === 'version' || verb === 'update')) return 'Проверка обновлений…';
  return 'Выполняется…';
}

/** Индикатор шапки по событию `activity` (`command` — «noun verb»). */
export function activityIndicator(command) {
  return command ? `Выполняется: ${command}` : '';
}

/**
 * «Открытая панель»: слушатель не на loopback и пароль запуска не задан
 * (поле `open` у `web status` / `web start`). Без `web status` вычисляется по
 * `hello.listener` и `status.script_password`.
 */
export function openPanel(hello, status, web) {
  if (web && typeof web.open === 'boolean') return web.open;
  const listener = hello && hello.listener;
  return Boolean(listener) && listener.loopback === false && Boolean(status) && status.script_password === false;
}

export const OPEN_PANEL_WARNING = 'Пароль запуска не задан: панель доступна всем в сети.';

/** Сообщение ошибки ответа ядра для показа пользователю. */
export function errorMessage(reply) {
  const error = reply && reply.error;
  if (error && typeof error.message === 'string' && error.message) return error.message;
  return 'Операция не выполнена.';
}

/** Наибольший размер входных данных команды (`input.file`), байт — предел демона. */
export const MAX_INPUT = 1 << 20;
export const FILE_TOO_LARGE = 'Файл больше 1 МиБ.';

/**
 * Текст выбранного файла, как у терминального меню: не больше `MAX_INPUT`
 * байт и строго UTF-8 (BOM сохраняется). `{text}` или `{error}`; `error: null`
 * — файл не читается или не в UTF-8.
 */
export async function readInputFile(file) {
  if (file.size > MAX_INPUT) return { error: FILE_TOO_LARGE };
  try {
    return { text: new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(await file.arrayBuffer()) };
  } catch {
    return { error: null };
  }
}

/** Записи журнала по уровню фильтра: `all` — все, `error`, `warn` — только этот уровень. */
export function filterJournal(entries, level = 'all') {
  const list = Array.isArray(entries) ? entries : [];
  if (level !== 'error' && level !== 'warn') return list;
  return list.filter((entry) => entry && entry.level === level);
}
