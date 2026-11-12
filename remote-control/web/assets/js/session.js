// Вход в панель (план 2.5 «Вход», порядок по поправке П4: `session open`
// выполняется до экранов первого запуска и восстановления). Чистые функции
// над переданным соединением; хранилище и окно — параметрами.

export const REMEMBER_FLAG = '--remember-key';

/** Точка входа после `hello`: экран, который нужно показать. */
export function routeReply(reply) {
  if (!reply || reply.ok) return 'open';
  const error = reply.error || {};
  switch (error.code) {
    case 'auth_required':
    case 'auth_failed':
      // `system.rs::open_session`: любой `auth_*` — пароль запуска, кроме кода доступа.
      return error.secret === 'access-token' ? 'access-code' : 'script-password';
    case 'vault_password_required':
    case 'vault_password_invalid':
      return 'vault-password';
    case 'not_configured':
      return 'first-run';
    case 'github_format_outdated':
    case 'github_format_newer':
    case 'github_format_invalid':
      return 'recovery';
    default:
      return 'retry';
  }
}

/**
 * `session open` с секретами формы. `access-token` — одноразовый код из
 * ссылки (`ticket`, передаётся один раз: демон гасит его при первом
 * предъявлении) либо токен возобновления `connection.resume` (обновляется
 * событием `access`). Отклонённый токен возобновления стирается, и вход
 * повторяется без него: демон сам скажет, нужен ли пароль или код доступа.
 * `remember` добавляет `--remember-key`.
 */
export async function openSession(connection, { secrets = {}, remember = false, ticket = null } = {}) {
  const argv = ['session', 'open'];
  if (remember) argv.push(REMEMBER_FLAG);
  const token = ticket || connection.resume;
  const reply = await connection.request(argv, { secrets: token ? { ...secrets, 'access-token': token } : { ...secrets } });
  const rejected = !reply.ok && reply.error && reply.error.code === 'auth_failed' && reply.error.secret === 'access-token';
  if (rejected && !ticket && token) {
    connection.forget();
    return connection.request(argv, { secrets: { ...secrets } });
  }
  return reply;
}

/**
 * Первый запуск: «Создать локальную конфигурацию» (`source init-local`).
 * Возвращает ответ команды.
 */
export function initLocal(connection) {
  return connection.request(['source', 'init-local'], {});
}

/** Варианты экрана восстановления (`system.rs::github_recovery`). */
export function recoveryOptions(code) {
  const outdated = code === 'github_format_outdated';
  const newer = code === 'github_format_newer';
  const options = [];
  if (outdated) options.push({ id: 'migrate', label: 'Преобразовать конфигурацию', verb: 'github-migrate-format', title: 'Преобразование конфигурации GitHub', question: 'Преобразовать и опубликовать конфигурацию?', tone: 'change' });
  if (!newer) options.push({ id: 'replace', label: 'Заменить конфигурацией с этого устройства', verb: 'github-replace-with-local', title: 'Замена конфигурации GitHub', question: 'Заменить конфигурацию в GitHub?', tone: 'danger' });
  return options;
}
