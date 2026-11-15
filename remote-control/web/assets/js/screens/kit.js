// Общие помощники экранов: чтение данных командой с повтором, занятость на
// время действия, строки контекста, «Загрузка…» и «Не удалось получить
// данные». Экран получает `ctx` (см. `app.js::makeContext`).
import { html, useEffect, useState, useRef } from '../../vendor/preact-htm.js';
import { Button, Card, Page } from '../ui.js';

/**
 * Чтение командой при входе и по `reload()`. `argv === null` — не читать.
 * Возвращает `{ reply, data, loading, reload }`. Ошибка уже показана `ctx.request`,
 * кроме кодов `expect` (например, `not_found` карточки, после которого экран
 * возвращается к списку) и `quiet`.
 */
export function useCommand(ctx, argv, deps = [], { expect = null, quiet = false } = {}) {
  const [state, setState] = useState({ reply: null, loading: argv !== null });
  const generation = useRef(0);
  const key = argv === null ? null : JSON.stringify(argv);
  const load = async () => {
    if (argv === null) return null;
    generation.current += 1;
    const mine = generation.current;
    setState((current) => ({ ...current, loading: true }));
    const reply = await ctx.request(argv, { expect, quiet });
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

/** Строки контекста; `{ text, tone }` или строка. `tone`: `ok|warn|error|dim|info`. */
export function Context({ lines }) {
  const items = (lines || []).filter((line) => line !== null && line !== undefined && line !== false);
  if (items.length === 0) return null;
  return html`<div class="context">
    ${items.map((line, index) => (typeof line === 'string'
      ? html`<div key=${index}>${line}</div>`
      : html`<div key=${index} class=${line.tone ? `t-${line.tone}` : ''}>${line.text}</div>`))}
  </div>`;
}

/** «Не удалось получить данные» с текстом ошибки и «Повторить чтение» (`nodes.rs::read_failed`). */
export function ReadFailed({ reply, loading = false, reload }) {
  return html`<div class="read-failed">
    <p class="t-warn">Не удалось получить данные</p>
    ${reply && reply.error && reply.error.message && html`<p>${reply.error.message}</p>`}
    <div class="row"><${Button} icon="refresh-cw" disabled=${loading} onClick=${() => reload()}>Повторить чтение<//></div>
  </div>`;
}

/**
 * Экран чтения: пока нет ответа — «Загрузка…»; ошибка — `ReadFailed`;
 * иначе `children(data)`. Без `inline` загрузка и ошибка показываются
 * страницей (`title`, `back`, `actions`), с `inline` — карточкой.
 */
export function Loaded({ title = null, back = null, state, actions = null, inline = false, children }) {
  const pending = !state.reply && !state.replies;
  const failed = pending ? null : state.reply ? (!state.reply.ok ? state.reply : null) : state.failed;
  if (!pending && !failed) return children(state.data);
  const body = pending
    ? html`<p class="t-dim">Загрузка…</p>`
    : html`<${ReadFailed} reply=${failed} loading=${state.loading} reload=${state.reload} />`;
  if (inline) return html`<${Card} title=${title}>${body}<//>`;
  return html`<${Page} title=${title} back=${back} actions=${actions}><${Card}>${body}<//><//>`;
}
