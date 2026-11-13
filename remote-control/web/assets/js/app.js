// Входная точка панели: подключение к демону, вход (план 2.5 «Вход», порядок
// П4), каркас Layout с меню разделов, шапка с индикаторами, журнал и
// всплывающие сообщения. Экраны разделов — `screens/`; каждый получает `ctx`
// (`makeContext`), параметр и вкладку маршрута.
import { html, render, useEffect, useState, useRef } from '../vendor/preact-htm.js';
import { connect } from './protocol.js';
import * as session from './session.js';
import * as router from './router.js';
import * as fmt from './format.js';
import * as theme from './theme.js';
import { runConfirmed, nodeRequest, isFailure } from './flows.js';
import { Layout, Card, Button, SecretField, Checkbox, Snackbars } from './ui.js';
import { useDialogs, DialogHost } from './dialogs.js';
import { TerminalOverlay } from './terminal.js';
import { SCREENS } from './screens/index.js';
import { githubWizard } from './screens/source.js';
import { recoveryRun } from './screens/system-model.js';

/** Разделы меню: `name` — маршрут (`summary` — `#/`), `divider` — разделитель. */
const MENU = [
  { name: 'summary', route: null, label: 'Сводка', icon: 'layout-dashboard' },
  { name: 'nodes', label: 'Ноды', icon: 'server' },
  { name: 'clients', label: 'Клиенты', icon: 'users' },
  { name: 'groups', label: 'Группы', icon: 'folders' },
  { name: 'templates', label: 'Шаблоны', icon: 'file-code' },
  { name: 'subscriptions', label: 'Подписки', icon: 'rss' },
  { name: 'telegram', label: 'Telegram Proxy', icon: 'send' },
  { divider: true },
  { name: 'source', label: 'Источник', icon: 'git-branch' },
  { name: 'settings', label: 'Настройки', icon: 'settings' },
  { name: 'journal', label: 'Журнал', icon: 'scroll-text' },
];

/** Наибольшее число записей журнала (старые отбрасываются). */
const JOURNAL_LIMIT = 2000;

/** Команда могла изменить состояние: шапка перечитывает `status`. */
const READ_VERBS = new Set(['status', 'list', 'show', 'accounts', 'version', 'headers', 'aliases', 'check']);
function changes(command) {
  const [noun = '', verb = ''] = String(command || '').split(' ');
  return noun !== 'status' && !READ_VERBS.has(verb);
}

/** Фоновая проверка шаблона в редакторе не показывается в шапке. */
const SILENT_ACTIVITY = new Set(['template check']);

/** Хеш маршрута раздела; сводка — `#/`. */
const href = (name, param = null, tab = null) => router.format(name === 'summary' ? '' : name, param, tab);

/** Маршрут экрана: неизвестный раздел — сводка (ключ экрана — `router.screenKey`). */
const screenRoute = (route) => (SCREENS[route.name] ? route : { ...route, name: 'summary' });

const menuEntries = (active) => MENU.map((item) => (item.divider ? item : {
  ...item,
  href: href(item.name),
  active: active === item.name,
}));

/** Событие очереди демона: «Ожидание: выполняется «noun verb».». */
const WAITING = /^Ожидание: выполняется «(.+)»\.$/;

const ACCESS_CODE_HINT = "Откройте панель ссылкой из «essence-rc web open».";

/** Локальное хранилище темы; недоступное (режим приватности) — `null`. */
function localStore(win) {
  try { return win.localStorage || null; } catch { return null; }
}

export function App({ win = window, deps = {} }) {
  const storage = deps.storage || (win.sessionStorage || new Map());
  const themeStore = localStore(win);
  const connectionRef = useRef(null);
  const [phase, setPhase] = useState('connecting'); // connecting | gate | app
  const [gate, setGate] = useState(null);           // view текущего шага входа
  const [gateReply, setGateReply] = useState(null); // последний ответ `session open`
  const [hello, setHello] = useState(null);
  const [status, setStatus] = useState(null);
  const [linkState, setLinkState] = useState('connecting');
  const [failure, setFailure] = useState(null);
  const [busy, setBusy] = useState(false);
  const [route, setRoute] = useState({ name: 'summary', param: null, tab: null });
  const [journal, setJournal] = useState([]);
  const [journalSeen, setJournalSeen] = useState(0); // id последней просмотренной записи
  const journalId = useRef(0);
  const [activity, setActivity] = useState(null);
  const [snacks, setSnacks] = useState([]);
  const snackId = useRef(0);
  const [themeChoice, setThemeChoice] = useState(() => theme.readChoice(themeStore));
  const [themeName, setThemeName] = useState(() => theme.resolve(theme.readChoice(themeStore), theme.prefersDark(win)));
  const [terminalState, setTerminalState] = useState(null);
  const [restart, setRestart] = useState(null); // null | 'update' | 'uninstall'
  const dialogs = useDialogs();
  // Защита ухода со страницы с несохранёнными изменениями (`ctx.setLeaveGuard`).
  const leaveGuard = useRef(null);
  const currentHash = useRef(String(win.location.hash || ''));
  const leavePending = useRef(false); // вопрос защиты открыт
  const routeRef = useRef(route);

  // Одноразовый код из `#ticket=…`: фрагмент стирается сразу, код уходит
  // только с первым `session open` и до отправки ждёт в `ticketRef`.
  const ticketRef = useRef(undefined);
  if (ticketRef.current === undefined) ticketRef.current = router.consumeTicket(win);
  if (!connectionRef.current) {
    connectionRef.current = connect({ WebSocket: win.WebSocket, location: win.location, storage });
  }
  const connection = connectionRef.current;
  const phaseRef = useRef(phase);
  phaseRef.current = phase;

  /** Запись журнала; `repeat: false` — такая же запись подряд не повторяется. */
  const record = (level, text, { repeat = true } = {}) => {
    journalId.current += 1;
    const entry = { id: journalId.current, level: level || 'info', text: String(text ?? ''), time: Date.now() };
    setJournal((current) => fmt.appendJournal(current, entry, JOURNAL_LIMIT, repeat));
  };
  const notify = (level, text) => {
    record(level, text);
    if (level !== 'info') {
      snackId.current += 1;
      const id = snackId.current;
      // Сообщение ядра и итог «Операция завершилась ошибкой…» видны вместе.
      setSnacks((current) => [...current.slice(-2), { id, level, text }]);
    }
  };
  const log = (entry) => {
    // Очередь за собственным запросом панели (параллельные чтения экрана и
    // шапки) — не новость; ожидание чужой команды остаётся в журнале.
    const waiting = entry.level === 'info' && WAITING.exec(entry.text || '');
    if (waiting && entry.id !== undefined && connection.runs(waiting[1], entry.id)) return;
    record(entry.level, entry.text);
  };

  // Тема: выбор пользователя и системная настройка.
  useEffect(() => theme.watch(win, themeStore, (choice, name) => { setThemeChoice(choice); setThemeName(name); }), []);
  const setTheme = (choice) => {
    theme.storeChoice(themeStore, choice);
    setThemeChoice(choice);
    const name = theme.resolve(choice, theme.prefersDark(win));
    setThemeName(name);
    theme.apply(win.document, name);
  };

  // Уход со страницы с защитой — вопрос браузера.
  useEffect(() => {
    const onUnload = (event) => {
      if (!leaveGuard.current) return;
      event.preventDefault();
      event.returnValue = '';
    };
    win.addEventListener('beforeunload', onUnload);
    return () => win.removeEventListener('beforeunload', onUnload);
  }, []);

  /** Применить маршрут; смена экрана закрывает его окна (кроме окон операций). */
  const applyRoute = (next, hash) => {
    currentHash.current = hash;
    if (router.screenKey(screenRoute(next)) !== router.screenKey(screenRoute(routeRef.current))) dialogs.api.cancelAll();
    routeRef.current = next;
    setRoute(next);
  };

  /**
   * Смена маршрута с учётом защиты ухода (`router.routeDecision`): вопрос
   * задаётся один раз, пока он открыт, новые смены адреса ждут его итога;
   * отказ возвращает прежний адрес через `history.replaceState` (без новой
   * записи истории и без `hashchange`), согласие применяет последний адрес.
   */
  const onRoute = (next) => {
    const hash = String(win.location.hash || '');
    const guard = leaveGuard.current;
    const decision = router.routeDecision({ hash, current: currentHash.current, guarded: Boolean(guard), pending: leavePending.current });
    if (decision === 'wait') return;
    if (decision === 'apply') { applyRoute(next, hash); return; }
    leavePending.current = true;
    const previous = currentHash.current;
    (async () => {
      let leave = false;
      try { leave = Boolean(await guard()); } catch { leave = false; }
      leavePending.current = false;
      if (!leave) {
        win.history.replaceState(win.history.state, '', router.hashUrl(win.location, previous));
        return;
      }
      leaveGuard.current = null;
      const latest = String(win.location.hash || '');
      applyRoute(router.parse(latest), latest);
    })();
  };

  useEffect(() => {
    if (connection.hello) setHello(connection.hello);
    const offHello = connection.on('hello', setHello);
    const offLog = connection.on('log', log);
    const offState = connection.on('state', (state) => {
      setLinkState(state);
      if (state === 'reconnecting') notify('warn', 'Соединение с демоном потеряно. Переподключение…');
      // Несовместимый `hello` после переподключения (обновлённый демон):
      // переподключений больше не будет, вкладку нужно перезагрузить.
      if (state === 'incompatible') {
        setFailure(connection.failure);
        setRestart((current) => (current === 'update' ? null : current));
        setGate('incompatible');
        setPhase('gate');
      }
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
    // фрагмент (без перезагрузки): код забирается и вход повторяется (после
    // текущей попытки, если она идёт). Этот обработчик стоит раньше
    // маршрутизатора — тот видит уже очищенный адрес.
    const onTicket = () => {
      const ticket = router.consumeTicket(win);
      if (!ticket) return;
      ticketRef.current = ticket;
      open();
    };
    win.addEventListener('hashchange', onTicket);
    const stopRouter = router.start(win, onRoute);
    const unwatch = connection.watch((event) => {
      const silentActivity = SILENT_ACTIVITY.has(event.command);
      if (event.state === 'start' && !silentActivity) setActivity(event.command || '');
      if (event.state === 'end') {
        if (!silentActivity) setActivity(null);
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

  // Журнал открыт — его записи просмотрены.
  useEffect(() => {
    if (route.name === 'journal') setJournalSeen(journalId.current);
  }, [route.name, journal]);

  const ctx = makeContext({
    connection, dialogs: dialogs.api, notify, record, hello, status, win,
    refreshStatus: () => loadStatus(),
    openTerminal: (argv, title) => new Promise((resolve) => setTerminalState({ argv, title, resolve })),
    restart: (kind) => {
      setRestart(kind);
      if (kind === 'uninstall') connection.close();
    },
    journal,
    clearJournal: () => { setJournal([]); setJournalSeen(journalId.current); },
    theme: { choice: themeChoice, dark: themeName === 'essence-dark', set: setTheme },
    setLeaveGuard: (guard) => { leaveGuard.current = typeof guard === 'function' ? guard : null; },
  });

  /** Шапка: источник, синхронизация и пароль запуска — из `status`. */
  const loadStatus = async () => {
    const reply = await connection.request(['status'], {});
    if (reply.ok) setStatus(reply.data);
  };

  /** Шаг входа: `session open` → экран по коду ответа. */
  const attemptOpen = async (options = {}) => {
    setBusy(true);
    const ticket = ticketRef.current;
    ticketRef.current = null;
    const reply = await session.openSession(connection, { ...options, ticket });
    setBusy(false);
    const view = session.loginView(connection, reply);
    // Экран несовместимости уже показан обработчиком `state`: ответ
    // `disconnected` его не заменяет.
    if (view === 'incompatible') return { view, reply };
    setGateReply(reply);
    setGate(view);
    setPhase(view === 'open' ? 'app' : 'gate');
    if (view === 'open') loadStatus();
    return { view, reply };
  };
  const attemptRef = useRef(attemptOpen);
  attemptRef.current = attemptOpen;
  // Попытки входа по одной: вызов во время `session open` ждёт его итога.
  const loginRef = useRef(null);
  if (!loginRef.current) {
    loginRef.current = session.serialLogin((options) => attemptRef.current(options), session.loginFinal);
  }
  const open = loginRef.current;

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
      return html`<div class="gate"><${Card} title="Remote Control"><p class="t-dim">Подключение к демону…</p><//></div>`;
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
          ${gateReply && gateReply.error && gateReply.error.code === 'auth_failed' && html`<p class="t-warn">${fmt.errorMessage(gateReply)}</p>`}
          <p>${ACCESS_CODE_HINT}</p>
        <//></div>`;
      case 'incompatible':
        return html`<div class="gate"><${Card} title="Не удалось подключиться к демону">
          <p class="t-error">${failure}</p>
          <p>Перезагрузите страницу, чтобы получить панель работающего демона.</p>
          <div class="row"><${Button} kind="primary" icon="refresh-cw" onClick=${() => win.location.reload()}>Перезагрузить страницу<//></div>
        <//></div>`;
      case 'first-run':
        return html`<div class="gate"><${Card} title="Первый запуск">
          <p>Выберите источник конфигурации:</p>
          <div class="gate-column">
            <${Button} kind="primary" disabled=${busy} onClick=${async () => {
              setBusy(true);
              const reply = await session.initLocal(connection);
              setBusy(false);
              if (reply.ok) open();
              else notify('error', fmt.errorMessage(reply));
            }}>Создать локальную конфигурацию<//>
            <${Button} icon="git-branch" disabled=${busy} onClick=${async () => {
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
          ${error.message && html`<p class="t-warn">${error.message}</p>`}
          ${error.version && html`<p>Формат конфигурации: v${error.version}</p>`}
          ${error.required && html`<p>Требуется remote-control: ${fmt.versionLabel(error.required)}</p>`}
          <div class="gate-column">
            ${options.map((option, index) => html`
              <${Button} key=${option.id} kind=${option.tone === 'danger' ? 'danger' : index === 0 ? 'primary' : 'neutral'} disabled=${busy} onClick=${async () => {
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
          <div class="row"><${Button} kind="primary" icon="refresh-cw" disabled=${busy} onClick=${() => open()}>Повторить<//></div>
        <//></div>`;
    }
  };

  // ── Каркас приложения ────────────────────────────────────────────────────
  const source = status ? fmt.sourceLabel(status.source) : null;
  const banner = hello && status && fmt.openPanel(hello, status, null) ? fmt.OPEN_PANEL_WARNING : null;
  const journalErrors = journal.filter((entry) => entry.level === 'error' && entry.id > journalSeen).length;
  const version = hello ? `essence-rc ${fmt.versionLabel(hello.version)}` : '';

  const screen = screenRoute(route);
  const Screen = SCREENS[screen.name];
  const screenName = screen.name;
  const body = restart === 'uninstall'
    ? html`<div class="gate"><${Card} title="essence-rc удалён"><p>Панель больше недоступна. Закройте эту вкладку.</p><//></div>`
    : restart === 'update'
      ? html`<div class="gate"><${Card} title="Демон перезапускается"><p class="t-dim">Переподключение…</p><//></div>`
      : phase === 'app'
        ? html`<${Layout} menu=${menuEntries(screenName)} source=${source} linkState=${linkState}
              activity=${activity ? fmt.activityIndicator(activity) : null} banner=${banner}
              themeChoice=${themeChoice} onTheme=${setTheme} version=${version} journalErrors=${journalErrors}>
            <${Screen} key=${router.screenKey(screen)} ctx=${ctx} param=${route.param} tab=${route.tab} />
          <//>`
        : gateView();

  return html`
    ${body}
    <${Snackbars} items=${snacks} journalHref=${phase === 'app' ? href('journal') : null}
      onDismiss=${(id) => setSnacks((current) => current.filter((item) => item.id !== id))} />
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
    ${message && html`<p class="t-warn">${message}</p>`}
    <form class="form" onSubmit=${(event) => { event.preventDefault(); onSubmit(value, keep); setValue(''); }}>
      <${SecretField} label=${label} value=${value} onInput=${setValue} />
      ${remember && html`<${Checkbox} label="Сохранить ключ расшифровки на этом устройстве" checked=${keep} onChange=${setKeep} />`}
      <div class="row">
        <${Button} kind="primary" type="submit" disabled=${busy || !value}>Открыть<//>
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
 * - `request(argv, { secrets, input, onLog, expect, operation, quiet })` → ответ;
 *   текст ошибки показывается здесь ровно один раз (кроме планов, `*_required`
 *   и кодов `expect`); с `quiet` — только записью «warn» в журнале (такая же
 *   запись подряд не повторяется: фоновые чтения идут на каждую правку), без
 *   снэкбара; `operation` — заголовок окна операции со строками журнала;
 * - `confirm`, `askSecret`, `ask`, `choose`, `form`, `show`, `operation` — диалоги;
 *   `dialogOpen()` — открыто ли окно (горячие клавиши экрана поверх окон молчат);
 * - `runConfirmed(title, question, argv, { secrets, input })`,
 *   `nodeRequest(name, argv, review)` — `flows.js` с этим контекстом;
 * - `failed()` — «Операция завершилась ошибкой…» для отказов без текста ядра;
 * - `navigate(name, param, tab)`, `href(name, param, tab)`, `terminal(argv, title)` →
 *   ответ после закрытия оверлея (`{ expect }` — как у `request`), `wizard(mode)` →
 *   `true` при успехе мастера GitHub, `restart('update'|'uninstall')`,
 *   `refreshStatus()`, `hello`, `status`;
 * - `journal`, `clearJournal()`, `theme: { choice, dark, set(choice) }` (`dark` — применённая тема),
 *   `setLeaveGuard(async () => boolean | null)` — вопрос перед уходом с экрана;
 * - `win` — окно панели (обработчики клавиш экрана — на нём, не на глобальном `window`).
 */
function makeContext({ connection, dialogs, notify, record, hello, status, win, refreshStatus, openTerminal, restart, journal, clearJournal, theme, setLeaveGuard }) {
  // Закрытие окон при смене экрана — дело каркаса, не экранов.
  const { cancelAll, ...dialogApi } = dialogs;
  const ctx = {
    hello,
    status,
    notify,
    journal,
    clearJournal,
    theme,
    setLeaveGuard,
    win,
    ...dialogApi,
    async request(argv, options = {}) {
      const { secrets, input, onLog, expect = null, operation = null, quiet = false } = options;
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
      if (!silent(reply, expect)) {
        // Фоновое чтение с `quiet`: экран показывает недоступность сам, причина — в журнале.
        if (quiet) record('warn', fmt.errorMessage(reply), { repeat: false });
        else notify('error', fmt.errorMessage(reply));
      }
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
    navigate: (name, param = null, tab = null) => router.navigate(win, name === 'summary' ? '' : name, param, tab),
    href,
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
