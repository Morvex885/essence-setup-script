// Настройки `#/settings` — `tui/src/system.rs::Settings` / `settings_view`:
// `self version` один раз за визит, `status` и `daemon status` при входе и
// после каждого действия; веб-блок «Демон». После успешного `self update` /
// `self uninstall` — `ctx.restart`.
import { html } from '../../vendor/preact-htm.js';
import { Card } from '../ui.js';
import { useCommand, useCommands, useBusy, Action, Actions, Context, Back, Loaded, ReadFailed } from './kit.js';
import { settingsView, settingsAction, daemonLines } from './system-model.js';

export function SettingsScreen({ ctx }) {
  const version = useCommand(ctx, ['self', 'version']);
  const state = useCommands(ctx, { status: ['status'], daemon: ['daemon', 'status'] });
  const [busy, run] = useBusy();
  const back = html`<${Back} ctx=${ctx} to="summary" />`;
  if (!version.reply || !state.replies) {
    return html`<${Card} title="Настройки" actions=${back}><p class="dim">Загрузка…</p><//>`;
  }
  // Пароль запуска известен только из успешного `status`: при ошибке — «Не
  // удалось получить данные» с повтором, без действий с паролем.
  const status = { reply: state.replies.status, data: state.data.status, loading: state.loading, reload: state.reload };
  return html`<${Loaded} title="Настройки" state=${status} actions=${back}>${(data) => {
    const password = data.script_password === true;
    const view = settingsView(version.reply, password);
    const act = (key) => run(async () => {
      const restart = await settingsAction(ctx, key, { password, available: view.available });
      if (restart) { ctx.restart(restart); return; }
      await state.reload();
    });
    // Отказ `self version` или `daemon status` — та же ошибка с повтором в своём блоке.
    return html`
      <${Card} title="Настройки" actions=${back}>
        ${!version.reply.ok && html`<${ReadFailed} reply=${version.reply} loading=${version.loading} reload=${version.reload} />`}
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
          : html`<${ReadFailed} reply=${state.replies.daemon} loading=${state.loading} reload=${state.reload} />`}
      <//>
    `;
  }}<//>`;
}
