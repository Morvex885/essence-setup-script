// Полноэкранный оверлей терминала (`node shell`, `telegram menu`): xterm.js и
// FitAddon из вендоренных классических скриптов (глобальные `Terminal`,
// `FitAddon`). `onData` → `write`, изменение размера → `resize`, «Закрыть» →
// `close`; после завершения показывается итог, оверлей закрывается кнопкой.
// Фокус: при открытии и после итога — «Закрыть», после `open` — терминал,
// при закрытии — элемент, с которого терминал открыт.
import { html, useEffect, useRef, useState } from '../vendor/preact-htm.js';
import { Badge, useModalFocus } from './ui.js';
import { Icon } from './icons.js';

const closeButton = (root) => root.querySelector('.terminal-bar .terminal-close');

/**
 * `start(argv, options)` — `connection.terminal`; `onClosed(reply)` вызывается
 * кнопкой закрытия после завершения команды.
 */
export function TerminalOverlay({ title, argv, start, onClosed }) {
  const overlay = useRef(null);
  const host = useRef(null);
  const session = useRef(null);
  const [reply, setReply] = useState(null);
  const [opened, setOpened] = useState(false);
  // Окно диалога поверх терминала держит фокус само.
  useModalFocus(overlay, closeButton, () => !document.querySelector('.modal.modal-open'));
  // Итог (и ошибка до `open`) заменяет кнопку «Закрыть»: фокус — на новую.
  useEffect(() => {
    if (reply !== null) closeButton(overlay.current).focus();
  }, [reply]);

  useEffect(() => {
    const term = new window.Terminal({ cursorBlink: true, convertEol: false, fontFamily: 'ui-monospace, Menlo, Consolas, monospace', fontSize: 14 });
    const fit = new window.FitAddon.FitAddon();
    term.loadAddon(fit);
    term.open(host.current);
    fit.fit();
    const handle = start(argv, {
      term: 'xterm-256color',
      cols: term.cols,
      rows: term.rows,
      onOpen: () => { setOpened(true); term.focus(); },
      onOutput: (bytes) => term.write(bytes),
      onLog: (entry) => term.write(`\r\n${String(entry.text).replace(/\n/g, '\r\n')}\r\n`),
    });
    session.current = handle;
    const typed = term.onData((data) => handle.write(data));
    const sized = term.onResize(({ cols, rows }) => handle.resize(cols, rows));
    const refit = () => { try { fit.fit(); } catch { /* оверлей уже закрыт */ } };
    window.addEventListener('resize', refit);
    handle.done.then((result) => setReply(result));
    return () => {
      window.removeEventListener('resize', refit);
      typed.dispose();
      sized.dispose();
      handle.close();
      term.dispose();
    };
  }, []);

  const finished = reply !== null;
  const outcome = !finished ? null : reply.ok ? 'Сеанс завершён.' : (reply.error && reply.error.message) || 'Сеанс завершился ошибкой.';
  const state = finished
    ? (reply.ok ? { tone: 'neutral', label: 'завершён' } : { tone: 'error', label: 'ошибка' })
    : opened ? { tone: 'ok', label: 'подключено' } : { tone: 'info', label: 'подключение…' };
  return html`
    <div class="terminal-overlay" role="dialog" aria-modal="true" aria-label=${title} ref=${overlay} tabindex="-1">
      <div class="terminal-bar">
        <${Icon} name="terminal" size=${18} />
        <span class="terminal-title">${title}</span>
        <${Badge} tone=${state.tone}>${state.label}<//>
        ${finished && html`<span class="terminal-outcome ${reply.ok ? 't-dim' : 't-error'}">${outcome}</span>`}
        <span class="terminal-spacer"></span>
        <span class="terminal-close-wrap">
          ${finished
            ? html`<button type="button" class="btn btn-sm btn-primary terminal-close" onClick=${() => onClosed(reply)}>
                <${Icon} name="x" size=${16} />Закрыть</button>`
            : html`<button type="button" class="btn btn-sm btn-soft btn-error terminal-close"
                onClick=${() => session.current && session.current.close()}><${Icon} name="x" size=${16} />Закрыть</button>`}
        </span>
      </div>
      <div class="terminal-host" ref=${host}></div>
    </div>
  `;
}
