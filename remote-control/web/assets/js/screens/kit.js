// Общие помощники экранов: чтение данных командой с повтором, занятость на
// время действия, кнопки действий с цветами скилла essence-menus, строки
// контекста. Экран получает `ctx` (см. `app.js::makeContext`).
import { html, useEffect, useState, useRef } from '../../vendor/preact-htm.js';
import { Button, Card } from '../ui.js';

/**
 * Чтение командой при входе и по `reload()`. `argv === null` — не читать.
 * Возвращает `{ reply, data, loading, reload }`. Ошибка уже показана `ctx.request`,
 * кроме кодов `expect` (например, `not_found` карточки, после которого экран
 * возвращается к списку).
 */
export function useCommand(ctx, argv, deps = [], { expect = null } = {}) {
  const [state, setState] = useState({ reply: null, loading: argv !== null });
  const generation = useRef(0);
  const key = argv === null ? null : JSON.stringify(argv);
  const load = async () => {
    if (argv === null) return null;
    generation.current += 1;
    const mine = generation.current;
    setState((current) => ({ ...current, loading: true }));
    const reply = await ctx.request(argv, { expect });
    if (mine === generation.current) setState({ reply, loading: false });
    return reply;
  };
  useEffect(() => { load(); }, [key, ...deps]);
  return { reply: state.reply, data: state.reply && state.reply.ok ? state.reply.data : null, loading: state.loading, reload: load };
}

/**
 * Несколько чтений сразу (`{ name: argv }`) — все повторяются вместе.
 * Возвращает `{ replies, data, loading, reload, failed }`.
 */
export function useCommands(ctx, map, deps = []) {
  const [state, setState] = useState({ replies: null, loading: true });
  const generation = useRef(0);
  const key = JSON.stringify(map);
  const load = async () => {
    generation.current += 1;
    const mine = generation.current;
    setState((current) => ({ ...current, loading: true }));
    const names = Object.keys(map).filter((name) => map[name] !== null);
    const results = await Promise.all(names.map((name) => ctx.request(map[name])));
    const replies = {};
    names.forEach((name, index) => { replies[name] = results[index]; });
    if (mine === generation.current) setState({ replies, loading: false });
    return replies;
  };
  useEffect(() => { load(); }, [key, ...deps]);
  const data = {};
  let failed = null;
  if (state.replies) {
    for (const [name, reply] of Object.entries(state.replies)) {
      data[name] = reply.ok ? reply.data : null;
      if (!reply.ok && !failed) failed = reply;
    }
  }
  return { replies: state.replies, data: state.replies ? data : null, loading: state.loading, reload: load, failed };
}

/** `[busy, run]`: `run(async () => …)` блокирует кнопки экрана до конца. */
export function useBusy() {
  const [busy, setBusy] = useState(false);
  const run = async (action) => {
    if (busy) return undefined;
    setBusy(true);
    try { return await action(); } finally { setBusy(false); }
  };
  return [busy, run];
}

/**
 * `ref.current` — экран ещё смонтирован. Поздний ответ ушедшего экрана не
 * должен переводить пользователя из уже выбранного раздела.
 */
export function useMounted() {
  const mounted = useRef(true);
  useEffect(() => {
    mounted.current = true;
    return () => { mounted.current = false; };
  }, []);
  return mounted;
}

/** Кнопка действия: `tone` — `view|create|change|danger`. */
export function Action({ tone = 'view', disabled = false, onClick, children }) {
  return html`<${Button} kind=${tone} disabled=${disabled} onClick=${onClick}>${children}<//>`;
}

/** Ряд кнопок; `column` — столбцом. */
export function Actions({ column = false, children }) {
  return html`<div class="modal-buttons ${column ? 'column' : ''}">${children}</div>`;
}

/** Строки контекста; `{ text, tone }` или строка. `tone`: `ok|warn|error|dim|info`. */
export function Context({ lines }) {
  const items = (lines || []).filter((line) => line !== null && line !== undefined && line !== false);
  if (items.length === 0) return null;
  return html`<div class="context">
    ${items.map((line, index) => (typeof line === 'string'
      ? html`<div key=${index}>${line}</div>`
      : html`<div key=${index} class=${line.tone ? `tone-${line.tone}` : ''}>${line.text}</div>`))}
  </div>`;
}

/** Заголовок с кнопкой «Назад» (возврат к списку раздела). */
export function Back({ ctx, to, param = null, label = 'Назад' }) {
  return html`<${Button} onClick=${() => ctx.navigate(to, param)}>${label}<//>`;
}

/**
 * Экран чтения: пока нет ответа — «Загрузка…»; ошибка — «Не удалось получить
 * данные» с «Повторить чтение» (`nodes.rs::read_failed`); иначе `children(data)`.
 */
export function Loaded({ title, state, actions = null, children }) {
  if (!state.reply && !state.replies) {
    return html`<${Card} title=${title} actions=${actions}><p class="dim">Загрузка…</p><//>`;
  }
  const failed = state.reply ? (!state.reply.ok ? state.reply : null) : state.failed;
  if (failed) {
    return html`<${Card} title=${title} actions=${actions}>
      <p class="tone-warn">Не удалось получить данные</p>
      ${failed.error && failed.error.message && html`<p>${failed.error.message}</p>`}
      <${Actions}><${Action} tone="view" disabled=${state.loading} onClick=${() => state.reload()}>Повторить чтение<//><//>
    <//>`;
  }
  return children(state.data);
}

/** Строки массива ответа (`rows` в TUI): не массив → пустой список. */
export function rows(value) {
  return Array.isArray(value) ? value : [];
}
