// Входная точка панели: подключение к демону, вход (план 2.5 «Вход», порядок
// П4), каркас Layout с боковым меню всех разделов 2.6, шапка с индикаторами.
// Экраны разделов (2.6) — `screens/`; каждый получает `ctx` (`makeContext`).
import { html, render, useEffect, useState, useRef } from '../vendor/preact-htm.js';
import { connect } from './protocol.js';
import * as session from './session.js';
import * as router from './router.js';
import * as fmt from './format.js';
import { runConfirmed, nodeRequest, isFailure } from './flows.js';
import { Layout, Card, Button, SecretField, Checkbox, Toast } from './ui.js';
import { useDialogs, DialogHost } from './dialogs.js';
import { TerminalOverlay } from './terminal.js';
import { SCREENS } from './screens/index.js';
import { githubWizard } from './screens/source.js';
import { recoveryRun } from './screens/system-model.js';

/** Разделы шага 2.6: пункт меню и маршрут. Цвет — по правилам скилла. */
const MENU = [
  { route: null, name: 'summary', label: 'Сводка', tone: 'view' },
  { route: 'nodes', name: 'nodes', label: 'Ноды', tone: 'create' },
  { route: 'clients', name: 'clients', label: 'Клиенты', tone: 'create' },
  { route: 'groups', name: 'groups', label: 'Группы', tone: 'create' },
  { route: 'templates', name: 'templates', label: 'Шаблоны', tone: 'create' },
  { route: 'connections', name: 'connections', label: 'Подключения', tone: 'change' },
  { route: 'generate', name: 'generate', label: 'Генерация конфигов', tone: 'change' },
  { route: 'subscriptions', name: 'subscriptions', label: 'Подписки', tone: 'change' },
  { route: 'awg', name: 'awg', label: 'AmneziaWG', tone: 'view' },
  { route: 'telegram', name: 'telegram', label: 'Telegram Proxy', tone: 'view' },
  { route: 'source', name: 'source', label: 'Источник конфигурации', tone: 'view' },
  { route: 'settings', name: 'settings', label: 'Настройки', tone: 'change' },
];

/** Команда могла изменить состояние: шапка перечитывает `status`. */
const READ_VERBS = new Set(['status', 'list', 'show', 'accounts', 'version', 'headers', 'aliases']);
function changes(command) {
  const [noun = '', verb = ''] = String(command || '').split(' ');
  return noun !== 'status' && !READ_VERBS.has(verb);
}

const menuEntries = (active) => MENU.map((item) => ({
  ...item,
  href: router.format(item.route || ''),
  active: active === item.name,
}));

/** Событие очереди демона: «Ожидание: выполняется «noun verb».». */
const WAITING = /^Ожидание: выполняется «(.+)»\.$/;

const ACCESS_CODE_HINT = "Откройте панель ссылкой из «essence-rc web open».";

export function App({ win = window, deps = {} }) {
  const storage = deps.storage || (win.sessionStorage || new Map());
  const connectionRef = useRef(null);
  const [phase, setPhase] = useState('connecting'); // connecting | gate | app
  const [gate, setGate] = useState(null);           // view текущего шага входа
  const [gateReply, setGateReply] = useState(null); // последний ответ `session open`
  const [hello, setHello] = useState(null);
  const [status, setStatus] = useState(null);
  const [linkState, setLinkState] = useState('connecting');
  const [failure, setFailure] = useState(null);
  const [busy, setBusy] = useState(false);
  const [route, setRoute] = useState({ name: 'summary', param: null });
  const [journal, setJournal] = useState([]);
  const [journalOpen, setJournalOpen] = useState(false);
  const [activity, setActivity] = useState(null);
  const [toasts, setToasts] = useState([]);
  const toastId = useRef(0);
  const [terminalState, setTerminalState] = useState(null);
  const [restart, setRestart] = useState(null); // null | 'update' | 'uninstall'
  const dialogs = useDialogs();

  // Одноразовый код из `#ticket=…`: фрагмент стирается сразу, код уходит
  // только с первым `session open`.
  const ticketRef = useRef(undefined);
  if (ticketRef.current === undefined) ticketRef.current = router.consumeTicket(win);
  if (!connectionRef.current) {
    connectionRef.current = connect({ WebSocket: win.WebSocket, location: win.location, storage });
  }
  const connection = connectionRef.current;
  const phaseRef = useRef(phase);
  phaseRef.current = phase;

  const notify = (level, text) => {
    setJournal((current) => [...current, { level, text }]);
    if (level !== 'info') {
      toastId.current += 1;
      const id = toastId.current;
      // Сообщение ядра и итог «Операция завершилась ошибкой…» видны вместе.
      setToasts((current) => [...current.slice(-2), { id, level, text }]);
    }
  };
  const log = (entry) => {
    // Очередь за собственным запросом панели (параллельные чтения экрана и
    // шапки) — не новость; ожидание чужой команды остаётся в журнале.
    const waiting = entry.level === 'info' && WAITING.exec(entry.text || '');
    if (waiting && entry.id !== undefined && connection.runs(waiting[1], entry.id)) return;
    setJournal((current) => [...current, { level: entry.level, text: entry.text }]);
  };

  useEffect(() => {
    if (connection.hello) setHello(connection.hello);
    const offHello = connection.on('hello', setHello);
    const offLog = connection.on('log', log);
    const offState = connection.on('state', (state) => {
      setLinkState(state);
      if (state === 'reconnecting') notify('warn', 'Соединение с демоном потеряно. Переподключение…');
    });
    // После переподключения: без токена или с отклонённым токеном — снова вход.
    const offResumed = connection.on('resumed', (reply) => {
      setBusy(false);
      setRestart((current) => (current === 'update' ? null : current));
      if (reply && reply.ok) {
        setGate('open');
        setPhase('app');
        loadStatus();
        return;
      }
      // Без токена или с отклонённым токеном (`protocol.js` уже стёр его) —
      // вход заново: демон сам скажет, нужен ли пароль или код доступа.
      if (reply === null || (reply.error && reply.error.secret === 'access-token')) { open(); return; }
      setGateReply(reply);
      setGate(session.routeReply(reply));
      setPhase('gate');
    });
    // Ссылка с кодом, вставленная в уже открытую вкладку, меняет только
    // фрагмент (без перезагрузки): код забирается и вход повторяется. Этот
    // обработчик стоит раньше маршрутизатора — тот видит уже очищенный адрес.
    const onTicket = () => {
      const ticket = router.consumeTicket(win);
      if (!ticket) return;
      ticketRef.current = ticket;
      open();
    };
    win.addEventListener('hashchange', onTicket);
    const stopRouter = router.start(win, setRoute);
    const unwatch = connection.watch((event) => {
      if (event.state === 'start') setActivity(event.command || '');
      if (event.state === 'end') {
        setActivity(null);
        if (phaseRef.current === 'app' && changes(event.command)) loadStatus();
      }
      // Свои запросы приходят и событиями `log` по `id`, и `activity`-журналом:
      // пока у этого соединения есть запросы в работе, журнал активности не дублируется.
      if (event.state === 'log' && !connection.inFlight()) log(event);
    });
    return () => {
      offHello(); offLog(); offState(); offResumed(); stopRouter(); unwatch();
      win.removeEventListener('hashchange', onTicket);
    };
  }, [connection]);

  const ctx = makeContext({
    connection, dialogs: dialogs.api, notify, hello, status, win,
    refreshStatus: () => loadStatus(),
    openTerminal: (argv, title) => new Promise((resolve) => setTerminalState({ argv, title, resolve })),
    restart: (kind) => {
      setRestart(kind);
      if (kind === 'uninstall') connection.close();
    },
  });

  /** Шапка: источник, синхронизация и пароль запуска — из `status`. */
  const loadStatus = async () => {
    const reply = await connection.request(['status'], {});
    if (reply.ok) setStatus(reply.data);
  };

  /** Шаг входа: `session open` → экран по коду ответа. */
  const open = async (options = {}) => {
    setBusy(true);
    const ticket = ticketRef.current;
    ticketRef.current = null;
    const reply = await session.openSession(connection, { ...options, ticket });
    setBusy(false);
    setGateReply(reply);
    const view = session.routeReply(reply);
    setGate(view);
    setPhase(view === 'open' ? 'app' : 'gate');
    if (view === 'open') loadStatus();
    return { view, reply };
  };

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        await connection.ready;
      } catch (error) {
        if (!cancelled) { setFailure(error.message); setPhase('gate'); setGate('incompatible'); }
        return;
      }
      if (cancelled) return;
      // Шаг 1 входа: `session status`; ошибка — экран «Повторить».
      const statusReply = await connection.request(['session', 'status'], {});
      if (cancelled) return;
      if (!statusReply.ok) {
        setGateReply(statusReply);
        setGate('retry');
        setPhase('gate');
        return;
      }
      open();
    })();
    return () => { cancelled = true; };
  }, [connection]);

  // ── Экраны входа ─────────────────────────────────────────────────────────
  const gateView = () => {
    if (phase === 'connecting') {
      return html`<div class="gate"><${Card} title="Remote Control"><p>Подключение к демону…</p><//></div>`;
    }
    switch (gate) {
      case 'script-password':
      case 'vault-password': {
        const vault = gate === 'vault-password';
        const code = gateReply && gateReply.error ? gateReply.error.code : null;
        const failed = code === 'auth_failed' || code === 'vault_password_invalid';
        return html`<${GateForm}
          key=${gate}
          title="Открытие сессии"
          label=${vault ? 'Пароль доступа к конфигурации GitHub' : 'Введите пароль'}
          message=${failed ? fmt.errorMessage(gateReply) : null}
          remember=${vault}
          busy=${busy}
          onSubmit=${async (password, remember) => {
            if (!password) return;
            await open({ secrets: vault ? { 'vault-password': password } : { 'script-password': password }, remember });
          }} />`;
      }
      case 'access-code':
        return html`<div class="gate"><${Card} title="Вход">
          ${gateReply && gateReply.error && gateReply.error.code === 'auth_failed' && html`<p class="tone-warn">${fmt.errorMessage(gateReply)}</p>`}
          <p>${ACCESS_CODE_HINT}</p>
        <//></div>`;
      case 'incompatible':
        return html`<div class="gate"><${Card} title="Не удалось подключиться к демону">
          <p class="tone-error">${failure}</p>
        <//></div>`;
      case 'first-run':
        return html`<div class="gate"><${Card} title="Первый запуск">
          <p>Выберите источник:</p>
          <div class="modal-buttons">
            <${Button} kind="create" disabled=${busy} onClick=${async () => {
              setBusy(true);
              const reply = await session.initLocal(connection);
              setBusy(false);
              if (reply.ok) open();
              else notify('error', fmt.errorMessage(reply));
            }}>Создать локальную конфигурацию<//>
            <${Button} kind="create" disabled=${busy} onClick=${async () => {
              setBusy(true);
              const done = await githubWizard(ctx, 'connect');
              setBusy(false);
              if (done) open();
            }}>Подключить GitHub<//>
          </div>
        <//></div>`;
      case 'recovery': {
        const error = gateReply && gateReply.error ? gateReply.error : {};
        const options = session.recoveryOptions(error.code || '');
        return html`<div class="gate"><${Card} title="Конфигурация GitHub требует восстановления">
          ${error.message && html`<p class="tone-warn">${error.message}</p>`}
          ${error.version && html`<p>Формат конфигурации: v${error.version}</p>`}
          ${error.required && html`<p>Требуется remote-control: ${fmt.versionLabel(error.required)}</p>`}
          <div class="modal-buttons column">
            ${options.map((option) => html`
              <${Button} key=${option.id} kind=${option.tone} disabled=${busy} onClick=${async () => {
                setBusy(true);
                const reply = await recoveryRun(ctx, option.title, option.question, option.verb, {});
                if (reply && isFailure(reply)) ctx.failed();
                setBusy(false);
                if (reply && reply.ok) open();
              }}>${option.label}<//>
            `)}
            <${Button} onClick=${() => open()}>Повторить вход<//>
          </div>
        <//></div>`;
      }
      default:
        return html`<div class="gate"><${Card} title="Не удалось открыть сессию">
          <p>${gateReply && gateReply.error ? fmt.errorMessage(gateReply) : 'Повторите позже.'}</p>
          <div class="modal-buttons"><${Button} kind="view" disabled=${busy} onClick=${() => open()}>Повторить<//></div>
        <//></div>`;
    }
  };

  // ── Каркас приложения ────────────────────────────────────────────────────
  const menu = menuEntries(route.name);
  const indicators = [];
  if (hello) indicators.push({ text: `essence-rc ${fmt.versionLabel(hello.version)}`, tone: 'dim' });
  if (status) {
    const source = fmt.sourceLabel(status.source);
    indicators.push({ text: `Источник: ${source.label}`, tone: 'info' });
    if (source.sync) indicators.push({ text: source.sync.label, tone: source.sync.tone });
  }
  if (linkState === 'reconnecting') indicators.push({ text: 'нет связи', tone: 'warn' });
  if (activity) indicators.push({ text: fmt.activityIndicator(activity), tone: 'info' });
  const banner = hello && status && fmt.openPanel(hello, status, null) ? fmt.OPEN_PANEL_WARNING : null;

  const Screen = SCREENS[route.name] || SCREENS.summary;
  const body = restart === 'uninstall'
    ? html`<div class="gate"><${Card} title="essence-rc удалён"><p>Панель больше недоступна. Закройте эту вкладку.</p><//></div>`
    : restart === 'update'
      ? html`<div class="gate"><${Card} title="Демон перезапускается"><p>Переподключение…</p><//></div>`
      : phase === 'app'
        ? html`<${Layout} menu=${menu} indicators=${indicators} banner=${banner}
              journal=${journal} journalOpen=${journalOpen} onToggleJournal=${() => setJournalOpen(!journalOpen)}>
            <${Screen} key=${`${route.name}/${route.param || ''}`} ctx=${ctx} param=${route.param} />
          <//>`
        : gateView();

  return html`
    <div class="toasts">
      ${toasts.map((toast) => html`<${Toast} key=${toast.id} toast=${toast}
        onDone=${() => setToasts((current) => current.filter((item) => item.id !== toast.id))} />`)}
    </div>
    ${body}
    ${terminalState && html`<${TerminalOverlay}
      title=${terminalState.title}
      argv=${terminalState.argv}
      start=${(argv, options) => connection.terminal(argv, options)}
      onClosed=${(reply) => { const done = terminalState.resolve; setTerminalState(null); done(reply); }} />`}
    <${DialogHost} stack=${dialogs.stack} />
  `;
}

/** Форма пароля входа (пароль запуска / пароль хранилища GitHub). */
function GateForm({ title, label, message = null, remember = false, busy = false, onSubmit }) {
  const [value, setValue] = useState('');
  const [keep, setKeep] = useState(false);
  return html`<div class="gate"><${Card} title=${title}>
    ${message && html`<p class="tone-warn">${message}</p>`}
    <form class="form" onSubmit=${(event) => { event.preventDefault(); onSubmit(value, keep); setValue(''); }}>
      <${SecretField} label=${label} value=${value} onInput=${setValue} />
      ${remember && html`<${Checkbox} label="Сохранить ключ расшифровки на этом устройстве" checked=${keep} onChange=${setKeep} />`}
      <div class="modal-buttons">
        <${Button} kind="create" type="submit" disabled=${busy || !value}>Открыть<//>
      </div>
    </form>
  <//></div>`;
}

/** Ответ, который `ctx.request` не показывает: планы и вопросы `*_required`. */
function silent(reply, expect) {
  if (reply.ok || !reply.error) return true;
  const code = reply.error.code || '';
  if (code === 'confirmation_required' || code === 'plan_changed' || code.endsWith('_required')) return true;
  return Array.isArray(expect) ? expect.includes(code) : expect === code;
}

/**
 * Контекст экранов — аналог `tui::app::Context`:
 * - `request(argv, { secrets, input, onLog, expect, operation })` → ответ; текст
 *   ошибки показывается здесь ровно один раз (кроме планов, `*_required` и
 *   кодов `expect`); `operation` — заголовок окна операции со строками журнала;
 * - `confirm`, `askSecret`, `ask`, `choose`, `toggle`, `show`, `operation` — диалоги;
 * - `runConfirmed(title, question, argv, { secrets, input })`,
 *   `nodeRequest(name, argv, review)` — `flows.js` с этим контекстом;
 * - `failed()` — «Операция завершилась ошибкой…» для отказов без текста ядра;
 * - `navigate(name, param)`, `terminal(argv, title)` → ответ после закрытия
 *   оверлея (`{ expect }` — как у `request`), `wizard(mode)` → `true` при успехе мастера GitHub,
 *   `restart('update'|'uninstall')`, `refreshStatus()`, `hello`, `status`.
 */
function makeContext({ connection, dialogs, notify, hello, status, win, refreshStatus, openTerminal, restart }) {
  const ctx = {
    hello,
    status,
    notify,
    ...dialogs,
    async request(argv, options = {}) {
      const { secrets, input, onLog, expect = null, operation = null } = options;
      const progress = operation ? dialogs.operation(operation) : null;
      const reply = await connection.request(argv, {
        secrets,
        input,
        onLog: (entry) => {
          if (progress) progress.log(entry);
          if (onLog) onLog(entry);
        },
      });
      if (progress) progress.finish();
      if (!silent(reply, expect)) notify('error', fmt.errorMessage(reply));
      return reply;
    },
    call: (...words) => ctx.request(words),
    failed: () => notify('warn', 'Операция завершилась ошибкой. Повторите действие из меню.'),
    isFailure,
    runConfirmed: (title, question, argv, { secrets, input } = {}) => runConfirmed(title, question, argv, {
      request: (words, opts) => ctx.request(words, opts), confirm: dialogs.confirm, notify, secrets, input,
    }),
    nodeRequest: (name, argv, review = null) => nodeRequest(name, argv, review, {
      request: (words, opts) => ctx.request(words, opts), confirm: dialogs.confirm, askSecret: dialogs.askSecret, notify,
    }),
    navigate: (name, param = null) => router.navigate(win, name === 'summary' ? '' : name, param),
    async terminal(argv, title, { expect = null } = {}) {
      const reply = await openTerminal(argv, title);
      if (!silent(reply, expect)) notify('error', fmt.errorMessage(reply));
      return reply;
    },
    wizard: (mode) => githubWizard(ctx, mode),
    restart,
    refreshStatus,
  };
  return ctx;
}

const mount = document.getElementById('app');
if (mount) render(html`<${App} />`, mount);
