// Модальные диалоги экранов — аналог `Context::confirm/secret/select/toggle`
// TUI: каждый вызов возвращает `Promise`, окно закрывается ответом. Диалоги
// складываются стопкой (подтверждение поверх окна операции); фокус — в
// верхнем окне, после закрытия возвращается туда, откуда окно открыто.
import { html, useState, useEffect, useRef } from '../vendor/preact-htm.js';
import { Button, useModalFocus } from './ui.js';

/**
 * Хранилище стопки диалогов. `push(kind, props)` → `Promise` ответа.
 * Возвращает `{ stack, api }`; `api` — функции для `ctx`.
 */
export function useDialogs() {
  const [stack, setStack] = useState([]);
  const counter = useRef(0);
  /** Открыть окно: `{ promise, close }`; `close` доступен сразу, до отрисовки. */
  const open = (kind, props) => {
    counter.current += 1;
    const id = counter.current;
    let resolve;
    const promise = new Promise((done) => { resolve = done; });
    const close = (value) => {
      setStack((current) => current.filter((entry) => entry.id !== id));
      resolve(value);
    };
    setStack((current) => [...current, { id, kind, props, close }]);
    return { promise, close };
  };
  const push = (kind, props) => open(kind, props).promise;
  const api = {
    /** План/вопрос → `true` только по «Да». */
    confirm: (props) => push('confirm', props),
    /** Скрытый ввод; отмена → `null`; пустое значение → `null`, с `allowEmpty` → `''`. */
    askSecret: (props) => push('secret', props),
    /** Строка текста; отмена → `null`, пустая строка допустима. */
    ask: (props) => push('text', props),
    /** Один из списка (`options: [{value,label,tone?}]`); отмена → `null`. */
    choose: (props) => push('choose', props),
    /** Несколько из списка; `selected` — исходные отметки; отмена → `null`. */
    toggle: (props) => push('toggle', props),
    /** Окно с содержимым (`lines` или `body`), закрывается кнопкой. */
    show: (props) => push('show', props),
    /**
     * Окно операции: строки журнала команды (адреса — ссылками). Возвращает
     * `{ log(entry), finish() }`. После `finish()` окно без строк закрывается
     * само, со строками — остаётся для чтения с кнопкой «Закрыть». Состояние
     * хранится вне компонента, поэтому `finish()` до отрисовки не теряется.
     */
    operation: (title) => {
      const shared = { lines: [], finished: false, update: null };
      const handle = open('operation', { title, shared });
      const refresh = () => { if (shared.update) shared.update({ lines: shared.lines, finished: shared.finished }); };
      return {
        log(entry) {
          shared.lines = [...shared.lines, entry];
          refresh();
        },
        finish() {
          shared.finished = true;
          if (shared.lines.length === 0) handle.close(undefined);
          else refresh();
        },
      };
    },
  };
  return { stack, api };
}

const TONE_KIND = { view: 'view', create: 'create', change: 'change', danger: 'danger', plain: 'plain' };

/**
 * Рамка окна. Фокус при открытии — на самом окне (Enter не подтверждает
 * план случайно), поля ввода ставят его на себя.
 */
function Shell({ title, context, wide = false, children }) {
  const lines = Array.isArray(context) ? context : context ? [context] : [];
  const modal = useRef(null);
  useModalFocus(modal);
  return html`
    <div class="overlay" role="dialog" aria-modal="true" aria-label=${title}>
      <div class="modal ${wide ? 'modal-wide' : ''}" ref=${modal} tabindex="-1">
        <h3>${title}</h3>
        ${lines.length > 0 && html`<div class="modal-context">${lines.map((line, index) => html`<div key=${index}>${line}</div>`)}</div>`}
        ${children}
      </div>
    </div>
  `;
}

function ConfirmDialog({ props, close }) {
  const { title = 'Подтверждение', plan = [], context = null, question, yes = 'Да', tone = 'change' } = props;
  return html`<${Shell} title=${title} context=${context}>
    ${plan && plan.length > 0 && html`<pre class="plan">${plan.join('\n')}</pre>`}
    ${question && html`<p class="question">${question}</p>`}
    <div class="modal-buttons">
      <${Button} kind=${TONE_KIND[tone] || 'change'} onClick=${() => close(true)}>${yes}<//>
      <${Button} onClick=${() => close(false)}>Отмена<//>
    </div>
  <//>`;
}

function InputDialog({ props, close, secret }) {
  const { title, label, context = null, value: initial = '', placeholder = '', multiline = false, submit = 'Отправить', allowEmpty = false } = props;
  const [value, setValue] = useState(secret ? '' : initial);
  const ref = useRef(null);
  useEffect(() => { if (ref.current) ref.current.focus(); }, []);
  const done = () => {
    if (secret) close(value || allowEmpty ? value : null);
    else close(value);
  };
  return html`<${Shell} title=${title} context=${context} wide=${multiline}>
    <form class="form" onSubmit=${(event) => { event.preventDefault(); done(); }}>
      <label class="field">
        <span class="field-label">${label}</span>
        ${multiline
          ? html`<textarea ref=${ref} class="code" rows="16" value=${value} onInput=${(event) => setValue(event.target.value)}></textarea>`
          : html`<input ref=${ref} type=${secret ? 'password' : 'text'} autocomplete="off" placeholder=${placeholder} value=${value}
              onInput=${(event) => setValue(event.target.value)} />`}
      </label>
      ${secret && !allowEmpty && html`<p class="dim">Пустое значение — отмена.</p>`}
      <div class="modal-buttons">
        <${Button} kind="create" type="submit">${submit}<//>
        <${Button} onClick=${() => close(null)}>Отмена<//>
      </div>
    </form>
  <//>`;
}

function ChooseDialog({ props, close }) {
  const { title, context = null, options = [], empty = 'Нет объектов для выбора', cancel = 'Отмена' } = props;
  return html`<${Shell} title=${title} context=${context}>
    ${options.length === 0 && html`<p class="dim">${empty}</p>`}
    <div class="modal-buttons column">
      ${options.map((option) => html`
        <${Button} key=${String(option.value)} kind=${TONE_KIND[option.tone] || 'view'} disabled=${option.disabled}
          onClick=${() => close(option.value)}>${option.label}<//>
      `)}
      <${Button} onClick=${() => close(null)}>${cancel}<//>
    </div>
  <//>`;
}

function ToggleDialog({ props, close }) {
  const { title, context = null, options = [], selected = [], empty = 'Нет объектов для выбора', submit = 'Сохранить' } = props;
  const [value, setValue] = useState([...selected]);
  const flip = (item) => setValue(value.includes(item) ? value.filter((v) => v !== item) : [...value, item]);
  return html`<${Shell} title=${title} context=${context}>
    ${options.length === 0
      ? html`<p class="dim">${empty}</p>`
      : html`<div class="toggle">
          ${options.map((option) => html`
            <label key=${String(option.value)} class="checkbox">
              <input type="checkbox" checked=${value.includes(option.value)} onChange=${() => flip(option.value)} />
              <span>${option.label}</span>
            </label>
          `)}
        </div>`}
    <div class="modal-buttons">
      ${options.length > 0 && html`<${Button} kind="change" onClick=${() => close(options.map((o) => o.value).filter((v) => value.includes(v)))}>${submit}<//>`}
      <${Button} onClick=${() => close(null)}>Отмена<//>
    </div>
  <//>`;
}

function ShowDialog({ props, close }) {
  const { title, context = null, lines = null, body = null, wide = false, close: label = 'Закрыть' } = props;
  return html`<${Shell} title=${title} context=${context} wide=${wide}>
    ${lines && html`<pre class="plan">${lines.join('\n')}</pre>`}
    ${body}
    <div class="modal-buttons"><${Button} onClick=${() => close(undefined)}>${label}<//></div>
  <//>`;
}

const URL_RE = /(https?:\/\/[^\s«»"'<>]+)/g;

/** Строка с адресами-ссылками (`github-login`: код устройства и адрес). */
export function Linkified({ text }) {
  const parts = String(text).split(URL_RE);
  return parts.map((part, index) => (index % 2 === 1
    ? html`<a key=${index} href=${part} target="_blank" rel="noopener noreferrer">${part}</a>`
    : part));
}

function OperationDialog({ props, close }) {
  const { title, shared } = props;
  const [view, setView] = useState({ lines: shared.lines, finished: shared.finished });
  useEffect(() => {
    shared.update = setView;
    // Строки или завершение, пришедшие до подписки.
    setView({ lines: shared.lines, finished: shared.finished });
    return () => { shared.update = null; };
  }, []);
  return html`<${Shell} title=${title} wide=${true}>
    <div class="operation">
      ${view.lines.length === 0 && !view.finished && html`<p class="dim">Выполняется…</p>`}
      ${view.lines.map((entry, index) => html`
        <div key=${index} class="journal-line level-${entry.level || 'info'}"><${Linkified} text=${entry.text} /></div>
      `)}
    </div>
    ${view.finished && html`<div class="modal-buttons"><${Button} onClick=${() => close(undefined)}>Закрыть<//></div>`}
  <//>`;
}

const VIEWS = {
  confirm: ConfirmDialog,
  secret: (args) => InputDialog({ ...args, secret: true }),
  text: (args) => InputDialog({ ...args, secret: false }),
  choose: ChooseDialog,
  toggle: ToggleDialog,
  show: ShowDialog,
  operation: OperationDialog,
};

/** Отрисовка стопки диалогов. */
export function DialogHost({ stack }) {
  return stack.map((entry) => {
    const View = VIEWS[entry.kind];
    return html`<${View} key=${entry.id} props=${entry.props} close=${entry.close} />`;
  });
}
