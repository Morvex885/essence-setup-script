// Источник конфигурации `#/source` — `tui/src/source.rs` (`Source`,
// `source_view`, `recovery_run`) и мастер GitHub (`github_wizard`). Логика
// действий и мастера — `system-model.js`; здесь — разметка, выбор файла ключа
// и окно ссылки для ручных действий.
import { html } from '../../vendor/preact-htm.js';
import { Card, FileText } from '../ui.js';
import { Linkified } from '../dialogs.js';
import { useCommand, useBusy, Action, Actions, Context, Back, Loaded } from './kit.js';
import { contextLines } from './summary.js';
import { sourceView, sourceAction, importRecoveryKey, githubWizardFlow } from './system-model.js';

/** Ссылка для ручного действия (`source.rs::manual_link`) — окно со ссылкой. */
function showLink(ctx, label, url) {
  return ctx.show({ title: label, body: html`<p class="mono"><${Linkified} text=${url} /></p>` });
}

/**
 * Мастер GitHub: `mode` — `connect` (первый запуск, локальный источник) или
 * `change` (смена аккаунта). `true` — команда выполнена.
 */
export function githubWizard(ctx, mode) {
  return githubWizardFlow(ctx, mode, { link: (label, url) => showLink(ctx, label, url) });
}

export function SourceScreen({ ctx }) {
  const state = useCommand(ctx, ['source', 'status']);
  const [busy, run] = useBusy();
  const back = html`<${Back} ctx=${ctx} to="summary" />`;
  const act = (key) => run(async () => {
    await sourceAction(ctx, key, state.data, { link: (label, url) => showLink(ctx, label, url) });
    await state.reload();
  });
  const importKey = (text) => run(async () => {
    await importRecoveryKey(ctx, text);
    await state.reload();
  });
  return html`<${Loaded} title="Источник конфигурации" state=${state} actions=${back}>${(data) => {
    const view = sourceView(data);
    return html`<${Card} title="Источник конфигурации" actions=${back}>
      <${Context} lines=${contextLines(view.context)} />
      ${view.sections.map((section, index) => html`
        <${Actions} key=${index}>
          ${section.map((item) => (item.key === 'k'
            ? html`<${FileText} key="k" tone=${item.tone} label=${item.label} accept="" disabled=${busy} onText=${importKey} />`
            : html`<${Action} key=${item.key} tone=${item.tone} disabled=${busy || state.loading} onClick=${() => act(item.key)}>${item.label}<//>`))}
        <//>
      `)}
    <//>`;
  }}<//>`;
}
