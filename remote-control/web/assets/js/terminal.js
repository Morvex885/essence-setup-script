// Полноэкранный оверлей терминала (`node shell`, `telegram menu`): xterm.js и
// FitAddon из вендоренных классических скриптов (глобальные `Terminal`,
// `FitAddon`). `onData` → `write`, изменение размера → `resize`, «Закрыть» →
// `close`; после завершения показывается итог, оверлей закрывается кнопкой.
import { html, useEffect, useRef, useState } from '../vendor/preact-htm.js';
import { Button } from './ui.js';

/**
 * `start(argv, options)` — `connection.terminal`; `onClosed(reply)` вызывается
 * кнопкой закрытия после завершения команды.
 */
export function TerminalOverlay({ title, argv, start, onClosed }) {
  const host = useRef(null);
  const session = useRef(null);
  const [reply, setReply] = useState(null);
  const [opened, setOpened] = useState(false);

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
  return html`
    <div class="terminal-overlay" role="dialog" aria-modal="true">
      <div class="terminal-bar">
        <span class="terminal-title">${title}</span>
        ${!finished && !opened && html`<span class="dim">Подключение…</span>`}
        ${finished && html`<span class=${reply.ok ? 'tone-ok' : 'tone-error'}>${outcome}</span>`}
        <span class="terminal-spacer"></span>
        ${finished
          ? html`<${Button} kind="view" onClick=${() => onClosed(reply)}>Закрыть<//>`
          : html`<${Button} kind="danger" onClick=${() => session.current && session.current.close()}>Закрыть<//>`}
      </div>
      <div class="terminal-host" ref=${host}></div>
    </div>
  `;
}
