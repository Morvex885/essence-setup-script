// Модель экранов нод без DOM — перенос чистой логики `tui/src/nodes.rs`
// (`node_label`, `card_view`, `delete_node`, `add_node_with`, `harden`,
// `aliases`, `offer_upload`, `interactive`): подписи, состояния и argv команд.

/** Строковое значение поля (`nodes.rs::text`): `null`/`undefined` → ''. */
export function plain(value) {
  if (value === null || value === undefined) return '';
  if (typeof value === 'string') return value;
  return typeof value === 'object' ? JSON.stringify(value) : String(value);
}

function list(value) {
  return Array.isArray(value) ? value : [];
}

/** Список через запятую (`nodes.rs::joined`); пустой → ''. */
export function joinedPlain(value) {
  return list(value).map(plain).join(', ');
}

/** «имя  ip:порт» (`nodes.rs::node_label`). */
export function nodeLabel(node) {
  return `${plain(node.name)}  ${plain(node.ip)}:${plain(node.port)}`;
}

/** Состояние ноды для списка: `{ tone, label }` — нет пароля SSH, `issues` или «готова». */
export function nodeStatus(node) {
  if (node.auth === 'password' && node.password !== 'ok') return { tone: 'warn', label: 'нет пароля SSH' };
  const issues = joinedPlain(node.issues);
  if (issues) return { tone: 'warn', label: issues };
  return { tone: 'ok', label: 'готова' };
}

/** Способ входа (`nodes.rs::card_view`). */
export function authLabel(node) {
  return node.auth === 'password' ? 'по паролю' : 'по ключу';
}

/** Отметка пароля SSH карточки: только при входе по паролю, иначе `null`. */
export function passwordStatus(node) {
  if (node.auth !== 'password') return null;
  return node.password === 'ok' ? { tone: 'ok', label: 'сохранён' } : { tone: 'warn', label: 'нет' };
}

/** `node shell` / `telegram menu` (`nodes.rs::interactive`). */
export function interactiveArgv(name, telegram) {
  return telegram ? ['telegram', 'menu', '--name', name] : ['node', 'shell', '--name', name];
}

/** Предложение загрузки скриптов по состоянию (`nodes.rs::offer_upload`). */
export function uploadOffer(name, state) {
  const force = state === 'broken' || state === 'unknown';
  const conditions = {
    missing: 'скрипты отсутствуют',
    outdated: 'скрипты устарели',
    broken: 'установка повреждена',
  };
  const argv = ['node', 'upload-scripts', '--name', name];
  if (force) argv.push('--force');
  return {
    force,
    title: `Скрипты на ноде: ${name}`,
    condition: `Состояние: ${conditions[state] || 'версия скриптов неизвестна'}`,
    label: force ? 'Загрузить скрипты принудительно' : 'Загрузить скрипты',
    argv,
  };
}

/** Варианты удаления из `node show .delete_options[]` (`nodes.rs::delete_node`). */
export function deleteOptions(node) {
  return list(node.delete_options).map((option, index) => ({ value: index, label: plain(option.label), tone: 'danger' }));
}

/** argv удаления в выбранном объёме; `--revoke-key` — только при `revoke_key: true`. */
export function deleteArgv(name, option) {
  const argv = ['node', 'delete', '--name', name, '--scope', plain(option.scope)];
  if (option.revoke_key === true) argv.push('--revoke-key');
  return argv;
}

/** argv усиления SSH (`nodes.rs::harden`): пустой порт — ядро подбирает свободный. */
export function hardenArgv(name, port) {
  const argv = ['node', 'harden', '--name', name];
  if (port) argv.push('--port', port);
  return argv;
}

/** Повторный вопрос порта: `port_in_use` или `invalid` при явном `--port`. */
export function hardenAsksPort(argv, reply) {
  const code = reply && reply.error ? reply.error.code : null;
  return code === 'port_in_use' || (argv.includes('--port') && code === 'invalid');
}

/**
 * Проверка формы добавления (`nodes.rs::add_node_with`) с умолчаниями v1.
 * Возвращает `{ warning }` либо `{ argv, password }`; пароль идёт только в
 * `secrets`, в argv его нет.
 */
export function addNodeArgv(form) {
  const name = form.name || 'vps-1';
  const ip = form.ip || '';
  if (!ip) return { warning: 'IP не указан.' };
  const port = form.port || '22';
  if (!/^[0-9]+$/.test(port) || Number(port) < 1 || Number(port) > 65535) {
    return { warning: 'Порт должен быть числом от 1 до 65535.' };
  }
  const user = form.user || 'root';
  const password = form.auth === 'password';
  if (password && !form.password) return { warning: 'Пароль не может быть пустым.' };
  if (!form.tag) return { warning: 'Тег не может быть пустым.' };
  return {
    argv: ['node', 'add', '--name', name, '--ip', ip, '--port', port, '--user', user,
      '--auth', password ? 'password' : 'key', '--tag', form.tag],
    password: password ? form.password : null,
  };
}

/**
 * Попытка добавления: отложенная настройка не проверяет ключ сервера
 * (`--defer-ssh-setup`), иначе — флаги ключа (`--accept-new-host-key` или
 * `--replace-host-key <отпечаток>`).
 */
export function addAttemptArgv(base, hostKey, defer) {
  return defer ? [...base, '--defer-ssh-setup'] : [...base, ...hostKey];
}

/** Первые флаги ключа сервера при добавлении. */
export const ACCEPT_HOST_KEY = ['--accept-new-host-key'];

/**
 * Ответы формы псевдонимов (`a<индекс>` — новое значение) в значения
 * `aliasArgv`: без изменений → `''`, очищенный → `-`, иначе новое значение.
 */
export function aliasValues(entries, form) {
  return list(entries).map((entry, index) => {
    const current = plain(entry.alias);
    const value = plain(form && form[`a${index}`]);
    if (value === current) return '';
    if (value === '') return '-';
    return value;
  });
}

/**
 * argv записи псевдонимов по ответам (`''` — без изменений, `-` — удалить);
 * `null`, если изменений нет.
 */
export function aliasArgv(name, entries, values) {
  const sets = [];
  const unsets = [];
  list(entries).forEach((entry, index) => {
    const proxy = plain(entry.proxy);
    const current = plain(entry.alias);
    const value = values[index] || '';
    if (value === '-') {
      if (current) unsets.push('--unset', proxy);
    } else if (value && value !== current) {
      sets.push('--set', `${proxy}=${value}`);
    }
  });
  if (sets.length === 0 && unsets.length === 0) return null;
  return ['node', 'aliases', '--name', name, ...sets, ...unsets];
}
