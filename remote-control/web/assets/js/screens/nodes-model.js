// Модель экранов нод без DOM — перенос логики `tui/src/nodes.rs`
// (`node_label`, `card_view`, `delete_node`, `add_node_with`, `harden`,
// `aliases`, `offer_upload`, `interactive`): подписи, состояния, argv команд
// и потоки добавления и изменения ноды поверх `ctx` (`app.js::makeContext`).
import { handleNodeCodes, reviewReply, setFlag, decisionFlag } from '../flows.js';
import { asList, errorMessage } from '../format.js';

/** Строковое значение поля (`nodes.rs::text`): `null`/`undefined` → ''. */
export function plain(value) {
  if (value === null || value === undefined) return '';
  if (typeof value === 'string') return value;
  return typeof value === 'object' ? JSON.stringify(value) : String(value);
}

/** Список через запятую (`nodes.rs::joined`); пустой → ''. */
export function joinedPlain(value) {
  return asList(value).map(plain).join(', ');
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
  return asList(node.delete_options).map((option, index) => ({ value: index, label: plain(option.label) }));
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

export const PORT_INVALID = 'Порт должен быть числом от 1 до 65535.';

/** Проверка SSH-порта: пусто — умолчание 22; иначе число 1…65535. Текст ошибки или `null`. */
export function portError(value) {
  const port = plain(value);
  if (port === '') return null;
  return /^[0-9]+$/.test(port) && Number(port) >= 1 && Number(port) <= 65535 ? null : PORT_INVALID;
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
  if (portError(form.port)) return { warning: PORT_INVALID };
  const port = form.port || '22';
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

export const ADD_TITLE = 'Добавление ноды';

/** Отказ от плана — не сбой (`nodes.rs::outcome`); сбой — итог «Операция завершилась ошибкой». */
function outcome(ctx, reply) {
  if (ctx.isFailure(reply)) ctx.failed();
}

const errorCode = (reply) => (reply && reply.error ? reply.error.code : null);

/**
 * Попытки `node add` (`nodes.rs::add_node_with`): первый ключ сервера
 * принимается, изменённый заменяется только через план, `remote_failed` —
 * повтор с согласия (и, при входе по паролю, с новым паролем),
 * `onboarding_failed` — повтор или отложенная настройка. Итог:
 * `{ status: 'ok', name }`, `{ status: 'failed' }` (сбой или отказ от
 * повтора — форму стоит показать снова) или `{ status: 'cancel' }`.
 */
export async function addNode(ctx, base, password) {
  const secrets = password ? { password } : undefined;
  let hostKey = [...ACCEPT_HOST_KEY];
  let defer = false;
  for (;;) {
    const words = addAttemptArgv(base, hostKey, defer);
    const reply = !defer && hostKey[0] === '--replace-host-key'
      ? await ctx.runConfirmed('Ключ сервера изменился', 'Обновить ключ ноды?', words, { secrets })
      : await ctx.request(words, { secrets });
    if (reply.ok) {
      if (reply.data && reply.data.needs_setup === true) {
        ctx.notify('warn', 'Нода сохранена, но требует SSH-настройки: раздел «Ноды» → «Завершить SSH-настройку».');
      }
      const saved = reply.data && typeof reply.data.name === 'string' && reply.data.name ? reply.data.name : base[3];
      return { status: 'ok', name: saved };
    }
    switch (errorCode(reply)) {
      case 'host_key_changed': {
        if (defer) { outcome(ctx, reply); return { status: 'failed' }; }
        const fingerprint = asList(reply.error.fingerprints)[0];
        if (typeof fingerprint !== 'string') { ctx.failed(); return { status: 'failed' }; }
        hostKey = ['--replace-host-key', fingerprint];
        break;
      }
      case 'remote_failed': {
        // Отказ от повтора — к форме с прежним вводом (исправить адрес или порт).
        if (!(await ctx.confirm({ title: ADD_TITLE, question: 'Повторить попытку?' }))) return { status: 'failed' };
        if (secrets) {
          const value = await ctx.askSecret({ title: ADD_TITLE, label: 'Новый пароль (пусто — прежний)', allowEmpty: true });
          if (value === null) return { status: 'cancel' };
          if (value) secrets.password = value;
        }
        break;
      }
      case 'onboarding_failed': {
        const choice = await ctx.choose({
          title: 'Не удалось настроить переносимый SSH-ключ',
          options: [
            { value: 'retry', label: 'Повторить' },
            { value: 'defer', label: 'Сохранить ноду и настроить позже' },
          ],
        });
        if (choice === null) return { status: 'cancel' };
        if (choice === 'defer') defer = true;
        break;
      }
      default:
        if (!ctx.isFailure(reply)) return { status: 'cancel' };
        ctx.failed();
        return { status: 'failed' };
    }
  }
}

/** Поля формы добавления (умолчания v1); `values` — прежний ввод без пароля. */
export function addFields(values = {}) {
  return [
    { name: 'name', label: 'Название', type: 'text', placeholder: 'vps-1', value: values.name },
    { name: 'ip', label: 'IP', type: 'text', required: 'IP не указан.', value: values.ip },
    { name: 'port', label: 'SSH-порт', type: 'text', placeholder: '22', value: values.port, validate: portError },
    { name: 'user', label: 'Логин', type: 'text', placeholder: 'root', value: values.user },
    { name: 'tag', label: 'Тег', type: 'text', required: 'Тег не может быть пустым.', value: values.tag },
    {
      name: 'auth',
      label: 'Способ входа',
      type: 'radio',
      value: values.auth || 'key',
      options: [{ value: 'key', label: 'SSH-ключ' }, { value: 'password', label: 'Пароль' }],
    },
    { name: 'password', label: 'Пароль', type: 'secret', required: 'Пароль не может быть пустым.', when: (current) => current.auth === 'password' },
  ];
}

/**
 * Добавление ноды одной формой (`nodes.rs::add_node_with`). Сбой добавления
 * открывает форму снова с прежним вводом (кроме пароля); отмена — выход.
 * Сохранённая нода открывается через `go(имя)` — экран вызывает переход,
 * только пока смонтирован. `true` — нода добавлена.
 */
export async function addNodeFlow(ctx, go) {
  let previous = {};
  for (;;) {
    const values = await ctx.form({ title: ADD_TITLE, fields: addFields(previous), submit: 'Добавить' });
    if (values === null) return false;
    previous = { ...values, password: undefined };
    const built = addNodeArgv(values);
    if (built.warning) {
      ctx.notify('warn', built.warning);
      continue;
    }
    const result = await addNode(ctx, built.argv, built.password);
    if (result.status === 'cancel') return false;
    if (result.status === 'ok') {
      go(result.name);
      return true;
    }
  }
}

/**
 * «Изменить»: название и тег одной формой. Сначала `node rename` (сбой
 * останавливает), затем `node tag` под новым именем. Итог — текущее имя
 * ноды или `null` при отмене и сбое переименования.
 */
export async function editNode(ctx, node) {
  const name = plain(node.name);
  const tag = plain(node.tag);
  const values = await ctx.form({
    title: `Изменение ноды: ${name}`,
    fields: [
      { name: 'name', label: 'Название', type: 'text', value: name, required: true },
      { name: 'tag', label: 'Тег', type: 'text', value: tag },
    ],
  });
  if (values === null) return null;
  let current = name;
  if (values.name !== name) {
    const renamed = await ctx.call('node', 'rename', '--name', name, '--new-name', values.name);
    if (!renamed.ok) {
      outcome(ctx, renamed);
      return null;
    }
    current = (renamed.data && typeof renamed.data.name === 'string' && renamed.data.name) || values.name;
  }
  if (values.tag !== tag) outcome(ctx, await ctx.call('node', 'tag', '--name', current, '--tag', values.tag));
  return current;
}

/**
 * Ответы формы псевдонимов (`a<индекс>` — новое значение) в значения
 * `aliasArgv`: без изменений → `''`, очищенный → `-`, иначе новое значение.
 */
export function aliasValues(entries, form) {
  return asList(entries).map((entry, index) => {
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
  asList(entries).forEach((entry, index) => {
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

/**
 * Псевдонимы подключений ноды одной формой (`nodes.rs::aliases`): чтение
 * через `nodeRequest`, форма с полем на подключение, запись только изменённых.
 * Отмена формы ничего не пишет.
 */
export async function editAliases(ctx, name) {
  const reply = await ctx.nodeRequest(name, ['node', 'aliases', '--name', name]);
  if (!reply.ok) return;
  const entries = asList(reply.data);
  if (entries.length === 0) {
    ctx.notify('info', 'Подключения на ноде не найдены.');
    return;
  }
  const form = await ctx.form({
    title: `Псевдонимы подключений: ${name}`,
    fields: entries.map((entry, index) => ({
      name: `a${index}`,
      label: plain(entry.proxy),
      type: 'text',
      value: plain(entry.alias),
      hint: 'пусто — без псевдонима',
    })),
  });
  if (form === null) return;
  const argv = aliasArgv(name, entries, aliasValues(entries, form));
  if (!argv) {
    ctx.notify('info', 'Изменений нет.');
    return;
  }
  const saved = await ctx.request(argv);
  if (ctx.isFailure(saved)) ctx.failed();
}

// ─── Действия над нодой ──────────────────────────────────────────────────────

/** Зависимости `flows.js` из контекста экрана. */
function deps(ctx) {
  return { request: (words, options) => ctx.request(words, options), confirm: ctx.confirm, askSecret: ctx.askSecret, notify: ctx.notify };
}

/**
 * `node shell` / `telegram menu` в оверлее терминала (`nodes.rs::interactive`).
 * Состояния ноды разрешаются и команда повторяется; устаревшие скрипты —
 * предложение загрузки; `conflict` — терминал этой ноды уже открыт.
 */
export async function interactive(ctx, name, telegram) {
  const argv = interactiveArgv(name, telegram);
  const title = telegram ? `Telegram Proxy: ${name}` : `Меню сервера: ${name}`;
  for (;;) {
    const reply = await ctx.terminal(argv, title, { expect: ['conflict', 'invalid'] });
    if (reply.ok) return;
    if (await handleNodeCodes(reply, name, deps(ctx))) continue;
    if (errorCode(reply) === 'conflict') {
      ctx.notify('warn', 'Терминал этой ноды уже открыт');
      return;
    }
    if (errorCode(reply) === 'invalid') {
      if (typeof reply.error.state === 'string') {
        await offerUpload(ctx, name, reply.error.state);
        return;
      }
      ctx.notify('error', errorMessage(reply));
    }
    outcome(ctx, reply);
    return;
  }
}

/** Явная загрузка скриптов (`nodes.rs::offer_upload`); меню заново не открывается. */
async function offerUpload(ctx, name, state) {
  const offer = uploadOffer(name, state);
  const choice = await ctx.choose({
    title: offer.title,
    context: [offer.condition],
    options: [{ value: 'u', label: offer.label }],
    cancel: 'Назад',
  });
  if (choice !== 'u') return;
  const reply = await ctx.nodeRequest(name, offer.argv, { title: 'Загрузка скриптов', question: 'Загрузить скрипты?' });
  if (reply.ok) ctx.notify('success', 'Скрипты загружены. Откройте меню снова.');
}

/** `node setup-ssh` под планом (`nodes.rs::setup_ssh`). */
export async function setupSsh(ctx) {
  const words = ['node', 'setup-ssh'];
  for (;;) {
    const reply = await ctx.runConfirmed('Завершение SSH-настройки', 'Выполнить?', words);
    if (reply.ok) {
      if (reply.data && reply.data.ready === true) {
        ctx.notify('success', 'SSH-настройка завершена.');
      } else {
        for (const node of asList(reply.data && reply.data.deferred)) {
          ctx.notify('warn', `Отложено: ${plain(node.name)} — ${plain(node.issue)}`);
        }
      }
      return;
    }
    switch (errorCode(reply)) {
      case 'key_provisioning_required': {
        const provision = await ctx.confirm({
          title: 'Переносимый SSH-ключ',
          context: [`Ноды: ${joinedPlain(reply.error.nodes)}`],
          question: 'Создать переносимый SSH-ключ для этих нод?',
        });
        setFlag(words, decisionFlag(errorCode(reply)), provision ? 'yes' : 'no');
        break;
      }
      case 'onboarding_failed': {
        const choice = await ctx.choose({
          title: 'Не удалось настроить переносимый SSH-ключ',
          options: [
            { value: 'retry', label: 'Повторить' },
            { value: 'defer', label: 'Отложить проблемные ноды' },
          ],
        });
        if (choice === null) return;
        if (choice === 'defer') setFlag(words, '--on-failure', 'defer');
        break;
      }
      // Сообщение ядра уже показано; сбоя нет.
      case 'nothing_pending':
        return;
      default:
        outcome(ctx, reply);
        return;
    }
  }
}

/** Объём удаления из `delete_options`; `true`, если ноды больше нет (`nodes.rs::delete_node`). */
export async function deleteNode(ctx, name, node) {
  const options = deleteOptions(node);
  if (options.length === 0) {
    ctx.notify('warn', 'Нет доступных вариантов удаления.');
    return false;
  }
  const values = await ctx.form({
    title: `Удаление ноды: ${name}`,
    fields: [{ name: 'scope', label: 'Объём удаления', type: 'radio', options, required: true }],
    submit: 'Далее',
    tone: 'danger',
  });
  if (values === null) return false;
  const argv = deleteArgv(name, node.delete_options[values.scope]);
  const reply = await ctx.nodeRequest(name, argv, { title: 'Удаление ноды', question: 'Удалить ноду в выбранном объёме?' });
  return reply.ok || (reply.error && reply.error.deleted === true);
}

/** Удаление из списка: варианты удаления есть только в `node show`. */
export async function deleteListed(ctx, name) {
  const shown = await ctx.request(['node', 'show', '--name', name]);
  if (!shown.ok) return false;
  return deleteNode(ctx, name, shown.data);
}

/** Сохранение пароля SSH: значение — только в `secrets` запроса. */
export async function setNodePassword(ctx, name) {
  const values = await ctx.form({
    title: `Пароль SSH: ${name}`,
    fields: [{ name: 'password', label: 'Пароль SSH', type: 'secret', required: true }],
  });
  if (values === null) return;
  outcome(ctx, await ctx.request(['node', 'password', '--name', name], { secrets: { password: values.password } }));
}

/** Порт задаётся явно или подбирается ядром; план подтверждается (`nodes.rs::harden`). */
export async function harden(ctx, name) {
  const title = 'Усиление защиты SSH';
  const ask = async () => {
    const values = await ctx.form({
      title,
      fields: [{ name: 'port', label: 'SSH-порт (пусто — подобрать свободный)', type: 'text', validate: portError }],
      submit: 'Далее',
    });
    return values === null ? null : values.port;
  };
  const port = await ask();
  if (port === null) return;
  let words = hardenArgv(name, port);
  for (;;) {
    let reply = await ctx.request(words);
    if (hardenAsksPort(words, reply)) {
      const again = await ask();
      if (again === null) return;
      words = hardenArgv(name, again);
      continue;
    }
    reply = await reviewReply(title, 'Усилить защиту SSH?', words, reply, deps(ctx), 2);
    if (reply.ok) return;
    if (errorCode(reply) === 'hardening_failed') {
      if (reply.error.console_required === true) ctx.notify('warn', 'Проверьте доступ через консоль провайдера.');
      ctx.failed();
      return;
    }
    if (await handleNodeCodes(reply, name, deps(ctx))) continue;
    outcome(ctx, reply);
    return;
  }
}
