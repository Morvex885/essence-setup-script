// Окна с QR-кодом: ссылка подписки (`clients.rs::share`, `share_view`): URL,
// срок, заголовки, curl, JSON и QR-код; конфиг AmneziaWG клиента на ноде.
// Разметка окон — здесь; данные — `shareModel`, `awgConfigFlow`.
import { html, useEffect, useRef, useState } from '../../vendor/preact-htm.js';
import { Button, CopyButton, downloadText } from '../ui.js';
import { awgConfigFile, awgConfigFlow, fetchData, shareModel } from './clients-model.js';

/** QR-код текста на `<canvas>`; без `window.qrcode` или при сбое — не рисуется. */
function QrCode({ text, label = 'QR-код ссылки подписки' }) {
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
      // Свободное поле в четыре модуля — внутри холста, при любом масштабе.
      const quiet = 4 * scale;
      target.width = count * scale + 2 * quiet;
      target.height = target.width;
      const draw = target.getContext('2d');
      draw.fillStyle = '#fff';
      draw.fillRect(0, 0, target.width, target.height);
      draw.fillStyle = '#000';
      for (let row = 0; row < count; row += 1) {
        for (let col = 0; col < count; col += 1) {
          if (qr.isDark(row, col)) draw.fillRect(quiet + col * scale, quiet + row * scale, scale, scale);
        }
      }
      setDrawn(true);
    } catch {
      setDrawn(false);
    }
  }, [text]);
  return html`<canvas ref=${canvas} class="qr" hidden=${!drawn} aria-label=${label}></canvas>`;
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
  const share = shareModel(read.data || {});
  await ctx.show({ title: share.title, wide: true, body: html`<${ShareView} share=${share} />` });
}

/** Окно конфига AmneziaWG: текст, копирование, скачивание `<клиент>-<нода>.conf` и QR. */
function AwgConfigView({ name, node, config }) {
  return html`<div class="share">
    <pre class="plan mono">${config}</pre>
    <div class="row">
      <${Button} kind="primary" icon="download" onClick=${() => downloadText(awgConfigFile(name, node), config)}>Скачать .conf<//>
      <${CopyButton} text=${config} label="Копировать" />
    </div>
    <${QrCode} text=${config} label="QR-код конфига AmneziaWG" />
  </div>`;
}

/** «Конфиг AmneziaWG»: выбор ноды, `client awg-config` и окно конфига. */
export async function showAwgConfig(ctx, name) {
  const result = await awgConfigFlow(ctx, name);
  if (result === null) return;
  await ctx.show({
    title: `AmneziaWG: ${name} — ${result.node}`, wide: true,
    body: html`<${AwgConfigView} name=${name} node=${result.node} config=${result.config} />`,
  });
}
