// Общие действия клиентов, групп, генерации и подписок — перенос помощников
// `remote-control/tui/src/clients.rs` (`fetch`, `load`, `generate`, `headers`,
// `share`, `resolved_headers`). Вопросы TUI здесь — формы и диалоги `ctx`.
import { html, useEffect, useRef, useState } from '../../vendor/preact-htm.js';
import { CopyButton } from '../ui.js';
import { Context } from './kit.js';
import * as model from './clients-model.js';

const PLAN_CODES = ['confirmation_required', 'plan_changed'];

/** Команда действия; неуспех — предупреждение (`clients.rs::execute`). */
export async function execute(ctx, argv, options) {
  const reply = await ctx.request(argv, options);
  if (!reply.ok) ctx.failed();
  return reply;
}

/** Опасное действие по плану (`clients.rs::confirmed_with`). */
export async function confirmed(ctx, title, question, argv, options) {
  const reply = await ctx.runConfirmed(title, question, argv, options);
  if (!reply.ok && !PLAN_CODES.includes(reply.error && reply.error.code)) ctx.failed();
  return reply;
}

/** Чтение внутри действия: `{ data }` или `null` после предупреждения (`fetch`). */
export async function fetchData(ctx, argv) {
  const reply = await execute(ctx, argv);
  return reply.ok ? { data: reply.data } : null;
}

/**
 * Чтение подменю (`clients.rs::load`): `not_found` — выход, прочие сбои —
 * явный «Повторить». Возвращает `{ data }` или `null`.
 */
export async function loadData(ctx, title, argv) {
  for (;;) {
    const reply = await ctx.request(argv, { expect: 'not_found' });
    if (reply.ok) return { data: reply.data };
    if (reply.error && reply.error.code === 'not_found') return null;
    ctx.failed();
    const choice = await ctx.choose({
      title, context: ['Данные недоступны'], options: [{ value: 'retry', label: 'Повторить', tone: 'change' }], cancel: 'Назад',
    });
    if (choice !== 'retry') return null;
  }
}

/** Варианты поля `select` из строк списка: подпись — `label(row)` или имя. */
export function nameOptions(data, label = null) {
  return model.rowsOf(data)
    .filter((row) => row && typeof row.name === 'string')
    .map((row) => ({ value: row.name, label: label ? label(row) : row.name }));
}

/** Окно итога (`clients.rs::summary`). */
export function showSummary(ctx, title, data, fields, empty) {
  return ctx.show({ title, body: html`<${Context} lines=${model.summaryLines(data, fields, empty)} />` });
}

/**
 * `generate …` (`clients.rs::generate`): итог при успехе и при `partial`
 * (поля в `error`). `scope` — хвост argv: `['--all']`, `['--group', G]`, `['--client', C]`.
 */
export async function runGenerate(ctx, scope) {
  const reply = await ctx.request(['generate', ...scope]);
  const data = model.generateResult(reply);
  if (data === null) { ctx.failed(); return; }
  await showSummary(ctx, 'Итог генерации', data, model.GENERATE_FIELDS, 'Нет результатов');
}

/** Заголовки подписки клиента или группы (`clients.rs::headers`); `kind`: `client|group`. */
export async function showHeaders(ctx, kind, name) {
  const client = kind === 'client';
  for (;;) {
    const read = await loadData(ctx, 'Заголовки подписки', model.headersArgv(kind, name));
    if (!read) return;
    const choice = await ctx.choose({
      title: `Заголовки подписки: ${name}`,
      context: model.headerLines(read.data, client),
      options: [{ value: 'set', label: 'Установить', tone: 'change' }, { value: 'unset', label: 'Удалить', tone: 'danger' }],
      cancel: 'Назад',
    });
    if (choice === null || choice === undefined) return;
    if (choice === 'set') {
      const values = await ctx.form({
        title: 'Установить заголовок',
        fields: [
          { name: 'header', label: 'Имя заголовка', type: 'text', required: true, autofocus: true },
          { name: 'value', label: 'Значение', type: 'text', required: true },
        ],
        submit: 'Установить',
      });
      if (values === null || values === undefined) continue;
      await execute(ctx, model.headersArgv(kind, name, '--set', `${values.header}=${values.value}`));
    } else {
      const own = model.removableHeaders(read.data, client);
      const target = await ctx.choose({ title: 'Удаление заголовка', options: own.map((item) => ({ value: item, label: item, tone: 'danger' })) });
      if (target !== null && target !== undefined) await execute(ctx, model.headersArgv(kind, name, '--unset', target));
    }
  }
}

/** QR-код ссылки на `<canvas>`; без `window.qrcode` или при сбое — не рисуется. */
function QrCode({ text }) {
  const canvas = useRef(null);
  const [drawn, setDrawn] = useState(true);
  useEffect(() => {
    const target = canvas.current;
    if (!target || typeof window.qrcode !== 'function') { setDrawn(false); return; }
    try {
      const qr = window.qrcode(0, 'M');
      qr.addData(text);
      qr.make();
      const count = qr.getModuleCount();
      const scale = Math.max(2, Math.floor(256 / count));
      target.width = count * scale;
      target.height = count * scale;
      const draw = target.getContext('2d');
      draw.fillStyle = '#fff';
      draw.fillRect(0, 0, target.width, target.height);
      draw.fillStyle = '#000';
      for (let row = 0; row < count; row += 1) {
        for (let col = 0; col < count; col += 1) {
          if (qr.isDark(row, col)) draw.fillRect(col * scale, row * scale, scale, scale);
        }
      }
      setDrawn(true);
    } catch {
      setDrawn(false);
    }
  }, [text]);
  return html`<canvas ref=${canvas} class="qr" hidden=${!drawn} aria-label="QR-код ссылки подписки"></canvas>`;
}

/** Окно ссылки (`clients.rs::share_view`): URL, срок, заголовки, curl, JSON, QR. */
function ShareView({ share }) {
  return html`<div class="share">
    <div class="share-label">Ссылка</div>
    <div class="share-value mono">${share.url}</div>
    <div class="row">
      <${CopyButton} text=${share.url} label="Копировать ссылку" kind="primary" />
      <${CopyButton} text=${share.curl} label="Копировать curl" />
      <${CopyButton} text=${share.json} label="Копировать JSON" />
    </div>
    ${share.expires && html`<div class="share-label">Срок действия</div><div class="t-warn">${share.expires}</div>`}
    ${share.headers.length > 0 && html`
      <div class="share-label">Сервер отдаст эти заголовки</div>
      <div class="share-value mono">${share.headers.map((line, index) => html`<div key=${index}>${line}</div>`)}</div>`}
    <div class="share-label">curl</div>
    <div class="share-value mono">${share.curl}</div>
    <div class="share-label">JSON</div>
    <div class="share-value mono">${share.json}</div>
    ${share.qr !== null && html`<${QrCode} text=${share.qr} />`}
  </div>`;
}

/** `subscription show` и окно ссылки (`clients.rs::share`). */
export async function showShare(ctx, name) {
  const read = await fetchData(ctx, ['subscription', 'show', '--name', name]);
  if (!read) return;
  const share = model.shareModel(read.data || {});
  await ctx.show({ title: share.title, wide: true, body: html`<${ShareView} share=${share} />` });
}

/** Итоговые заголовки клиента с источником (`clients.rs::resolved_headers`). */
export async function resolvedHeaders(ctx, name) {
  const read = await fetchData(ctx, ['subscription', 'headers', '--client', name]);
  if (!read) return;
  await ctx.show({ title: `Итоговые заголовки: ${name}`, lines: model.headerLines(read.data, true) });
}
