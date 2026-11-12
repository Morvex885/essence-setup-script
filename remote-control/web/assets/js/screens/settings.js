// Настройки `#/settings` — `tui/src/system.rs::Settings` / `settings_view`:
// `self version` один раз за визит, `status` и `daemon status` при входе и
// после каждого действия; веб-блок «Демон». После успешного `self update` /
// `self uninstall` — `ctx.restart`.
import { html } from '../../vendor/preact-htm.js';
import { Card } from '../ui.js';
import { useCommand, useCommands, useBusy, Action, Actions, Context, Back } from './kit.js';
import { settingsView, settingsAction, daemonLines } from './system-model.js';

export function SettingsScreen({ ctx }) {
  const version = useCommand(ctx, ['self', 'version']);
  const state = useCommands(ctx, { status: ['status'], daemon: ['daemon', 'status'] });
  const [busy, run] = useBusy();
  const back = html`<${Back} ctx=${ctx} to="summary" />`;
  if (!version.reply || !state.replies) {
    return html`<${Card} title="Настройки" actions=${back}><p class="dim">Загрузка…</p><//>`;
  }
  const password = Boolean(state.data.status && state.data.status.script_password === true);
  const view = settingsView(version.reply, password);
  const act = (key) => run(async () => {
    const restart = await settingsAction(ctx, key, { password, available: view.available });
    if (restart) { ctx.restart(restart); return; }
    await state.reload();
  });
  return html`
    <${Card} title="Настройки" actions=${back}>
      <${Context} lines=${view.context} />
      <${Actions}>
        ${view.actions.map((item) => html`
          <${Action} key=${item.key} tone=${item.tone} disabled=${busy || state.loading} onClick=${() => act(item.key)}>${item.label}<//>
        `)}
      <//>
    <//>
    <${Card} title="Демон">
      ${state.data.daemon
        ? html`<${Context} lines=${daemonLines(state.data.daemon).map((line) => `${line.label}: ${line.value}`)} />`
        : html`<p class="tone-warn">Не удалось получить данные</p>`}
    <//>
  `;
}
