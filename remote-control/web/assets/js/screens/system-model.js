// Сводка, настройки, источник конфигурации и мастер GitHub — перенос
// `tui/src/system.rs` (`dashboard_view`, `settings_view`, `Settings`,
// `new_password`) и `tui/src/source.rs` (`source_view`, `Source`,
// `recovery_run`, `provision`, `github_wizard`). Без DOM: диалоги и запросы —
// через `ctx` (`app.js::makeContext`), ссылки для ручных действий — `deps.link`.
import { decisionFlag, setFlag, clearFlag, isFailure } from '../flows.js';
import { versionLabel, syncState, joined, text, openPanel, OPEN_PANEL_WARNING, strings } from '../format.js';
import { validate } from '../form-model.js';

export const CANCELLED = 'Отменено.';
export const FILE_UNREADABLE = 'Файл недоступен или не в UTF-8.';
export const PASSWORDS_DIFFER = 'Пароли не совпадают.';
export const PASSWORD_EMPTY = 'Пароль не может быть пустым.';

const str = (value) => (typeof value === 'string' ? value : '');

/** Сбой после операции; отказ от плана — не сбой (`source.rs::report`). */
export function report(ctx, reply) {
  if (reply && isFailure(reply)) ctx.failed();
}

/** «Отменено.» (`source.rs::cancelled`). */
function cancelled(ctx) {
  ctx.notify('info', CANCELLED);
}

/**
 * Новый пароль дважды одной формой (`system.rs::new_password`); с
 * `current` — ещё и текущий пароль. `{ current, password }` или `null` при
 * отмене. Значения уходят только в `secrets` вызывающего.
 */
export async function passwordForm(ctx, title, { current = false, currentLabel = 'Текущий пароль' } = {}) {
  const fields = [
    ...(current ? [{ name: 'current', label: currentLabel, type: 'secret', required: true }] : []),
    { name: 'password', label: 'Новый пароль', type: 'secret', required: PASSWORD_EMPTY },
    {
      name: 'repeat', label: 'Повторите пароль', type: 'secret',
      validate: (value, values) => (value === values.password ? null : PASSWORDS_DIFFER),
    },
  ];
  const values = await ctx.form({ title, fields, submit: 'Сохранить' });
  if (values === null || values === undefined) return null;
  // Форма проверяет поля сама; повторная проверка не пропускает неверный ввод.
  const errors = Object.values(validate(fields, values));
  if (errors.length > 0) { ctx.notify('warn', errors[0]); return null; }
  return { current: current ? values.current : null, password: values.password };
}

// ─── Сводка ────────────────────────────────────────────────────────────────

/**
 * «Требует внимания» на сводке из `status` и `hello`: `[{ id, tone, text,
 * action }]`; `action` — `{ label, type: 'password'|'ssh-setup'|'route',
 * node?, route?, param?, tab? }` (экран выполняет действие по `type`).
 * Третий аргумент — ответы `group list` и `node list` (`null`, если не
 * прочитаны): группы без нод и ноды, чьи подключения не назначены ни одной группе.
 */
export function attentionItems(status, hello, { groups = null, nodes = null } = {}) {
  const data = status && typeof status === 'object' ? status : {};
  const items = [];
  for (const node of strings(data.password_missing)) {
    items.push({
      id: `password:${node}`, tone: 'warn', text: `Нода «${node}»: пароль SSH не сохранён`,
      action: { label: 'Задать пароль', type: 'password', node },
    });
  }
  if (data.ssh_setup_pending === true) {
    items.push({
      id: 'ssh-setup', tone: 'warn', text: 'Отложена SSH-настройка нод',
      action: { label: 'Завершить настройку', type: 'ssh-setup' },
    });
  }
  if (!str(data.subscription_host)) {
    items.push({
      id: 'subscription-host', tone: 'info', text: 'Хост-нода подписок не задана',
      action: { label: 'Выбрать хост', type: 'route', route: 'subscriptions' },
    });
  }
  const source = data.source || {};
  if (source.type === 'github') {
    const sync = syncState(source.sync);
    if (sync.tone === 'warn' || sync.tone === 'error') {
      items.push({
        id: 'sync', tone: sync.tone, text: `Источник GitHub: ${sync.label}`,
        action: { label: 'Источник', type: 'route', route: 'source' },
      });
    }
  }
  if (data.update && data.update.available === true) {
    items.push({
      id: 'update', tone: 'info', text: `Доступно обновление ${versionLabel(str(data.update.latest))}`,
      action: { label: 'Настройки', type: 'route', route: 'settings' },
    });
  }
  if (openPanel(hello, data, null)) {
    items.push({
      id: 'open-panel', tone: 'warn', text: OPEN_PANEL_WARNING,
      action: { label: 'Настройки', type: 'route', route: 'settings' },
    });
  }
  if (Array.isArray(groups)) {
    const nodeNames = Array.isArray(nodes) ? nodes.map((node) => str(node && node.name)).filter(Boolean) : [];
    for (const group of groups) {
      const name = str(group && group.name);
      if (!name || strings(group.nodes).length > 0) continue;
      const clients = Number.isInteger(group.clients) ? group.clients : 0;
      // Назначение — на вкладке подключений ноды; единственная нода открывается сразу.
      const only = nodeNames.length === 1 ? nodeNames[0] : null;
      items.push({
        id: `group-nodes:${name}`, tone: clients > 0 ? 'warn' : 'info',
        text: clients > 0
          ? `Группа «${name}»: нет нод — клиенты группы (${clients}) получат конфиг без подключений`
          : `Группа «${name}»: нет нод`,
        action: only
          ? { label: 'Назначить подключения', type: 'route', route: 'nodes', param: only, tab: 'connections' }
          : { label: 'Ноды', type: 'route', route: 'nodes' },
      });
    }
    if (Array.isArray(nodes)) {
      const used = new Set(groups.flatMap((group) => strings(group && group.nodes)));
      for (const name of nodeNames) {
        if (used.has(name)) continue;
        items.push({
          id: `node-groups:${name}`, tone: 'info', text: `Нода «${name}»: подключения не назначены ни одной группе`,
          action: { label: 'Назначить подключения', type: 'route', route: 'nodes', param: name, tab: 'connections' },
        });
      }
    }
  }
  return items;
}

/** Заголовок сводки (`dashboard_view`): версия из `status`, иначе из `hello`. */
export function dashboardTitle(data, helloVersion = '') {
  const status = data && typeof data === 'object' ? data : {};
  const version = typeof status.version === 'string' ? status.version : str(helloVersion);
  return `Remote Control ${versionLabel(version)}`;
}

// ─── Настройки ─────────────────────────────────────────────────────────────

/** Обновление доступно по ответу `self version` (`settings_view`). */
export function updateAvailable(version) {
  return Boolean(version && version.ok && version.data && version.data.update_available === true);
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
      const form = await passwordForm(ctx, 'Пароль запуска', { current: Boolean(password), currentLabel: 'Текущий пароль запуска' });
      if (form === null) return null;
      const secrets = {};
      if (password) secrets['current-password'] = form.current;
      secrets.password = form.password;
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
      const values = await ctx.form({
        title: 'Удаление remote-control',
        fields: [{
          name: 'scope', label: 'Локальные данные', type: 'radio', required: 'Выберите объём удаления.',
          options: [
            { value: 'keep', label: 'Сохранить локальные данные' },
            { value: 'remove', label: 'Удалить локальные данные' },
          ],
        }],
        submit: 'Далее',
        tone: 'danger',
      });
      if (values === null || values === undefined || !values.scope) return null;
      const scope = values.scope;
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

/**
 * Режим и клавиши действий экрана источника (`source_view`): GitHub —
 * синхронизация, смена аккаунта, при шифровании пароль, ключ и импорт ключа
 * восстановления, затем отключение и опасные действия; локальный — только `g`.
 */
export function sourceView(data) {
  const status = data && typeof data === 'object' ? data : {};
  const github = status.type === 'github';
  const encrypted = github && status.storage === 'age';
  if (!github) return { github, encrypted, keys: ['g'] };
  return { github, encrypted, keys: ['f', 'p', 'c', ...(encrypted ? ['r', 'v', 'k'] : []), 'e', 'l', 'd'] };
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

/** Импорт ключа восстановления: текст файла → `input.file` (ключ `k`); `reason` — отказ чтения. */
export async function importRecoveryKey(ctx, fileText, reason = null) {
  if (typeof fileText !== 'string') { ctx.notify('warn', reason || FILE_UNREADABLE); return null; }
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
      const form = await passwordForm(ctx, 'Смена пароля доступа', { current: true, currentLabel: 'Текущий пароль доступа' });
      if (form === null) return;
      const secrets = { 'vault-password': form.current, 'new-vault-password': form.password };
      report(ctx, await ctx.request(['source', 'github-rewrap-password'], { secrets }));
      return;
    }
    case 'v': {
      if (!encrypted) return;
      const form = await passwordForm(ctx, 'Новый ключ шифрования');
      if (form === null) return;
      const reply = await ctx.runConfirmed('Новый ключ шифрования', 'Создать новый ключ?', ['source', 'github-rotate-key'],
        { secrets: { 'new-vault-password': form.password } });
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
    options: choices.map((choice, position) => ({ value: position, label: label(choice) })),
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
      ...accounts.map((account, index) => ({ value: index, label: account })),
      { value: accounts.length, label: OTHER_LOGIN },
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
        decided = await ctx.confirm({ title: 'Вход в GitHub', question: 'Войти в GitHub через браузер сейчас?', yes: 'Войти' });
        if (decided) {
          const auth = await ctx.request(['source', 'github-login', '--login', login], { operation: 'Вход в GitHub' });
          if (!auth.ok) { ctx.failed(); return false; }
        }
        break;
      }
      case 'repo_create_required':
        decided = await ctx.confirm({ title: 'Создание репозитория', question: `Создать приватный репозиторий ${str(error.repo)}?` });
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
        const form = await passwordForm(ctx, title);
        decided = form !== null;
        if (decided) secrets['new-vault-password'] = form.password;
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
