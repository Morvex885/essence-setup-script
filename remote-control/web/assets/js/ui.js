// Компоненты веб-панели (Preact + htm). Обработчики навешиваются компонентами,
// не инлайн-атрибутами в разметке (CSP `default-src 'self'`). Тексты — русские.
import { html } from '../vendor/preact-htm.js';
import { useEffect, useRef, useState } from '../vendor/preact-htm.js';
import { readInputFile } from './format.js';

const TONE_CLASS = { ok: 'tone-ok', warn: 'tone-warn', error: 'tone-error', dim: 'tone-dim', info: 'tone-info' };

/** Строка с классом тона (`ok|warn|error|dim|info`). */
export function Tone({ tone = 'info', children }) {
  return html`<span class="${TONE_CLASS[tone] || TONE_CLASS.info}">${children}</span>`;
}

/** Каркас: боковое меню слева, шапка с индикаторами, контент, журнал снизу. */
export function Layout({ menu, indicators = [], banner = null, journal = null, journalOpen = false, onToggleJournal = () => {}, children }) {
  return html`
    <div class="app">
      <nav class="menu">
        <div class="menu-brand">Remote Control</div>
        ${menu.map((item) => html`
          <a key=${item.route} class="menu-item ${item.tone ? `menu-${item.tone}` : ''} ${item.active ? 'active' : ''}" href=${item.href}>${item.label}</a>
        `)}
        <button type="button" class="menu-journal" onClick=${onToggleJournal}>${journalOpen ? 'Скрыть журнал' : 'Журнал'}</button>
      </nav>
      <div class="main">
        <header class="header">
          <div class="indicators">
            ${indicators.map((indicator, index) => html`<${Tone} key=${index} tone=${indicator.tone || 'dim'}>${indicator.text}<//>`)}
          </div>
          ${banner && html`<div class="banner banner-warn">${banner}</div>`}
        </header>
        <main class="content">${children}</main>
        ${journalOpen && journal !== null && html`
          <section class="journal" aria-label="Журнал">
            ${journal.length === 0 && html`<div class="journal-empty">Журнал пуст</div>`}
            ${journal.map((entry, index) => html`<div key=${index} class="journal-line ${`level-${entry.level || 'info'}`}">${entry.text}</div>`)}
          </section>
        `}
      </div>
    </div>
  `;
}

/** Таблица: `columns` — `[{key,label}]`, `rows` — массивы объектов. */
export function Table({ columns, rows, empty = 'Нет объектов' }) {
  if (!rows || rows.length === 0) return html`<div class="empty">${empty}</div>`;
  return html`
    <table class="table">
      <thead><tr>${columns.map((column) => html`<th key=${column.key}>${column.label}</th>`)}</tr></thead>
      <tbody>
        ${rows.map((row, index) => html`
          <tr key=${index}>
            ${columns.map((column) => html`<td key=${column.key}>${column.render ? column.render(row) : (row[column.key] ?? '—')}</td>`)}
          </tr>
        `)}
      </tbody>
    </table>
  `;
}

/** Карточка-раздел с заголовком и строкой действий. */
export function Card({ title, actions = null, children }) {
  return html`
    <section class="card">
      <div class="card-head"><h2>${title}</h2>${actions && html`<div class="actions">${actions}</div>`}</div>
      <div class="card-body">${children}</div>
    </section>
  `;
}

/** Модальное окно; `plan` — строки замороженного плана, `question` — вопрос. */
export function Modal({ title, plan = null, question = null, context = null, buttons = null, children }) {
  return html`
    <div class="overlay" role="dialog" aria-modal="true">
      <div class="modal">
        <h3>${title}</h3>
        ${plan && plan.length > 0 && html`<pre class="plan">${plan.join('\n')}</pre>`}
        ${context && context.length > 0 && html`<div class="modal-context">${context.join('\n')}</div>`}
        ${question && html`<p class="question">${question}</p>`}
        ${children}
        ${buttons && html`<div class="modal-buttons">${buttons}</div>`}
      </div>
    </div>
  `;
}

/** Кнопка с классом действия (`view|create|change|danger|plain`). */
export function Button({ kind = 'plain', type = 'button', disabled = false, onClick, children }) {
  return html`<button type=${type} class="btn btn-${kind}" disabled=${disabled} onClick=${onClick}>${children}</button>`;
}

/** Форма: `onSubmit(formData)` вызывается по «Отправить». */
export function Form({ fields = [], submitLabel = 'Отправить', onSubmit, onCancel = null, busy = false, children }) {
  const [values, setValues] = useState(() => {
    const initial = {};
    for (const field of fields) initial[field.name] = field.value !== undefined ? field.value : '';
    return initial;
  });
  const update = (name, value) => setValues((current) => ({ ...current, [name]: value }));
  return html`
    <form class="form" onSubmit=${(event) => { event.preventDefault(); onSubmit({ ...values }); }}>
      ${fields.map((field) => html`
        <label key=${field.name} class="field">
          <span class="field-label">${field.label}</span>
          ${field.secret
            ? html`<input type="password" autocomplete="off" value=${values[field.name] || ''} onInput=${(event) => update(field.name, event.target.value)} />`
            : html`<input type=${field.type || 'text'} value=${values[field.name] || ''} onInput=${(event) => update(field.name, event.target.value)} />`}
        </label>
      `)}
      ${children}
      <div class="modal-buttons">
        <${Button} kind="create" type="submit" disabled=${busy}>${submitLabel}<//>
        ${onCancel && html`<${Button} onClick=${onCancel}>Отмена<//>`}
      </div>
    </form>
  `;
}

/** Поле формы с произвольным содержимым (`children` вместо input). */
export function Field({ label, children }) {
  return html`<label class="field"><span class="field-label">${label}</span>${children}</label>`;
}

/** Секретное поле: `type=password`, значение живёт только в состоянии формы. */
export function SecretField({ label, value, onInput, placeholder = '' }) {
  return html`
    <label class="field">
      <span class="field-label">${label}</span>
      <input type="password" autocomplete="off" placeholder=${placeholder} value=${value} onInput=${(event) => onInput(event.target.value)} />
    </label>
  `;
}

/** Флажок (`label` + `checkbox`). */
export function Checkbox({ label, checked, onChange }) {
  return html`
    <label class="checkbox">
      <input type="checkbox" checked=${checked} onChange=${(event) => onChange(event.target.checked)} />
      <span>${label}</span>
    </label>
  `;
}

/** Выбор ровно одного из списка. */
export function Picker({ label = null, options, value, onChange }) {
  return html`
    <${Field} label=${label}>
      <select value=${value} onChange=${(event) => onChange(event.target.value)}>
        ${options.map((option) => html`<option key=${option.value} value=${option.value}>${option.label}</option>`)}
      </select>
    <//>
  `;
}

/** Выбор нескольких из списка; отмеченное — в `value` (массив). */
export function Toggle({ options, value, onChange }) {
  const toggle = (optionValue) => {
    if (value.includes(optionValue)) onChange(value.filter((item) => item !== optionValue));
    else onChange([...value, optionValue]);
  };
  return html`
    <div class="toggle">
      ${options.map((option) => html`
        <label key=${option.value} class="checkbox">
          <input type="checkbox" checked=${value.includes(option.value)} onChange=${() => toggle(option.value)} />
          <span>${option.label}</span>
        </label>
      `)}
    </div>
  `;
}

/** Всплывающее сообщение; исчезает по таймеру `ttl` (мс). */
export function Toast({ toast, onDone }) {
  useEffect(() => {
    if (!toast) return undefined;
    const timer = setTimeout(onDone, toast.ttl || 6000);
    return () => clearTimeout(timer);
  }, [toast]);
  if (!toast) return null;
  return html`<div class="toast toast-${toast.level || 'info'}">${toast.text}</div>`;
}

/**
 * Кнопка копирования: буфер обмена; при отказе — видимое поле с выделенным
 * текстом (`execCommand('copy')`). «Скопировано» — только при успехе.
 */
export function CopyButton({ text, label = 'Копировать' }) {
  const [done, setDone] = useState(false);
  const [manual, setManual] = useState(false);
  const field = useRef(null);
  const copied = () => {
    setDone(true);
    setTimeout(() => setDone(false), 2000);
  };
  useEffect(() => {
    if (!manual || !field.current) return;
    field.current.focus();
    field.current.select();
    let ok = false;
    try { ok = document.execCommand('copy'); } catch { ok = false; }
    if (ok) copied();
  }, [manual]);
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(text);
      copied();
    } catch {
      if (manual && field.current) { field.current.focus(); field.current.select(); } else setManual(true);
    }
  };
  return html`
    <span class="copy">
      <${Button} kind="view" onClick=${copy}>${done ? 'Скопировано' : label}<//>
      ${manual && html`<input ref=${field} class="copy-manual mono" type="text" readonly value=${text}
        aria-label="Текст для копирования" onFocus=${(event) => event.target.select()} />`}
      ${manual && !done && html`<span class="dim">Текст выделен: скопируйте его (Ctrl+C).</span>`}
    </span>
  `;
}

/** Скачать текст файлом `name` (Blob и временная ссылка). */
export function downloadText(name, text, type = 'text/plain;charset=utf-8') {
  const url = URL.createObjectURL(new Blob([text], { type }));
  const anchor = document.createElement('a');
  anchor.href = url;
  anchor.download = name;
  anchor.click();
  // Отзыв сразу после `click()` может оборвать загрузку в части браузеров.
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

/** Кнопка скачивания текстового файла. */
export function Download({ name, text, label = 'Скачать' }) {
  return html`<${Button} kind="view" onClick=${() => downloadText(name, text)}>${label}<//>`;
}

/**
 * Чтение локального текстового файла: `onText(text)`, при отказе
 * `onText(null, причина)` (причина `null` — файл не читается или не в UTF-8).
 */
export function FileText({ onText, label = 'Выбрать файл', accept = '.txt,.yaml,.yml,.json,text/*', tone = 'view', disabled = false }) {
  const pick = async (event) => {
    const file = event.target.files && event.target.files[0];
    event.target.value = '';
    if (!file) return;
    const read = await readInputFile(file);
    onText(read.text ?? null, read.error ?? null);
  };
  return html`<label class="btn btn-${tone} file-text ${disabled ? 'disabled' : ''}" aria-disabled=${disabled}>${label}<input type="file" accept=${accept} disabled=${disabled} onChange=${pick} /></label>`;
}

/** Свернутый/развёрнутый блок моноширинного текста. */
export function Pre({ text, openLabel = 'Показать' }) {
  const [open, setOpen] = useState(false);
  return html`
    <div class="pre">
      <${Button} kind="view" onClick=${() => setOpen(!open)}>${open ? 'Скрыть' : openLabel}<//>
      ${open && html`<pre>${text}</pre>`}
    </div>
  `;
}
