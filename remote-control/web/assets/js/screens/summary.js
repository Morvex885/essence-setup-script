// Сводка `#/` — `tui/src/system.rs::dashboard_view` (+ `Dashboard::run`):
// `status` при входе; вместо буквенных клавиш — кнопки разделов в порядке и
// цветах TUI.
import { html } from '../../vendor/preact-htm.js';
import { Card } from '../ui.js';
import { useCommand, Action, Actions, Context, Loaded } from './kit.js';
import { dashboardView } from './system-model.js';

/** Строки модели (`{ text, tone, suffix }`) → строки `Context`. */
export function contextLines(lines) {
  return lines.map((line) => (line.suffix
    ? { text: html`${line.text}<span class="tone-${line.suffix.tone}">${line.suffix.text}</span>`, tone: line.tone }
    : line));
}

export function SummaryScreen({ ctx }) {
  const state = useCommand(ctx, ['status']);
  const version = ctx.hello && typeof ctx.hello.version === 'string' ? ctx.hello.version : '';
  return html`<${Loaded} title="Сводка" state=${state}>${(data) => {
    const view = dashboardView(data, version);
    return html`<${Card} title=${view.title}>
      ${view.update && html`<p class="tone-${view.update.tone}">${view.update.text}</p>`}
      <${Context} lines=${contextLines(view.context)} />
      ${view.sections.map((section, index) => html`
        <${Actions} key=${index}>
          ${section.map((item) => html`
            <${Action} key=${item.route} tone=${item.tone} onClick=${() => ctx.navigate(item.route)}>${item.label}<//>
          `)}
        <//>
      `)}
    <//>`;
  }}<//>`;
}
