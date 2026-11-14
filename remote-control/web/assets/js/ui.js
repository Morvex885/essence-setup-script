// Компоненты веб-панели (Preact + htm, разметка daisyUI 5). Обработчики
// навешиваются компонентами, не инлайн-атрибутами в разметке (CSP
// `default-src 'self'`). Тексты — русские. Чистая логика таблиц —
// `table-model.js`, форм — `form-model.js`.
import { html, useEffect, useRef, useState } from '../vendor/preact-htm.js';
import { readInputFile, asList } from './format.js';
import { THEME_OPTIONS } from './theme.js';
import { filterRows, cellText, allSelected, toggleVisible } from './table-model.js';
import { tabEdges } from './focus-model.js';
import { Icon } from './icons.js';

// ─── Кнопки ──────────────────────────────────────────────────────────────────

const KIND_CLASS = {
  primary: 'btn btn-sm btn-primary',
  neutral: 'btn btn-sm',
  danger: 'btn btn-sm btn-soft btn-error',
  ghost: 'btn btn-sm btn-ghost',
};

const kindClass = (kind) => KIND_CLASS[kind] || KIND_CLASS.neutral;

/** Кнопка: `kind` — `primary|neutral|danger|ghost`. */
export function Button({ kind = 'neutral', icon = null, type = 'button', disabled = false, title = null, onClick, children }) {
  return html`<button type=${type} class=${kindClass(kind)} disabled=${disabled} title=${title || undefined} onClick=${onClick}>
    ${icon && html`<${Icon} name=${icon} size=${16} />`}${children}
  </button>`;
}

/** Кнопка-иконка с подписью для экранного диктора и подсказкой. */
export function IconButton({ icon, label, onClick, disabled = false }) {
  return html`<button type="button" class="btn btn-sm btn-ghost btn-square" aria-label=${label} title=${label}
    disabled=${disabled} onClick=${onClick}><${Icon} name=${icon} size=${18} /></button>`;
}

/** Переключатель из нескольких кнопок (`options: [{value,label,icon?}]`). */
export function Segmented({ options, value, onChange, label = null }) {
  return html`<div class="join segmented" role="group" aria-label=${label || undefined}>
    ${options.map((option) => html`<button key=${option.value} type="button"
      class="btn btn-sm join-item ${option.value === value ? 'btn-active segmented-on' : ''}"
      aria-pressed=${option.value === value} onClick=${() => onChange(option.value)}>
      ${option.icon && html`<${Icon} name=${option.icon} size=${16} />`}${option.label}
    </button>`)}
  </div>`;
}

/** Узкий экран (`css/app.css`, `max-width: 639.98px`): меню разделов — по кнопке. */
const NARROW_QUERY = '(max-width: 639.98px)';

// ─── Каркас ──────────────────────────────────────────────────────────────────

/**
 * Каркас: меню разделов (≥1024 — с подписями, 640–1023 — иконки, <640 —
 * выезжающее по кнопке в шапке: фокус переходит в меню, Tab не выходит из
 * него, Esc и фон закрывают, фокус возвращается кнопке), выбор темы из трёх
 * вариантов, шапка с источником, связью и текущей командой, предупреждение
 * об открытой панели, область страницы.
 * `menu` — `[{name,label,icon,href,active}|{divider:true}]`, `source` —
 * `{ label, sync: {label,tone}|null }|null`, `activity` — текст или `null`.
 */
export function Layout({ menu, activity = null, source = null, linkState = 'open', banner = null, themeChoice = 'system',
  onTheme = () => {}, version = '', journalErrors = 0, children }) {
  const [open, setOpen] = useState(false);
  const nav = useRef(null);
  const burger = useRef(null);
  useEffect(() => {
    if (!open) return undefined;
    // Меню по кнопке — только на узком экране: при расширении окна до 640 px
    // оно становится постоянным, и удержание Tab в нём снимается.
    const narrow = typeof window.matchMedia === 'function' ? window.matchMedia(NARROW_QUERY) : null;
    if (narrow && !narrow.matches) { setOpen(false); return undefined; }
    const onWiden = () => { if (!narrow.matches) setOpen(false); };
    if (narrow) narrow.addEventListener('change', onWiden);
    const root = nav.current;
    const first = root && root.querySelector('a[href]');
    if (first) first.focus();
    const onKey = (event) => {
      // Над меню открыто окно или терминал: Esc и Tab — их (верхний слой).
      if (event.defaultPrevented || document.querySelector('.modal-open, .terminal-overlay')) return;
      if (event.key === 'Escape') setOpen(false);
      else if (event.key === 'Tab' && root) trapTab(root, event);
    };
    document.addEventListener('keydown', onKey);
    return () => {
      if (narrow) narrow.removeEventListener('change', onWiden);
      document.removeEventListener('keydown', onKey);
      // Скрытое меню уже могло сбросить фокус на `body`: возвращаем его кнопке.
      const active = document.activeElement;
      const lost = !active || active === document.body || (root && root.contains(active));
      if (lost && burger.current) burger.current.focus();
    };
  }, [open]);
  return html`
    <div class="shell ${open ? 'nav-open' : ''}">
      <aside class="shell-nav" aria-label="Разделы" ref=${nav}>
        <div class="shell-brand" title="Remote Control">
          <span class="shell-logo"><${Icon} name="terminal" size=${18} /></span>
          <span class="nav-label">Remote Control</span>
        </div>
        <ul class="menu shell-menu">
          ${menu.map((item, index) => (item.divider
            ? html`<li key=${`d${index}`} class="nav-divider" role="separator"></li>`
            : html`<li key=${item.name}>
                <a href=${item.href} class=${item.active ? 'menu-active' : ''} title=${item.label}
                  aria-current=${item.active ? 'page' : undefined} onClick=${() => setOpen(false)}>
                  <${Icon} name=${item.icon} size=${18} />
                  <span class="nav-label">${item.label}</span>
                  ${item.name === 'journal' && journalErrors > 0 && html`<span class="badge badge-error badge-xs nav-count"
                    aria-label=${`Ошибок: ${journalErrors}`}>${journalErrors}</span>`}
                </a>
              </li>`))}
        </ul>
        <div class="shell-foot">
          <div class="join nav-theme" role="group" aria-label="Тема оформления">
            ${THEME_OPTIONS.map((theme) => html`<button key=${theme.value} type="button"
              class="btn btn-xs btn-ghost btn-square join-item ${theme.value === themeChoice ? 'btn-active nav-theme-on' : ''}"
              aria-pressed=${theme.value === themeChoice} aria-label=${`Тема: ${theme.label}`} title=${`Тема: ${theme.label}`}
              onClick=${() => onTheme(theme.value)}><${Icon} name=${theme.icon} size=${16} /></button>`)}
          </div>
          ${version && html`<span class="nav-label nav-version t-dim">${version}</span>`}
        </div>
      </aside>
      <div class="shell-backdrop" onClick=${() => setOpen(false)}></div>
      <div class="shell-main">
        <header class="topbar">
          <button type="button" class="btn btn-sm btn-ghost btn-square topbar-burger" aria-label="Меню разделов" ref=${burger}
            aria-expanded=${open} onClick=${() => setOpen(!open)}><${Icon} name="menu" size=${20} /></button>
          ${source && html`<span class="topbar-source">
            <${Icon} name="git-branch" size=${16} /><span class="topbar-text">${source.label}</span>
            ${source.sync && html`<${Badge} tone=${source.sync.tone}>${source.sync.label}<//>`}
          </span>`}
          ${linkState === 'reconnecting' && html`<${Badge} tone="warn">нет связи<//>`}
          <span class="topbar-spacer"></span>
          ${activity && html`<span class="topbar-activity t-dim" title=${activity}>${activity}</span>`}
          ${activity && html`<progress class="progress progress-primary topbar-progress" aria-label="Выполняется команда"></progress>`}
        </header>
        ${banner && html`<div role="alert" class="alert alert-warning alert-soft shell-banner">
          <${Icon} name="triangle-alert" size=${18} /><span>${banner}</span>
        </div>`}
        <main class="page">${children}</main>
      </div>
    </div>
  `;
}

/**
 * Страница раздела: «Назад» (`back: {href,label}`), заголовок с отметкой,
 * действия, вкладки (`tabs: [{id,label,href,active}]` — ссылки маршрута,
 * текущая — `aria-current`) и содержимое.
 */
export function Page({ title, subtitle = null, back = null, badge = null, actions = null, tabs = null, children }) {
  return html`
    <div class="page-head">
      ${back && html`<a class="page-back" href=${back.href}><${Icon} name="arrow-left" size=${16} />${back.label}</a>`}
      <div class="page-title-row">
        <h1 class="page-title">${title}</h1>
        ${badge}
        ${actions && html`<div class="page-actions row">${actions}</div>`}
      </div>
      ${subtitle && html`<p class="page-subtitle t-dim">${subtitle}</p>`}
    </div>
    ${tabs && html`<nav class="tabs tabs-border page-tabs" aria-label="Вкладки">
      ${tabs.map((tab) => html`<a key=${tab.id} class="tab ${tab.active ? 'tab-active' : ''}" href=${tab.href}
        aria-current=${tab.active ? 'page' : undefined}>${tab.label}</a>`)}
    </nav>`}
    <div class="vstack">${children}</div>
  `;
}

// ─── Таблица ─────────────────────────────────────────────────────────────────

const SEARCH_FROM = 8;

/** Поле ввода, редактор или открытый диалог: «/» там — обычный символ. */
function typing(target) {
  if (!target || !target.closest) return false;
  return Boolean(target.closest('input, textarea, select, [contenteditable="true"], .modal, .terminal-overlay, .ace_editor'));
}

/**
 * Таблица: `columns` — `[{key,label,render?,search?}]`; первая колонка —
 * ссылка `href(row)`; `menu(row)` — пункты `MoreMenu`; `selection` —
 * `{ selected: [ключи], onChange }` («Выбрать все» — только видимые после
 * поиска строки); поиск — при `rows.length > 8` («/»).
 * На узком экране строки — карточки (подпись ячейки — `data-label`).
 */
export function DataTable({ columns, rows, rowKey = 'name', empty = 'Нет объектов', href = null, menu = null, selection = null }) {
  const [query, setQuery] = useState('');
  const search = useRef(null);
  const list = asList(rows);
  const searchable = list.length > SEARCH_FROM && columns.some((column) => column.search);
  useEffect(() => {
    if (!searchable) return undefined;
    const onKey = (event) => {
      if (event.key !== '/' || event.ctrlKey || event.metaKey || event.altKey || typing(event.target)) return;
      if (document.querySelector('.modal-open, .terminal-overlay')) return;
      event.preventDefault();
      if (search.current) search.current.focus();
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [searchable]);
  if (list.length === 0) return html`<div class="table-empty t-dim">${empty}</div>`;
  const keyOf = (row) => (typeof rowKey === 'function' ? rowKey(row) : row[rowKey]);
  const shown = searchable ? filterRows(list, columns, query) : list;
  const selected = selection ? selection.selected : [];
  const visibleKeys = shown.map(keyOf);
  const all = Boolean(selection) && allSelected(selected, visibleKeys);
  const flip = (key) => selection.onChange(selected.includes(key) ? selected.filter((item) => item !== key) : [...selected, key]);
  const cell = (column, row, index) => {
    const content = column.render ? column.render(row) : (cellText(row, column.key) || '—');
    return index === 0 && href ? html`<a class="cell-link" href=${href(row)}>${content}</a>` : content;
  };
  return html`
    ${searchable && html`<label class="input input-sm table-search">
      <${Icon} name="search" size=${16} />
      <input ref=${search} type="search" placeholder="Поиск" aria-label="Поиск по таблице" value=${query}
        onInput=${(event) => setQuery(event.target.value)}
        onKeyDown=${(event) => { if (event.key === 'Escape' && query) { event.stopPropagation(); setQuery(''); } }} />
      <kbd class="kbd kbd-sm">/</kbd>
    </label>`}
    ${shown.length === 0
      ? html`<div class="table-empty t-dim">Ничего не найдено</div>`
      : html`<div class="table-wrap"><table class="table data-table">
        <thead><tr>
          ${selection && html`<th class="col-check"><input type="checkbox" class="checkbox checkbox-sm"
            aria-label=${query ? 'Выбрать все найденные' : 'Выбрать все'}
            checked=${all} onChange=${() => selection.onChange(toggleVisible(selected, visibleKeys))} /></th>`}
          ${columns.map((column) => html`<th key=${column.key}>${column.label}</th>`)}
          ${menu && html`<th class="col-menu"><span class="sr-only">Действия</span></th>`}
        </tr></thead>
        <tbody>
          ${shown.map((row) => {
            const key = keyOf(row);
            return html`<tr key=${String(key)}>
              ${selection && html`<td class="col-check"><input type="checkbox" class="checkbox checkbox-sm"
                aria-label=${`Выбрать ${key}`} checked=${selected.includes(key)} onChange=${() => flip(key)} /></td>`}
              ${columns.map((column, index) => html`<td key=${column.key} data-label=${column.label}
                class=${index === 0 ? 'col-main' : ''}>${cell(column, row, index)}</td>`)}
              ${menu && html`<td class="col-menu"><${MoreMenu} items=${menu(row)} /></td>`}
            </tr>`;
          })}
        </tbody>
      </table></div>`}
  `;
}

// ─── Меню действий ───────────────────────────────────────────────────────────

/**
 * Меню «⋮»: `items` — `[{label,icon?,danger?,disabled?,onClick}]`. С явной
 * `label` — текстовая кнопка «label ▾». Закрывается выбором, Esc, нажатием
 * вне меню и уходом фокуса из меню (Tab); ↑/↓ — переход между пунктами.
 */
export function MoreMenu({ items, label }) {
  const [place, setPlace] = useState(null);
  const root = useRef(null);
  const button = useRef(null);
  const list = useRef(null);
  const name = label === undefined || label === null ? 'Действия' : label;
  const textual = label !== undefined && label !== null;
  const open = place !== null;
  const close = (focus = false) => {
    setPlace(null);
    if (focus && button.current) button.current.focus();
  };
  useEffect(() => {
    if (!open) return undefined;
    const outside = (event) => { if (root.current && !root.current.contains(event.target)) close(); };
    const away = (event) => { if (!list.current || !list.current.contains(event.target)) close(); };
    document.addEventListener('pointerdown', outside, true);
    window.addEventListener('resize', away);
    window.addEventListener('scroll', away, true);
    const first = list.current && list.current.querySelector('button:not([disabled])');
    if (first) first.focus();
    return () => {
      document.removeEventListener('pointerdown', outside, true);
      window.removeEventListener('resize', away);
      window.removeEventListener('scroll', away, true);
    };
  }, [open]);
  const toggle = () => {
    if (open) { close(); return; }
    const rect = button.current.getBoundingClientRect();
    const below = window.innerHeight - rect.bottom;
    const style = { right: Math.max(8, window.innerWidth - rect.right) };
    if (below < 260 && rect.top > below) style.bottom = window.innerHeight - rect.top + 4;
    else style.top = rect.bottom + 4;
    setPlace(style);
  };
  const onKey = (event) => {
    if (!open) return;
    if (event.key === 'Escape') { event.preventDefault(); event.stopPropagation(); close(true); return; }
    if (event.key !== 'ArrowDown' && event.key !== 'ArrowUp') return;
    event.preventDefault();
    const buttons = [...list.current.querySelectorAll('button:not([disabled])')];
    if (buttons.length === 0) return;
    const index = buttons.indexOf(document.activeElement);
    const step = event.key === 'ArrowDown' ? 1 : -1;
    buttons[(index + step + buttons.length) % buttons.length].focus();
  };
  const style = place ? Object.entries(place).map(([key, value]) => `${key}:${value}px`).join(';') : '';
  // Фокус ушёл за пределы меню (Tab, щелчок по другому полю) — меню закрывается.
  // Свойство в нижнем регистре: Preact подписывается на `focusout` как есть.
  const onFocusOut = (event) => { if (open && root.current && !root.current.contains(event.relatedTarget)) close(); };
  return html`<div class="more" ref=${root} onKeyDown=${onKey} onfocusout=${onFocusOut}>
    ${textual
      ? html`<button ref=${button} type="button" class="btn btn-sm" aria-haspopup="menu" aria-expanded=${open}
          onClick=${toggle}>${name}<${Icon} name="chevron-down" size=${16} /></button>`
      : html`<button ref=${button} type="button" class="btn btn-sm btn-ghost btn-square" aria-haspopup="menu"
          aria-expanded=${open} aria-label=${name} title=${name} onClick=${toggle}><${Icon} name="ellipsis-vertical" size=${18} /></button>`}
    ${open && html`<ul ref=${list} class="menu more-list" role="menu" style=${style}
      onMouseDown=${(event) => event.preventDefault()}>
      ${items.map((item, index) => html`<li key=${index} role="none">
        <button type="button" role="menuitem" class=${item.danger ? 't-error' : ''} disabled=${item.disabled}
          onClick=${() => { close(true); item.onClick(); }}>
          ${item.icon && html`<${Icon} name=${item.icon} size=${16} />`}${item.label}
        </button>
      </li>`)}
    </ul>`}
  </div>`;
}

// ─── Блоки содержимого ───────────────────────────────────────────────────────

/** Карточка с необязательными заголовком и действиями. */
export function Card({ title = null, actions = null, className = '', children }) {
  return html`<section class="card card-border panel ${className}">
    <div class="card-body">
      ${(title || actions) && html`<div class="card-top">
        ${title && html`<h2 class="card-title">${title}</h2>`}
        ${actions && html`<div class="row card-actions-row">${actions}</div>`}
      </div>`}
      ${children}
    </div>
  </section>`;
}

/** Пары «подпись — значение»; `value` `null`/`undefined`/`false`/`''` — строка пропускается. */
export function Facts({ items }) {
  const shown = (items || []).filter((item) => item && item.value !== null && item.value !== undefined && item.value !== false && item.value !== '');
  return html`<dl class="facts">
    ${shown.map((item) => html`<div key=${item.label} class="fact"><dt>${item.label}</dt><dd>${item.value}</dd></div>`)}
  </dl>`;
}

const BADGE_CLASS = { ok: 'badge-success', warn: 'badge-warning', error: 'badge-error', info: 'badge-info', neutral: 'badge-ghost', dim: 'badge-ghost' };

/** Отметка состояния: `tone` — `ok|warn|error|info|neutral`. */
export function Badge({ tone = 'neutral', children }) {
  return html`<span class="badge badge-soft badge-sm ${BADGE_CLASS[tone] || BADGE_CLASS.neutral}">${children}</span>`;
}

/** Набор отметок-ссылок: `items` — `[{label,href?}]`. */
export function Chips({ items, empty = 'нет' }) {
  const list = (items || []).filter(Boolean);
  if (list.length === 0) return html`<span class="t-dim">${empty}</span>`;
  return html`<span class="chips">
    ${list.map((item) => (item.href
      ? html`<a key=${item.label} class="badge badge-outline badge-sm chip" href=${item.href}>${item.label}</a>`
      : html`<span key=${item.label} class="badge badge-ghost badge-sm chip">${item.label}</span>`))}
  </span>`;
}

/** Пустое состояние: иконка, заголовок, пояснение, действие. */
export function Empty({ icon = 'info', title, hint = null, action = null }) {
  return html`<div class="empty-state">
    <span class="empty-icon"><${Icon} name=${icon} size=${28} /></span>
    <p class="empty-title">${title}</p>
    ${hint && html`<p class="t-dim">${hint}</p>`}
    ${action && html`<div class="row">${action}</div>`}
  </div>`;
}

/** Ряд показателей (`Stat`). */
export function Stats({ children }) {
  return html`<div class="stats stats-row">${children}</div>`;
}

/** Показатель-ссылка на раздел. */
export function Stat({ label, value, href }) {
  return html`<a class="stat" href=${href}>
    <div class="stat-title">${label}</div>
    <div class="stat-value">${value}</div>
  </a>`;
}

const SNACK_CLASS = { success: 'alert-success', warn: 'alert-warning', error: 'alert-error', info: 'alert-info' };
const SNACK_ICON = { success: 'circle-check', warn: 'triangle-alert', error: 'circle-alert', info: 'info' };

function Snackbar({ item, onDismiss, journalHref }) {
  useEffect(() => {
    if (item.level === 'error') return undefined;
    const timer = setTimeout(() => onDismiss(item.id), 5000);
    return () => clearTimeout(timer);
  }, [item.id]);
  return html`<div class="alert alert-soft ${SNACK_CLASS[item.level] || SNACK_CLASS.info} snack"
    role=${item.level === 'error' ? 'alert' : 'status'}>
    <${Icon} name=${SNACK_ICON[item.level] || 'info'} size=${18} />
    <span class="snack-text">${item.text}</span>
    ${journalHref && html`<a class="link snack-link" href=${journalHref} onClick=${() => onDismiss(item.id)}>Журнал</a>`}
    <${IconButton} icon="x" label="Закрыть" onClick=${() => onDismiss(item.id)} />
  </div>`;
}

/** Всплывающие сообщения: успех и предупреждение исчезают через 5 с, ошибка — только кнопкой. */
export function Snackbars({ items, onDismiss, journalHref = null }) {
  if (!items || items.length === 0) return null;
  return html`<div class="toast toast-end toast-bottom snackbars">
    ${items.map((item) => html`<${Snackbar} key=${item.id} item=${item} onDismiss=${onDismiss} journalHref=${journalHref} />`)}
  </div>`;
}

// ─── Фокус модальных слоёв ───────────────────────────────────────────────────

const FOCUSABLE = 'button:not([disabled]), a[href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';

/**
 * Tab и Shift+Tab по кругу внутри `root`; фокус снаружи (щелчок по фону)
 * возвращается на первый или последний элемент слоя. Края — по настоящей
 * последовательности Tab (`tabEdges`: radio-группа — одна остановка).
 */
function trapTab(root, event) {
  const items = [...root.querySelectorAll(FOCUSABLE)].filter((item) => item.getClientRects().length > 0);
  const active = document.activeElement;
  const { atFirst, atLast, first, last } = tabEdges(items, active);
  if (!first) { event.preventDefault(); root.focus(); return; }
  if (!root.contains(active)) { event.preventDefault(); (event.shiftKey ? last : first).focus(); return; }
  if (event.shiftKey && (atFirst || active === root)) { event.preventDefault(); last.focus(); }
  else if (!event.shiftKey && atLast) { event.preventDefault(); first.focus(); }
}

/**
 * Фокус модального слоя `ref`: при открытии переходит в слой (`initial()` или
 * сам слой, если фокус ещё снаружи), Tab и Shift+Tab не выходят из слоя, при
 * закрытии фокус возвращается элементу, с которого слой открыт. Обработчик
 * стоит на документе, поэтому работает и после щелчка мимо слоя; `isActive()`
 * — слой верхний (у стопки диалогов Tab ловит только верхнее окно). Слой
 * должен принимать фокус (`tabindex="-1"`).
 */
export function useModalFocus(ref, initial = null, isActive = null) {
  const opener = useRef(document.activeElement);
  useEffect(() => {
    const root = ref.current;
    if (!root.contains(document.activeElement)) ((initial && initial(root)) || root).focus();
    const trap = (event) => {
      if (event.key !== 'Tab' || event.defaultPrevented || (isActive && !isActive())) return;
      trapTab(root, event);
    };
    document.addEventListener('keydown', trap);
    return () => {
      document.removeEventListener('keydown', trap);
      const target = opener.current;
      if (target && target.isConnected && typeof target.focus === 'function') target.focus();
    };
  }, []);
}

// ─── Поля и файлы ────────────────────────────────────────────────────────────

/** Секретное поле: `type=password`, значение живёт только в состоянии формы. */
export function SecretField({ label, value, onInput, placeholder = '' }) {
  return html`
    <label class="field">
      <span class="field-label">${label}</span>
      <input type="password" class="input input-sm" autocomplete="off" placeholder=${placeholder} value=${value}
        onInput=${(event) => onInput(event.target.value)} />
    </label>
  `;
}

/** Флажок (`label` + `checkbox`). */
export function Checkbox({ label, checked, onChange }) {
  return html`
    <label class="check-row">
      <input type="checkbox" class="checkbox checkbox-sm" checked=${checked} onChange=${(event) => onChange(event.target.checked)} />
      <span>${label}</span>
    </label>
  `;
}

/**
 * Кнопка копирования: буфер обмена; при отказе — видимое поле с выделенным
 * текстом (`execCommand('copy')`). «Скопировано» — только при успехе.
 */
export function CopyButton({ text, label = 'Копировать', kind = 'neutral' }) {
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
      <${Button} kind=${kind} icon=${done ? 'check' : 'copy'} onClick=${copy}>${done ? 'Скопировано' : label}<//>
      ${manual && html`<input ref=${field} class="input input-sm copy-manual mono" type="text" readonly value=${text}
        aria-label="Текст для копирования" onFocus=${(event) => event.target.select()} />`}
      ${manual && !done && html`<span class="t-dim">Текст выделен: скопируйте его (Ctrl+C).</span>`}
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

/**
 * Чтение локального текстового файла: `onText(text)`, при отказе
 * `onText(null, причина)` (причина `null` — файл не читается или не в UTF-8).
 */
export function FileText({ onText, label = 'Выбрать файл', accept = '.txt,.yaml,.yml,.json,text/*', kind = 'neutral', disabled = false }) {
  const pick = async (event) => {
    const file = event.target.files && event.target.files[0];
    event.target.value = '';
    if (!file) return;
    const read = await readInputFile(file);
    onText(read.text ?? null, read.error ?? null);
  };
  return html`<label class="${kindClass(kind)} file-text ${disabled ? 'btn-disabled' : ''}" aria-disabled=${disabled}>
    <${Icon} name="upload" size=${16} />${label}
    <input type="file" accept=${accept} disabled=${disabled} onChange=${pick} />
  </label>`;
}
