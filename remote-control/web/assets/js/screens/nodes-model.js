// Модель экранов нод без DOM — перенос чистой логики `tui/src/nodes.rs`
// (`node_label`, `node_items`, `card_view`, `delete_node`, `add_node_with`,
// `harden`, `aliases`, `offer_upload`, `interactive`): подписи, строки
// контекста, тона действий и argv команд.

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

/** Нода с проблемой: пароль не сохранён при входе по паролю или есть `issues`. */
export function nodeProblem(node) {
  return (node.auth === 'password' && node.password !== 'ok') || list(node.issues).length > 0;
}

/** Пункты списка нод (`nodes.rs::node_items(.., true)`): проблемные — жёлтые. */
export function nodeItems(data) {
  return list(data).map((node) => ({
    name: plain(node.name),
    label: nodeLabel(node),
    tone: nodeProblem(node) ? 'change' : 'view',
  }));
}

/** Действия списка нод (`Nodes::run`): отложенная настройка — только при `ssh_setup_pending`. */
export function listActions(status) {
  const actions = [{ key: 'a', label: 'Добавить ноду', tone: 'create' }];
  if (status && status.ssh_setup_pending === true) {
    actions.push({ key: 'h', label: 'Завершить отложенную SSH-настройку', tone: 'change' });
  }
  return actions;
}

/** Строки контекста карточки (`nodes.rs::card_view`): строка или `{ text, tone }`. */
export function cardContext(node) {
  const lines = [
    `Адрес: ${plain(node.ip)}:${plain(node.port)}`,
    `Пользователь: ${plain(node.user)}`,
  ];
  if (node.auth === 'password') {
    lines.push('Вход: по паролю');
    lines.push(node.password === 'ok'
      ? { text: 'Пароль SSH: сохранён', tone: 'ok' }
      : { text: 'Пароль SSH: нет', tone: 'warn' });
  } else {
    lines.push('Вход: по ключу');
  }
  lines.push(`Тег: ${plain(node.tag)}`);
  const issues = joinedPlain(node.issues);
  if (issues) lines.push({ text: `Требует настройки: ${issues}`, tone: 'warn' });
  const groups = joinedPlain(node.groups);
  lines.push(`Группы: ${groups || 'нет'}`);
  lines.push(`Клиентов: ${plain(node.clients)}`);
  return lines;
}

/** Действия карточки в порядке и с цветами `card_view` (без «Назад»). */
export function cardActions(node) {
  const actions = [
    { key: 'o', label: 'Меню сервера', tone: 'view' },
    { key: 't', label: 'Telegram Proxy на ноде', tone: 'view' },
    { key: 'p', label: 'Подключения ноды', tone: 'view' },
    { key: 'a', label: 'Клиенты AmneziaWG', tone: 'view' },
    { key: 'k', label: 'Проверить подключение', tone: 'view' },
    { key: 'u', label: 'Загрузить скрипты принудительно', tone: 'change' },
    { key: 'h', label: 'Усилить защиту SSH', tone: 'change' },
    { key: 'r', label: 'Переименовать', tone: 'change' },
    { key: 'e', label: 'Тег', tone: 'change' },
  ];
  if (node.auth === 'password') actions.push({ key: 'w', label: 'Пароль SSH', tone: 'change' });
  actions.push({ key: 'l', label: 'Псевдонимы подключений', tone: 'change' });
  actions.push({ key: 'd', label: 'Удалить ноду', tone: 'danger' });
  return actions;
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

/** Подпись вопроса псевдонима (`nodes.rs::aliases`). */
export function aliasPrompt(entry) {
  return `${plain(entry.proxy)} [${plain(entry.alias)}] (- — удалить)`;
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
