// Подтверждения по замороженному плану ядра и обработка состояний нод —
// перенос `tui/src/confirm.rs` и `tui/src/nodes.rs` (`handle_node_codes`,
// `node_request`). Зависимости передаются параметрами:
// - `request(argv, { secrets, input })` → `Promise<{ok,data,error,...}>`;
// - `confirm({ title, plan, question })` → `Promise<boolean>`;
// - `askSecret({ title, label })` → `Promise<string|null>`;
// - `notify(level, text)` — сообщение пользователю (`info|success|warn|error`).

export const PLAN_CHANGED = 'План изменился. Проверьте его ещё раз.';
export const PLAN_KEEPS_CHANGING = 'План продолжает меняться. Действие не выполнено; повторите позже.';
export const BROKEN_PLAN = 'Операция завершилась ошибкой. Повторите действие.';
/** `Context::failed` TUI: итог неуспешной операции; текст ядра показывает слой запросов. */
export const OPERATION_FAILED = 'Операция завершилась ошибкой. Повторите действие из меню.';
export const NEEDS_SETUP = 'Нода требует SSH-настройки: раздел «Ноды» → «Завершить отложенную SSH-настройку».';
/** Состояния ноды, которые разрешает `handleNodeCodes`. */
export const NODE_CODES = ['missing_secret', 'host_key_changed', 'host_key_unknown', 'needs_setup'];

/** Флаг решения по коду `*_required` (`confirm.rs::decision_flag`); иначе `null`. */
export function decisionFlag(code) {
  switch (code) {
    case 'repo_create_required': return '--create-repo';
    case 'repo_private_required': return '--make-private';
    case 'storage_mode_required': return '--storage';
    case 'existing_config_action_required': return '--existing';
    case 'key_provisioning_required': return '--provision-keys';
    case 'cache_skip_required': return '--without-cache';
    case 'target_replace_required': return '--replace-target';
    case 'delete_scope_required': return '--scope';
    case 'on_failure_required': return '--on-failure';
    default: return null;
  }
}

/**
 * Задать флаг без повторов (`confirm.rs::set_flag`); `value === null` или
 * `undefined` — булев флаг. Меняет и возвращает `argv`.
 */
export function setFlag(argv, flag, value = null) {
  const index = argv.indexOf(flag);
  if (index >= 0) {
    if (value !== null && value !== undefined) {
      if (index + 1 < argv.length && !argv[index + 1].startsWith('--')) argv[index + 1] = String(value);
      else argv.splice(index + 1, 0, String(value));
    }
  } else {
    argv.push(flag);
    if (value !== null && value !== undefined) argv.push(String(value));
  }
  return argv;
}

/** Убрать ранее заданный булев флаг (`confirm.rs::clear_flag`). */
export function clearFlag(argv, flag) {
  for (let i = argv.length - 1; i >= 0; i -= 1) if (argv[i] === flag) argv.splice(i, 1);
  return argv;
}

const quiet = () => {};

/**
 * Просмотр уже полученного ответа с планом (`confirm.rs::review`).
 * Отказ возвращает последний неуспешный ответ без отправки мутации.
 * `maxChanges` — сколько раз показывается `plan_changed` (`null` — без предела).
 */
export async function reviewReply(title, question, argv, reply, deps, maxChanges = 2) {
  const { request, confirm, notify = quiet, secrets, input } = deps;
  const base = [...argv];
  let changes = 0;
  for (;;) {
    const code = reply && reply.error ? reply.error.code : null;
    if (reply.ok || (code !== 'confirmation_required' && code !== 'plan_changed')) return reply;
    if (code === 'plan_changed') {
      changes += 1;
      if (maxChanges !== null && changes > maxChanges) {
        notify('warn', PLAN_KEEPS_CHANGING);
        return reply;
      }
      notify('warn', PLAN_CHANGED);
      // Харднинг замораживает выбранный порт в argv: обновляется только уже
      // присутствующий `--port`, другие флаги сюда не добавляются.
      const port = reply.error.port;
      if (base.includes('--port') && port !== null && port !== undefined) setFlag(base, '--port', String(port));
    }
    const token = typeof reply.error.plan_token === 'string' ? reply.error.plan_token : '';
    if (!token) {
      notify('error', BROKEN_PLAN);
      return reply;
    }
    const plan = Array.isArray(reply.error.plan) ? reply.error.plan : [];
    if (!(await confirm({ title, plan, question }))) return reply;
    const confirmed = [...base];
    setFlag(confirmed, '--yes');
    setFlag(confirmed, '--plan-token', token);
    reply = await request(confirmed, { secrets, input });
  }
}

/**
 * Команда под подтверждением (`confirm.rs::run_confirmed_with`): первый вызов
 * получает план, повтор — с `--yes --plan-token`. `deps.secrets` и
 * `deps.input` уходят с каждой попыткой.
 */
export async function runConfirmed(title, question, argv, deps) {
  const reply = await deps.request([...argv], { secrets: deps.secrets, input: deps.input });
  return reviewReply(title, question, argv, reply, deps, 2);
}

/** Отказ от плана — не сбой (`nodes.rs::outcome`). */
export function isFailure(reply) {
  if (reply.ok) return false;
  const code = reply.error ? reply.error.code : null;
  return code !== 'confirmation_required' && code !== 'plan_changed';
}

/**
 * Команда не выполнилась и ничего не изменила (`confirm.rs::retryable`): не
 * отказ от плана и не `partial` — форма, отправившая её, открывается снова с введённым.
 */
export function retryable(reply) {
  return isFailure(reply) && !(reply.error && reply.error.code === 'partial');
}

/**
 * Разрешение состояния ноды (`nodes.rs::handle_node_codes`): `true`, если
 * условие устранено и исходную команду можно повторить.
 */
export async function handleNodeCodes(reply, name, deps) {
  const { request, confirm, askSecret, notify = quiet } = deps;
  const code = reply && reply.error ? reply.error.code : null;
  switch (code) {
    case 'missing_secret': {
      const title = `Нода: ${name}`;
      if (!(await confirm({ title, plan: [], question: 'Пароль SSH для ноды не сохранён. Сохранить сейчас?' }))) return false;
      const password = await askSecret({ title, label: 'Пароль SSH' });
      if (!password) return false;
      // Текст ошибки ядра показывает `request` (как `Context::request` в TUI).
      const saved = await request(['node', 'password', '--name', name], { secrets: { password } });
      return saved.ok;
    }
    case 'host_key_changed':
    case 'host_key_unknown': {
      const fingerprints = Array.isArray(reply.error.fingerprints) ? reply.error.fingerprints : [];
      const fingerprint = typeof fingerprints[0] === 'string' ? fingerprints[0] : null;
      if (!fingerprint) return false;
      const argv = ['node', 'trust-host-key', '--name', name, '--host-key', fingerprint];
      const trusted = await runConfirmed('Ключ сервера изменился', 'Доверять новому ключу?', argv, { request, confirm, notify });
      return trusted.ok;
    }
    case 'needs_setup':
      notify('warn', NEEDS_SETUP);
      return false;
    default:
      return false;
  }
}

/**
 * Команда над нодой (`nodes.rs::node_request`): `review` — `{ title, question }`
 * для команды под подтверждением либо `null`. После устранённого состояния
 * ноды исходная команда повторяется. Оставшийся сбой (не отказ от плана)
 * сообщается `OPERATION_FAILED` (`nodes.rs::outcome`); текст ядра (`error.message`)
 * уже показал `request` — вызывающий экран сбой не повторяет. Коды `expect`
 * (команда без подтверждения) экран обрабатывает сам: `request` их не
 * показывает, `OPERATION_FAILED` нет.
 */
export async function nodeRequest(name, argv, review, deps, { expect = null } = {}) {
  for (;;) {
    const reply = review
      ? await runConfirmed(review.title, review.question, argv, { request: deps.request, confirm: deps.confirm, notify: deps.notify })
      : await deps.request([...argv], expect === null ? {} : { expect });
    if (reply.ok) return reply;
    if (!review && expect !== null && reply.error && reply.error.code === expect) return reply;
    if (await handleNodeCodes(reply, name, deps)) continue;
    if (isFailure(reply) && deps.notify) deps.notify('warn', OPERATION_FAILED);
    return reply;
  }
}

/** Значение отмены окна по виду (как Esc и «Отмена»): `confirm` → `false`, `show` → `undefined`, прочие → `null`. */
const CANCEL = { confirm: false, show: undefined };
export const cancelValue = (kind) => (kind in CANCEL ? CANCEL[kind] : null);

/** Методы `ctx` с окнами-вопросами и вид окна (`dialogs.js`). */
const DIALOG_KINDS = { confirm: 'confirm', askSecret: 'secret', ask: 'text', choose: 'choose', form: 'form', show: 'show' };

/**
 * Окна экрана: пока `alive()` — окна `api`, после ухода с экрана —
 * сразу значение отмены без окна. Поток ушедшего экрана (цикл меню, повтор
 * формы) завершается сам и не открывает окна поверх нового раздела; окна
 * операций (`operation`) не затрагиваются — их закрывает сама команда.
 */
export function screenDialogs(api, alive) {
  const scoped = { ...api };
  for (const [method, kind] of Object.entries(DIALOG_KINDS)) {
    scoped[method] = (props) => (alive() ? api[method](props) : Promise.resolve(cancelValue(kind)));
  }
  return scoped;
}
