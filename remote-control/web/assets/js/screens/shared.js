// Общие действия клиентов, групп, шаблонов, генерации и подписок — перенос
// помощников `remote-control/tui/src/clients.rs` (`fetch`, `load`, `pick`,
// `generate`, `headers`, `share`, `client_subscription`). Подменю TUI здесь —
// цепочки диалогов `ctx`; функции завершаются, когда пользователь вышел.
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

/** Обязательный ответ: отмена — `null`, пустой — предупреждение и `null`. */
export async function required(ctx, title, label, missing) {
  const answer = await ctx.ask({ title, label });
  if (answer === null || answer === undefined) return null;
  if (answer === '') { ctx.notify('warn', missing); return null; }
  return answer;
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
      const header = await ctx.ask({ title: 'Установить заголовок', label: 'Имя заголовка' });
      if (header === null || header === undefined) continue;
      const value = await ctx.ask({ title: 'Установить заголовок', label: 'Значение', context: [header] });
      if (value === null || value === undefined) continue;
      if (header === '' || value === '') { ctx.notify('warn', 'Имя и значение заголовка обязательны.'); continue; }
      await execute(ctx, model.headersArgv(kind, name, '--set', `${header}=${value}`));
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
    <div class="field-label tone-ok">URL</div>
    <div class="mono">${share.url}</div>
    <${CopyButton} text=${share.url} label="Копировать ссылку" />
    ${share.expires && html`<p><span class="tone-warn">Срок действия: </span>${share.expires}</p>`}
    ${share.headers.length > 0 && html`
      <div class="section-title">Сервер отдаст эти заголовки:</div>
      <${Context} lines=${share.headers.map((line) => `  ${line}`)} />`}
    <div class="section-title">curl</div>
    <div class="mono">${share.curl}</div>
    <${CopyButton} text=${share.curl} label="Копировать curl" />
    <div class="section-title">JSON</div>
    <div class="mono">${share.json}</div>
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
async function resolvedHeaders(ctx, name) {
  const read = await fetchData(ctx, ['subscription', 'headers', '--client', name]);
  if (!read) return;
  await ctx.show({ title: `Итоговые заголовки: ${name}`, lines: model.headerLines(read.data, true) });
}

/** Срок публикации (`clients.rs::ttl`): `undefined` — отмена, `null` — без `--ttl`. */
async function askTtl(ctx, current) {
  const choice = await ctx.choose({ title: model.TTL_TITLE, options: model.ttlOptions(current).map((o) => ({ ...o, tone: 'view' })) });
  if (choice === null || choice === undefined) return undefined;
  if (choice === 'keep') return null;
  if (choice !== 'custom') return choice;
  const custom = await required(ctx, model.TTL_TITLE, model.TTL_PROMPT, 'Срок не указан.');
  return custom === null ? undefined : custom;
}

const SUBSCRIPTION_ACTIONS = [
  { value: 'publish', label: 'Опубликовать', tone: 'create' },
  { value: 'share', label: 'Показать ссылку', tone: 'view' },
  { value: 'resolved', label: 'Итоговые заголовки', tone: 'view' },
  { value: 'headers', label: 'Заголовки клиента', tone: 'change' },
  { value: 'rotate', label: 'Сменить токен', tone: 'danger' },
  { value: 'revoke', label: 'Отозвать подписку', tone: 'danger' },
];

/** Подменю «Подписка клиента» (`clients.rs::client_subscription`). */
export async function clientSubscription(ctx, name) {
  for (;;) {
    const read = await loadData(ctx, 'Подписка клиента', ['client', 'list']);
    if (!read) return;
    const row = model.findRow(read.data, name);
    if (!row) { ctx.notify('warn', `Клиент «${name}» не найден.`); return; }
    // Нечитаемый хост только скрывает строку (v1 `sub host || true`).
    const host = await ctx.request(['subscription', 'host']);
    const choice = await ctx.choose({
      title: `Подписка клиента: ${name}`,
      context: [model.hostLine(host).text, `Подписка: ${model.subscriptionState(row)}`],
      options: SUBSCRIPTION_ACTIONS,
      cancel: 'Назад',
    });
    if (choice === null || choice === undefined) return;
    if (choice === 'publish') {
      const ttl = await askTtl(ctx, model.currentExpiry(row));
      if (ttl === undefined) continue;
      const reply = await ctx.request(model.publishArgv(name, ttl));
      if (model.published(reply)) await showShare(ctx, name);
      else ctx.failed();
    } else if (choice === 'share') {
      await showShare(ctx, name);
    } else if (choice === 'resolved') {
      await resolvedHeaders(ctx, name);
    } else if (choice === 'headers') {
      await showHeaders(ctx, 'client', name);
    } else if (choice === 'rotate') {
      const reply = await confirmed(ctx, 'Смена токена подписки', 'Сменить токен?', ['subscription', 'rotate', '--name', name]);
      if (model.published(reply)) await showShare(ctx, name);
    } else if (choice === 'revoke') {
      await confirmed(ctx, 'Отзыв подписки', 'Отозвать подписку?', ['subscription', 'revoke', '--name', name]);
    }
  }
}
