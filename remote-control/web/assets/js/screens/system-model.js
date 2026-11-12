// Сводка, настройки, источник конфигурации и мастер GitHub — перенос
// `tui/src/system.rs` (`dashboard_view`, `settings_view`, `Settings`,
// `new_password`) и `tui/src/source.rs` (`source_view`, `Source`,
// `recovery_run`, `provision`, `github_wizard`). Без DOM: диалоги и запросы —
// через `ctx` (`app.js::makeContext`), ссылки для ручных действий — `deps.link`.
import { decisionFlag, setFlag, clearFlag, isFailure } from '../flows.js';
import { versionLabel, syncState, joined, text } from '../format.js';

export const CANCELLED = 'Отменено.';
export const FILE_UNREADABLE = 'Файл недоступен или не в UTF-8.';
export const PASSWORDS_DIFFER = 'Пароли не совпадают.';
export const PASSWORD_EMPTY = 'Пароль не может быть пустым.';

const strings = (value) => (Array.isArray(value) ? value.filter((item) => typeof item === 'string') : []);
const str = (value) => (typeof value === 'string' ? value : '');

/** Сбой после операции; отказ от плана — не сбой (`source.rs::report`). */
export function report(ctx, reply) {
  if (reply && isFailure(reply)) ctx.failed();
}

/** «Отменено.» (`source.rs::cancelled`). */
function cancelled(ctx) {
  ctx.notify('info', CANCELLED);
}

/** Новый пароль дважды (`system.rs::new_password`); `null` — отмена. */
export async function newPassword(ctx, title) {
  const first = await ctx.askSecret({ title, label: 'Новый пароль', allowEmpty: true });
  if (first === null || first === undefined) return null;
  if (first === '') { ctx.notify('warn', PASSWORD_EMPTY); return null; }
  const second = await ctx.askSecret({ title, label: 'Повторите пароль' });
  if (second === null || second === undefined) return null;
  if (first !== second) { ctx.notify('warn', PASSWORDS_DIFFER); return null; }
  return first;
}

// ─── Сводка ────────────────────────────────────────────────────────────────

/**
 * Разделы сводки в порядке и цветах TUI (`dashboard_view`): создание —
 * `create`, операции над конфигурацией — `change`, просмотр — `view`.
 */
export const DASHBOARD_SECTIONS = [
  [
    { route: 'nodes', label: 'Ноды', tone: 'create' },
    { route: 'clients', label: 'Клиенты', tone: 'create' },
    { route: 'groups', label: 'Группы', tone: 'create' },
    { route: 'templates', label: 'Шаблоны', tone: 'create' },
    { route: 'connections', label: 'Подключения', tone: 'change' },
    { route: 'generate', label: 'Генерация конфигов', tone: 'change' },
    { route: 'subscriptions', label: 'Подписки', tone: 'change' },
    { route: 'awg', label: 'AmneziaWG', tone: 'view' },
    { route: 'telegram', label: 'Telegram Proxy', tone: 'view' },
  ],
  [
    { route: 'source', label: 'Источник конфигурации', tone: 'view' },
    { route: 'settings', label: 'Настройки', tone: 'change' },
  ],
];

const count = (value) => (Number.isInteger(value) && value >= 0 ? value : 0);

/**
 * Заголовок и контекст сводки только из `status` (`dashboard_view`).
 * Строка контекста: `{ text, tone?, suffix?: { text, tone } }`. Вместо
 * клавиш разделов TUI («раздел o», «n → h») — названия разделов панели.
 */
export function dashboardView(data, helloVersion = '') {
  const status = data && typeof data === 'object' ? data : {};
  const version = typeof status.version === 'string' ? status.version : str(helloVersion);
  const update = status.update && status.update.available === true
    ? { text: `Доступно обновление ${versionLabel(str(status.update.latest))} — раздел «Настройки»`, tone: 'warn' }
    : null;
  const context = [];
  const source = status.source || {};
  if (source.type === 'github') {
    const sync = syncState(source.sync);
    context.push({ text: `Источник: GitHub ${str(source.repo)} • `, suffix: { text: sync.label, tone: sync.tone } });
  } else {
    context.push({ text: 'Источник: локальная' });
  }
  const counts = status.counts || {};
  context.push({ text: `Ноды: ${count(counts.nodes)}  Клиенты: ${count(counts.clients)}  Группы: ${count(counts.groups)}` });
  const host = str(status.subscription_host);
  context.push(host ? { text: `Хост подписок: ${host}` } : { text: 'Хост подписок не задан', tone: 'dim' });
  const missing = strings(status.password_missing);
  if (missing.length > 0) context.push({ text: `Нет пароля SSH: ${missing.join(', ')}`, tone: 'warn' });
  if (status.ssh_setup_pending === true) {
    context.push({ text: 'Отложена SSH-настройка нод — раздел «Ноды» → «Завершить отложенную SSH-настройку»', tone: 'warn' });
  }
  return { title: `Remote Control ${versionLabel(version)}`, update, context, sections: DASHBOARD_SECTIONS };
}

// ─── Настройки ─────────────────────────────────────────────────────────────

/**
 * Контекст и действия настроек (`settings_view`): `version` — ответ
 * `self version` (один раз за визит), `password` — `status.script_password`.
 */
export function settingsView(version, password) {
  const ok = Boolean(version && version.ok);
  const data = ok && version.data ? version.data : {};
  const available = ok && data.update_available === true;
  const context = [];
  if (ok) {
    context.push({ text: `Версия: ${versionLabel(str(data.current))}` });
    if (data.checked === true) context.push({ text: `Последняя: ${versionLabel(str(data.latest))}` });
    else context.push({ text: 'Не удалось проверить обновления', tone: 'dim' });
  }
  context.push({ text: password ? 'Пароль запуска: установлен' : 'Пароль запуска: не установлен' });
  const actions = [];
  if (available) actions.push({ key: 'u', label: 'Обновить remote-control', tone: 'change' });
  if (password) {
    actions.push({ key: 'l', label: 'Сменить пароль запуска', tone: 'change' });
    actions.push({ key: 'r', label: 'Убрать пароль запуска', tone: 'danger' });
  } else {
    actions.push({ key: 'l', label: 'Установить пароль запуска', tone: 'change' });
  }
  actions.push({ key: 'x', label: 'Удалить remote-control', tone: 'danger' });
  return { context, actions, available };
}

/** Объём удаления → argv `self uninstall` (`Settings`, ключ `x`). */
export function uninstallArgv(scope) {
  const argv = ['self', 'uninstall'];
  if (scope === 'remove') argv.push('--remove-data');
  return argv;
}

/**
 * Действие настроек (`Settings::run`). Возвращает `'update'|'uninstall'`
 * после успешного обновления или удаления (демон перезапускается/исчезает),
 * иначе `null`.
 */
export async function settingsAction(ctx, key, { password, available }) {
  switch (key) {
    case 'u': {
      if (!available) return null;
      const reply = await ctx.runConfirmed('Обновление', 'Обновить remote-control?', ['self', 'update']);
      if (reply.ok) return 'update';
      report(ctx, reply);
      return null;
    }
    case 'l': {
      const secrets = {};
      if (password) {
        const current = await ctx.askSecret({ title: 'Пароль запуска', label: 'Текущий пароль запуска' });
        if (current === null || current === undefined) return null;
        secrets['current-password'] = current;
      }
      const next = await newPassword(ctx, 'Пароль запуска');
      if (next === null) return null;
      secrets.password = next;
      report(ctx, await ctx.request(['self', 'password-set'], { secrets }));
      return null;
    }
    case 'r': {
      if (!password) return null;
      const current = await ctx.askSecret({ title: 'Пароль запуска', label: 'Текущий пароль запуска' });
      if (current === null || current === undefined) return null;
      const reply = await ctx.runConfirmed('Пароль запуска', 'Убрать пароль запуска?', ['self', 'password-remove'],
        { secrets: { 'current-password': current } });
      report(ctx, reply);
      return null;
    }
    case 'x': {
      const scope = await ctx.choose({
        title: 'Удаление remote-control',
        options: [
          { value: 'keep', label: 'Сохранить локальные данные', tone: 'view' },
          { value: 'remove', label: 'Удалить локальные данные', tone: 'view' },
        ],
      });
      if (scope === null || scope === undefined) return null;
      const reply = await ctx.runConfirmed('Удаление remote-control', 'Удалить remote-control в выбранном объёме?', uninstallArgv(scope));
      if (reply.ok) return 'uninstall';
      report(ctx, reply);
      return null;
    }
    default:
      return null;
  }
}

/**
 * Блок «Демон» из `daemon status`: версия, клиенты, открытые терминалы,
 * адрес панели, отпечаток сертификата. Отсутствующее значение — «—».
 */
export function daemonLines(data) {
  const status = data && typeof data === 'object' ? data : {};
  const web = status.web && typeof status.web === 'object' ? status.web : {};
  return [
    { label: 'Версия', value: typeof status.version === 'string' && status.version ? versionLabel(status.version) : '—' },
    { label: 'Клиенты', value: Array.isArray(status.clients) ? String(status.clients.length) : '—' },
    { label: 'Открытые терминалы', value: Array.isArray(status.terminals) ? joined(strings(status.terminals)) : '—' },
    { label: 'Адрес панели', value: text(web.url) },
    { label: 'Отпечаток сертификата', value: text(web.fingerprint) },
  ];
}

// ─── Источник конфигурации ─────────────────────────────────────────────────

/** Контекст и группы действий экрана источника (`source_view`). */
export function sourceView(data) {
  const status = data && typeof data === 'object' ? data : {};
  const github = status.type === 'github';
  const encrypted = github && status.storage === 'age';
  const context = [];
  const sections = [];
  if (github) {
    context.push({ text: `GitHub: ${str(status.repo)}` });
    context.push({ text: `Ветка: ${str(status.branch)}` });
    context.push({ text: encrypted ? 'Хранение: зашифровано' : 'Хранение: без шифрования' });
    const sync = syncState(status.sync);
    context.push({ text: 'Синхронизация: ', suffix: { text: sync.label, tone: sync.tone } });
    const sync_ = [
      { key: 'f', label: 'Загрузить из GitHub', tone: 'change' },
      { key: 'p', label: 'Отправить в GitHub', tone: 'change' },
      { key: 'c', label: 'Сменить аккаунт', tone: 'change' },
    ];
    if (encrypted) {
      sync_.push(
        { key: 'r', label: 'Сменить пароль доступа', tone: 'change' },
        { key: 'v', label: 'Новый ключ шифрования', tone: 'danger' },
        { key: 'k', label: 'Импортировать ключ восстановления', tone: 'change' },
      );
    }
    sections.push(sync_);
    sections.push([
      { key: 'e', label: 'Работать локально без синхронизации', tone: 'change' },
      { key: 'l', label: 'Заменить GitHub локальной конфигурацией', tone: 'danger' },
      { key: 'd', label: 'Удалить репозиторий', tone: 'danger' },
    ]);
  } else {
    context.push({ text: 'Источник: локальная' });
    sections.push([{ key: 'g', label: 'Подключить GitHub', tone: 'create' }]);
  }
  return { github, encrypted, context, sections };
}

/** Ссылка для ручного действия (`source.rs::manual_link`). */
function manualLink(deps, value, label) {
  const url = str(value);
  if (url && deps && deps.link) return deps.link(label, url);
  return undefined;
}

/** `key_provisioning_required{nodes}` → `--provision-keys yes|no` (`source.rs::provision`). */
async function provision(ctx, reply, argv) {
  const nodes = strings(reply.error && reply.error.nodes);
  const yes = await ctx.confirm({
    title: 'Переносимый SSH-ключ',
    context: [`Ноды: ${nodes.join(', ')}`],
    question: 'Создать переносимый SSH-ключ для этих нод?',
    tone: 'create',
  });
  setFlag(argv, decisionFlag('key_provisioning_required'), yes ? 'yes' : 'no');
}

/**
 * Команды восстановления под планом (`source.rs::recovery_run`): свой пароль
 * запуска, пароль хранилища, решение о переносимом ключе. `null` — отмена
 * ввода пароля. `secrets` накапливается между попытками.
 */
export async function recoveryRun(ctx, title, question, verb, secrets = {}) {
  const argv = ['source', verb];
  let scriptTries = 0;
  let vaultTries = 0;
  for (;;) {
    const reply = await ctx.runConfirmed(title, question, argv, { secrets });
    if (reply.ok) return reply;
    const code = reply.error ? reply.error.code : null;
    if ((code === 'auth_required' || code === 'auth_failed') && scriptTries < 3) {
      scriptTries += 1;
      const password = await ctx.askSecret({ title, label: 'Введите пароль' });
      if (password === null || password === undefined) return null;
      secrets['script-password'] = password;
    } else if ((code === 'vault_password_required' || code === 'vault_password_invalid') && vaultTries < 3) {
      vaultTries += 1;
      const password = await ctx.askSecret({ title, label: 'Пароль доступа к конфигурации GitHub' });
      if (password === null || password === undefined) return null;
      secrets['vault-password'] = password;
    } else if (code === 'key_provisioning_required') {
      await provision(ctx, reply, argv);
    } else {
      return reply;
    }
  }
}

/** Импорт ключа восстановления: текст файла → `input.file` (ключ `k`). */
export async function importRecoveryKey(ctx, fileText) {
  if (typeof fileText !== 'string') { ctx.notify('warn', FILE_UNREADABLE); return null; }
  const reply = await ctx.request(['source', 'github-import-recovery-key'], { input: { file: fileText } });
  report(ctx, reply);
  return reply;
}

/**
 * Действие экрана источника (`Source::run`), кроме `k` (файл выбирается в
 * браузере → `importRecoveryKey`). `deps.link(label, url)` — показ ссылки.
 */
export async function sourceAction(ctx, key, data, deps = {}) {
  const { github, encrypted } = sourceView(data);
  if (!github) {
    if (key === 'g') await ctx.wizard('connect');
    return;
  }
  switch (key) {
    case 'f': report(ctx, await ctx.request(['source', 'github-fetch'])); return;
    case 'p': report(ctx, await ctx.request(['source', 'github-push'])); return;
    case 'c': await ctx.wizard('change'); return;
    case 'r': {
      if (!encrypted) return;
      const current = await ctx.askSecret({ title: 'Смена пароля доступа', label: 'Текущий пароль доступа' });
      if (current === null || current === undefined) return;
      const next = await newPassword(ctx, 'Смена пароля доступа');
      if (next === null) return;
      const secrets = { 'vault-password': current, 'new-vault-password': next };
      report(ctx, await ctx.request(['source', 'github-rewrap-password'], { secrets }));
      return;
    }
    case 'v': {
      if (!encrypted) return;
      const next = await newPassword(ctx, 'Новый ключ шифрования');
      if (next === null) return;
      const reply = await ctx.runConfirmed('Новый ключ шифрования', 'Создать новый ключ?', ['source', 'github-rotate-key'],
        { secrets: { 'new-vault-password': next } });
      report(ctx, reply);
      return;
    }
    case 'e': report(ctx, await ctx.request(['source', 'github-switch-local'])); return;
    case 'l': {
      const reply = await recoveryRun(ctx, 'Замена конфигурации GitHub', 'Заменить конфигурацию в GitHub?', 'github-replace-with-local', {});
      if (reply) report(ctx, reply);
      return;
    }
    case 'd': {
      const reply = await ctx.runConfirmed('Удаление репозитория', 'Удалить репозиторий?', ['source', 'github-delete-repo']);
      if (!reply.ok) await manualLink(deps, reply.error && reply.error.settings_url, 'Удалите репозиторий вручную');
      report(ctx, reply);
      return;
    }
    default:
  }
}

// ─── Мастер GitHub ─────────────────────────────────────────────────────────

/** Команда и заголовок мастера: `connect` (первый запуск) или `change`. */
export function wizardMode(mode) {
  return mode === 'change'
    ? { change: true, verb: 'github-change-account', title: 'Смена аккаунта GitHub' }
    : { change: false, verb: 'github-connect', title: 'Подключение GitHub' };
}

/** Сохранённые аккаунты и глобальный вход `gh` без повторов. */
export function wizardAccounts(data) {
  const accounts = strings(data && data.accounts);
  const global = str(data && data.global_login);
  if (global && !accounts.includes(global)) accounts.push(global);
  return accounts;
}

export const OTHER_LOGIN = 'Указать другой логин';

/** Подпись режима хранения из `storage_mode_required.choices`. */
export function storageLabel(choice) {
  if (choice === 'age') return 'Зашифровать паролем (age)';
  if (choice === 'none') return 'Без шифрования';
  return choice;
}

/** Подпись решения из `existing_config_action_required.choices`. */
export function existingLabel(choice, error = {}) {
  if (choice === 'remote') {
    const counts = error.remote_counts;
    const detail = counts && typeof counts === 'object' && !Array.isArray(counts)
      ? `ноды ${text(counts.nodes)}, клиенты ${text(counts.clients)}`
      : 'состав неизвестен';
    return `Использовать конфигурацию из GitHub (${detail})`;
  }
  if (choice === 'local') return 'Заменить её конфигурацией с этого устройства';
  if (choice === 'migrate') return 'Преобразовать конфигурацию из GitHub';
  return choice;
}

/** Контекст вопроса `target_replace_required` (чужие файлы в репозитории). */
export function targetReplaceContext(error = {}) {
  const lines = [`Репозиторий ${str(error.repo)} не содержит конфигурации Remote Control 2.`];
  const reason = str(error.reason);
  if (reason) lines.push(`Причина: ${reason}`);
  lines.push(`Файлов в репозитории: ${text(error.tracked_files)}; после замены они останутся только в истории Git.`);
  return lines;
}

/** Выбор из `choices` ответа: значение или `null` при отмене. */
async function chooseChoice(ctx, title, choices, label) {
  const index = await ctx.choose({
    title,
    options: choices.map((choice, position) => ({ value: position, label: label(choice), tone: 'view' })),
    cancel: 'Отмена',
  });
  return index === null || index === undefined ? null : choices[index];
}

/**
 * Мастер GitHub (`source.rs::github_wizard`). `true` — команда выполнена.
 * Отказ на любом шаге → «Отменено.», дальнейших вызовов нет. Вход в GitHub
 * (`github-login`) идёт в окне операции: код устройства и адрес — строками
 * журнала `output`.
 */
export async function githubWizardFlow(ctx, mode, deps = {}) {
  const { change, verb, title } = wizardMode(mode);
  const list = await ctx.request(['source', 'github-accounts']);
  if (!list.ok) { ctx.failed(); return false; }
  const accounts = wizardAccounts(list.data);
  const picked = await ctx.choose({
    title: 'Аккаунт GitHub',
    options: [
      ...accounts.map((account, index) => ({ value: index, label: account, tone: 'view' })),
      { value: accounts.length, label: OTHER_LOGIN, tone: 'view' },
    ],
  });
  if (picked === null || picked === undefined) { cancelled(ctx); return false; }
  let login;
  if (picked === accounts.length) {
    const typed = await ctx.ask({ title: 'Аккаунт GitHub', label: 'Логин GitHub' });
    // Логин уходит как введён (`source.rs::github_wizard`); пустой — отмена.
    login = typeof typed === 'string' ? typed : '';
    if (!login) { cancelled(ctx); return false; }
  } else {
    login = accounts[picked];
  }
  const argv = ['source', verb, '--login', login];
  const secrets = {};
  let vaultTries = 0;
  for (;;) {
    const reply = await ctx.runConfirmed(title, 'Выполнить?', argv, { secrets });
    if (reply.ok) {
      if (change) await manualLink(deps, reply.data && reply.data.old_repo_settings_url, 'Прежний репозиторий можно удалить вручную');
      return true;
    }
    const error = reply.error || {};
    const code = error.code;
    let decided;
    switch (code) {
      case 'github_auth_required': {
        decided = await ctx.confirm({ title: 'Вход в GitHub', question: 'Войти в GitHub через браузер сейчас?', yes: 'Войти', tone: 'view' });
        if (decided) {
          const auth = await ctx.request(['source', 'github-login', '--login', login], { operation: 'Вход в GitHub' });
          if (!auth.ok) { ctx.failed(); return false; }
        }
        break;
      }
      case 'repo_create_required':
        decided = await ctx.confirm({ title: 'Создание репозитория', question: `Создать приватный репозиторий ${str(error.repo)}?`, tone: 'create' });
        if (decided) setFlag(argv, decisionFlag(code));
        break;
      // Приватность подтверждается один раз — планом ядра.
      case 'repo_private_required':
        setFlag(argv, decisionFlag(code));
        decided = true;
        break;
      // Чужие файлы: сначала причина; само удаление ещё раз — в плане ядра.
      case 'target_replace_required':
        decided = await ctx.confirm({
          title: 'Репозиторий GitHub',
          context: targetReplaceContext(error),
          question: 'Заменить их конфигурацией этого устройства?',
          tone: 'danger',
        });
        if (decided) setFlag(argv, decisionFlag(code));
        break;
      case 'storage_mode_required': {
        const choice = await chooseChoice(ctx, 'Хранение конфигурации GitHub', strings(error.choices), storageLabel);
        decided = choice !== null;
        if (decided) setFlag(argv, decisionFlag(code), choice);
        break;
      }
      case 'new_vault_password_required': {
        const password = await newPassword(ctx, title);
        decided = password !== null;
        if (decided) secrets['new-vault-password'] = password;
        break;
      }
      case 'existing_config_action_required': {
        const choice = await chooseChoice(ctx, 'Конфигурация в GitHub', strings(error.choices), (item) => existingLabel(item, error));
        decided = choice !== null;
        if (decided) setFlag(argv, decisionFlag(code), choice);
        break;
      }
      case 'vault_password_required':
      case 'vault_password_invalid': {
        if (vaultTries >= 3) { report(ctx, reply); return false; }
        vaultTries += 1;
        const password = await ctx.askSecret({ title, label: 'Пароль доступа к конфигурации GitHub' });
        decided = password !== null && password !== undefined;
        if (decided) {
          secrets['vault-password'] = password;
          if (!change) {
            const remember = await ctx.confirm({ title: 'Ключ расшифровки', question: 'Сохранить ключ расшифровки на этом устройстве?' });
            if (remember) setFlag(argv, '--remember-key');
            else clearFlag(argv, '--remember-key');
          }
        }
        break;
      }
      case 'key_provisioning_required':
        await provision(ctx, reply, argv);
        decided = true;
        break;
      case 'cache_skip_required':
        decided = await ctx.confirm({ title: 'Локальный кэш', question: 'Продолжить смену аккаунта без локального кэша?' });
        if (decided) setFlag(argv, decisionFlag(code));
        break;
      default:
        report(ctx, reply);
        return false;
    }
    if (!decided) { cancelled(ctx); return false; }
  }
}
