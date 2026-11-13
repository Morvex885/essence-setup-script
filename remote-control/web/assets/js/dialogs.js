// Модальные диалоги экранов — аналог `Context::confirm/secret/select/toggle`
// TUI и формы `ctx.form`: каждый вызов возвращает `Promise`, окно
// закрывается ответом. Диалоги складываются стопкой (подтверждение поверх
// окна операции); фокус — в верхнем окне, Esc закрывает верхнее окно
// значением отмены, щелчок по фону окно не закрывает.
import { html, useState, useEffect, useRef } from '../vendor/preact-htm.js';
import { Button, useModalFocus } from './ui.js';
import { Icon } from './icons.js';
import { initialValues, visibleFields, validate, result } from './form-model.js';

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
    /** План/вопрос → `true` только по «Да»; отмена — `false`. */
    confirm: (props) => push('confirm', props),
    /** Скрытый ввод; отмена → `null`; пустое значение → `null`, с `allowEmpty` → `''`. */
    askSecret: (props) => push('secret', props),
    /** Строка текста; отмена → `null`, пустая строка допустима. */
    ask: (props) => push('text', props),
    /** Один из списка (`options: [{value,label,tone?}]`); отмена → `null`. */
    choose: (props) => push('choose', props),
    /** Несколько из списка; `selected` — исходные отметки; отмена → `null`. */
    toggle: (props) => push('toggle', props),
    /**
     * Форма: `{ title, context, fields, submit, tone, wide }` → значения
     * видимых полей или `null` при отмене (`form-model.js`).
     */
    form: (props) => push('form', props),
    /** Окно с содержимым (`lines` или `body`), закрывается кнопкой; итог — `undefined`. */
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

/**
 * Рамка окна. Фокус при открытии — на самом окне (Enter не подтверждает
 * план случайно), поля ввода ставят его на себя. Esc — `onDismiss()`
 * (обработчик стоит на окне: срабатывает только в верхнем окне с фокусом).
 */
function Shell({ title, context, wide = false, onDismiss = null, children }) {
  const lines = Array.isArray(context) ? context : context ? [context] : [];
  const modal = useRef(null);
  useModalFocus(modal);
  const onKey = (event) => {
    if (event.key !== 'Escape' || event.defaultPrevented) return;
    event.preventDefault();
    event.stopPropagation();
    if (onDismiss) onDismiss();
  };
  return html`
    <div class="modal modal-open" role="dialog" aria-modal="true" aria-label=${title}>
      <div class="modal-box ${wide ? 'modal-wide' : ''}" ref=${modal} tabindex="-1" onKeyDown=${onKey}>
        <h3 class="modal-title">${title}</h3>
        ${lines.length > 0 && html`<div class="modal-context">${lines.map((line, index) => html`<div key=${index}>${line}</div>`)}</div>`}
        ${children}
      </div>
    </div>
  `;
}

function ConfirmDialog({ props, close }) {
  const { title = 'Подтверждение', plan = [], context = null, question, yes = 'Да', tone = 'primary' } = props;
  return html`<${Shell} title=${title} context=${context} onDismiss=${() => close(false)}>
    ${plan && plan.length > 0 && html`<pre class="plan">${plan.join('\n')}</pre>`}
    ${question && html`<p class="question">${question}</p>`}
    <div class="modal-action">
      <${Button} kind="ghost" onClick=${() => close(false)}>Отмена<//>
      <${Button} kind=${tone === 'danger' ? 'danger' : 'primary'} onClick=${() => close(true)}>${yes}<//>
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
  return html`<${Shell} title=${title} context=${context} wide=${multiline} onDismiss=${() => close(null)}>
    <form class="form" onSubmit=${(event) => { event.preventDefault(); done(); }}>
      <label class="field">
        <span class="field-label">${label}</span>
        ${multiline
          ? html`<textarea ref=${ref} class="textarea code" rows="16" value=${value} onInput=${(event) => setValue(event.target.value)}></textarea>`
          : html`<input ref=${ref} class="input input-sm" type=${secret ? 'password' : 'text'} autocomplete="off" placeholder=${placeholder} value=${value}
              onInput=${(event) => setValue(event.target.value)} />`}
      </label>
      ${secret && !allowEmpty && html`<p class="t-dim">Пустое значение — отмена.</p>`}
      <div class="modal-action">
        <${Button} kind="ghost" onClick=${() => close(null)}>Отмена<//>
        <${Button} kind="primary" type="submit">${submit}<//>
      </div>
    </form>
  <//>`;
}

function ChooseDialog({ props, close }) {
  const { title, context = null, options = [], empty = 'Нет объектов для выбора', cancel = 'Отмена' } = props;
  return html`<${Shell} title=${title} context=${context} onDismiss=${() => close(null)}>
    ${options.length === 0
      ? html`<p class="t-dim">${empty}</p>`
      : html`<ul class="menu choose-list">
          ${options.map((option) => html`<li key=${String(option.value)}>
            <button type="button" class=${option.tone === 'danger' ? 't-error' : ''} disabled=${option.disabled}
              onClick=${() => close(option.value)}>${option.label}</button>
          </li>`)}
        </ul>`}
    <div class="modal-action"><${Button} kind="ghost" onClick=${() => close(null)}>${cancel}<//></div>
  <//>`;
}

function ToggleDialog({ props, close }) {
  const { title, context = null, options = [], selected = [], empty = 'Нет объектов для выбора', submit = 'Сохранить' } = props;
  const [value, setValue] = useState([...selected]);
  const flip = (item) => setValue(value.includes(item) ? value.filter((v) => v !== item) : [...value, item]);
  return html`<${Shell} title=${title} context=${context} onDismiss=${() => close(null)}>
    ${options.length === 0
      ? html`<p class="t-dim">${empty}</p>`
      : html`<div class="choice-list">
          ${options.map((option) => html`
            <label key=${String(option.value)} class="check-row">
              <input type="checkbox" class="checkbox checkbox-sm" checked=${value.includes(option.value)} onChange=${() => flip(option.value)} />
              <span>${option.label}</span>
            </label>
          `)}
        </div>`}
    <div class="modal-action">
      <${Button} kind="ghost" onClick=${() => close(null)}>Отмена<//>
      ${options.length > 0 && html`<${Button} kind="primary" onClick=${() => close(options.map((o) => o.value).filter((v) => value.includes(v)))}>${submit}<//>`}
    </div>
  <//>`;
}

// ─── Форма ───────────────────────────────────────────────────────────────────

const MULTI_FILTER_FROM = 8;

function MultiField({ field, value, onChange, invalid }) {
  const [query, setQuery] = useState('');
  const options = field.options || [];
  const needle = query.trim().toLowerCase();
  const shown = needle ? options.filter((option) => String(option.label).toLowerCase().includes(needle)) : options;
  const selected = Array.isArray(value) ? value : [];
  const flip = (item) => onChange(selected.includes(item) ? selected.filter((v) => v !== item) : [...selected, item]);
  return html`<div class="choice-box ${invalid ? 'choice-invalid' : ''}">
    ${options.length > MULTI_FILTER_FROM && html`<label class="input input-sm choice-filter">
      <${Icon} name="search" size=${16} />
      <input type="search" placeholder="Фильтр" aria-label=${`Фильтр: ${field.label}`} value=${query}
        onInput=${(event) => setQuery(event.target.value)}
        onKeyDown=${(event) => { if (event.key === 'Enter') event.preventDefault(); }} />
    </label>`}
    ${options.length === 0 && html`<p class="t-dim">Нет вариантов для выбора</p>`}
    <div class="choice-list" role="group" aria-label=${field.label}>
      ${shown.map((option) => html`<label key=${String(option.value)} class="check-row">
        <input type="checkbox" class="checkbox checkbox-sm" name=${field.name} disabled=${option.disabled}
          checked=${selected.includes(option.value)} onChange=${() => flip(option.value)} />
        <span>${option.label}${option.hint && html` <span class="t-dim">${option.hint}</span>`}</span>
      </label>`)}
    </div>
  </div>`;
}

function FormControl({ field, value, onChange, invalid }) {
  const common = { id: `f-${field.name}`, name: field.name, 'aria-invalid': invalid ? 'true' : undefined, autofocus: field.autofocus || undefined };
  switch (field.type) {
    case 'select':
      return html`<select ...${common} class="select select-sm ${invalid ? 'select-error' : ''}" value=${value}
        onChange=${(event) => onChange(event.target.value)}>
        ${(field.options || []).map((option) => html`<option key=${String(option.value)} value=${option.value}
          disabled=${option.disabled}>${option.label}</option>`)}
      </select>`;
    case 'radio':
      return html`<div class="choice-list ${invalid ? 'choice-invalid' : ''}" role="radiogroup" aria-label=${field.label}>
        ${(field.options || []).map((option) => html`<label key=${String(option.value)} class="check-row">
          <input type="radio" class="radio radio-sm" name=${field.name} disabled=${option.disabled}
            checked=${value === option.value} onChange=${() => onChange(option.value)} />
          <span>${option.label}${option.hint && html`<span class="choice-hint t-dim">${option.hint}</span>`}</span>
        </label>`)}
      </div>`;
    case 'multi':
      return html`<${MultiField} field=${field} value=${value} onChange=${onChange} invalid=${invalid} />`;
    case 'checkbox':
      return html`<label class="check-row">
        <input type="checkbox" class="checkbox checkbox-sm" name=${field.name} checked=${value === true}
          onChange=${(event) => onChange(event.target.checked)} />
        <span>${field.label}</span>
      </label>`;
    case 'textarea':
      return html`<textarea ...${common} class="textarea code ${invalid ? 'textarea-error' : ''}" rows="8"
        placeholder=${field.placeholder || ''} value=${value} onInput=${(event) => onChange(event.target.value)}></textarea>`;
    default:
      return html`<input ...${common} class="input input-sm ${invalid ? 'input-error' : ''}"
        type=${field.type === 'secret' ? 'password' : 'text'} autocomplete="off" placeholder=${field.placeholder || ''}
        value=${value} onInput=${(event) => onChange(event.target.value)} />`;
  }
}

function FormDialog({ props, close }) {
  const { title, context = null, fields = [], submit = 'Сохранить', tone = 'primary', wide = false } = props;
  const [values, setValues] = useState(() => initialValues(fields));
  const [errors, setErrors] = useState({});
  const body = useRef(null);
  const visible = visibleFields(fields, values);
  useEffect(() => {
    const target = body.current && (body.current.querySelector('[autofocus]')
      || body.current.querySelector('input:not([type=checkbox]):not([type=radio]):not([type=search]), select, textarea'));
    if (target) target.focus();
  }, []);
  const update = (name, value) => {
    setValues((current) => ({ ...current, [name]: value }));
    if (errors[name]) setErrors((current) => { const next = { ...current }; delete next[name]; return next; });
  };
  const send = (event) => {
    event.preventDefault();
    const found = validate(fields, values);
    setErrors(found);
    const first = visible.find((field) => found[field.name]);
    if (first) {
      const target = body.current && body.current.querySelector(`[name="${CSS.escape(first.name)}"]`);
      if (target) target.focus();
      return;
    }
    close(result(fields, values));
  };
  return html`<${Shell} title=${title} context=${context} wide=${wide} onDismiss=${() => close(null)}>
    <form class="form" ref=${body} onSubmit=${send} novalidate>
      ${visible.map((field) => {
        const error = errors[field.name];
        const id = `f-${field.name}`;
        return html`<div key=${field.name} class="field">
          ${field.type !== 'checkbox' && html`<label class="field-label" for=${id}>${field.label}${field.required && html`<span class="t-dim"> *</span>`}</label>`}
          <${FormControl} field=${{ ...field, name: field.name }} value=${values[field.name]} invalid=${Boolean(error)}
            onChange=${(value) => update(field.name, value)} />
          ${field.hint && !error && html`<span class="field-hint t-dim">${field.hint}</span>`}
          ${error && html`<span class="field-error" role="alert">${error}</span>`}
        </div>`;
      })}
      <div class="modal-action">
        <${Button} kind="ghost" onClick=${() => close(null)}>Отмена<//>
        <${Button} kind=${tone === 'danger' ? 'danger' : 'primary'} type="submit">${submit}<//>
      </div>
    </form>
  <//>`;
}

function ShowDialog({ props, close }) {
  const { title, context = null, lines = null, body = null, wide = false, close: label = 'Закрыть' } = props;
  return html`<${Shell} title=${title} context=${context} wide=${wide} onDismiss=${() => close(undefined)}>
    ${lines && html`<pre class="plan">${lines.join('\n')}</pre>`}
    ${body}
    <div class="modal-action"><${Button} onClick=${() => close(undefined)}>${label}<//></div>
  <//>`;
}

const URL_RE = /(https?:\/\/[^\s«»"'<>]+)/g;

/** Строка с адресами-ссылками (`github-login`: код устройства и адрес). */
export function Linkified({ text }) {
  const parts = String(text).split(URL_RE);
  return parts.map((part, index) => (index % 2 === 1
    ? html`<a key=${index} class="link" href=${part} target="_blank" rel="noopener noreferrer">${part}</a>`
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
  return html`<${Shell} title=${title} wide=${true} onDismiss=${() => { if (view.finished) close(undefined); }}>
    <div class="operation">
      ${view.lines.length === 0 && !view.finished && html`<p class="t-dim">Выполняется…</p>`}
      ${view.lines.map((entry, index) => html`
        <div key=${index} class="log-line level-${entry.level || 'info'}"><${Linkified} text=${entry.text} /></div>
      `)}
    </div>
    ${!view.finished && html`<progress class="progress progress-primary"></progress>`}
    ${view.finished && html`<div class="modal-action"><${Button} onClick=${() => close(undefined)}>Закрыть<//></div>`}
  <//>`;
}

const VIEWS = {
  confirm: ConfirmDialog,
  secret: (args) => InputDialog({ ...args, secret: true }),
  text: (args) => InputDialog({ ...args, secret: false }),
  choose: ChooseDialog,
  toggle: ToggleDialog,
  form: FormDialog,
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
