// Настройки `#/settings` — `tui/src/system.rs::Settings` / `settings_view`:
// `self version` один раз за визит, `status` и `daemon status` при входе и
// после каждого действия; веб-блоки «Оформление» и «Демон». После успешного
// `self update` / `self uninstall` — `ctx.restart`.
import { html } from '../../vendor/preact-htm.js';
import { Page, Card, Facts, Badge, Button, Segmented } from '../ui.js';
import { versionLabel } from '../format.js';
import { useCommand, useCommands, useBusy, Loaded, ReadFailed } from './kit.js';
import { updateAvailable, settingsAction, daemonLines } from './system-model.js';

const THEMES = [
  { value: 'system', label: 'Системная', icon: 'monitor' },
  { value: 'light', label: 'Светлая', icon: 'sun' },
  { value: 'dark', label: 'Тёмная', icon: 'moon' },
];

export function SettingsScreen({ ctx }) {
  const version = useCommand(ctx, ['self', 'version']);
  const state = useCommands(ctx, { status: ['status'], daemon: ['daemon', 'status'] });
  const [busy, run] = useBusy();
  // Пароль запуска известен только из успешного `status`: при ошибке — «Не
  // удалось получить данные» с повтором, без действий с паролем.
  const status = { reply: state.replies && state.replies.status, data: state.data && state.data.status, loading: state.loading, reload: state.reload };
  return html`<${Loaded} title="Настройки" state=${status}>${(data) => {
    const password = data.script_password === true;
    const available = updateAvailable(version.reply);
    const act = (key) => run(async () => {
      const restart = await settingsAction(ctx, key, { password, available });
      if (restart) { ctx.restart(restart); return; }
      await state.reload();
    });
    const disabled = busy || state.loading;
    const info = version.reply && version.reply.ok ? (version.reply.data || {}) : null;
    return html`<${Page} title="Настройки">
      <${Card} title="Версия" actions=${available && html`<${Button} kind="primary" icon="download" disabled=${disabled}
        onClick=${() => act('u')}>Обновить remote-control<//>`}>
        ${!version.reply
          ? html`<p class="t-dim">Загрузка…</p>`
          : !info
            ? html`<${ReadFailed} reply=${version.reply} loading=${version.loading} reload=${version.reload} />`
            : html`<${Facts} items=${[
                { label: 'Установлена', value: versionLabel(typeof info.current === 'string' ? info.current : '') },
                { label: 'Последняя', value: info.checked === true ? versionLabel(typeof info.latest === 'string' ? info.latest : '') : html`<span class="t-dim">не удалось проверить</span>` },
                { label: 'Обновление', value: available ? html`<${Badge} tone="info">доступно<//>` : html`<${Badge} tone="neutral">нет<//>` },
              ]} />`}
      <//>
      <${Card} title="Пароль запуска" actions=${html`
        <${Button} kind=${password ? 'neutral' : 'primary'} icon="key-round" disabled=${disabled} onClick=${() => act('l')}>${password ? 'Сменить' : 'Установить'}<//>
        ${password && html`<${Button} kind="danger" disabled=${disabled} onClick=${() => act('r')}>Убрать<//>`}`}>
        <div class="row">
          ${password ? html`<${Badge} tone="ok">установлен<//>` : html`<${Badge} tone="warn">не установлен<//>`}
          <span class="t-dim">Пароль спрашивается при открытии меню и панели.</span>
        </div>
      <//>
      <${Card} title="Оформление">
        <${Segmented} label="Тема" options=${THEMES} value=${ctx.theme.choice} onChange=${(choice) => ctx.theme.set(choice)} />
      <//>
      <${Card} title="Демон">
        ${state.data.daemon
          ? html`<${Facts} items=${daemonLines(state.data.daemon).map((line) => ({ label: line.label, value: line.value }))} />`
          : html`<${ReadFailed} reply=${state.replies.daemon} loading=${state.loading} reload=${state.reload} />`}
      <//>
      <${Card} title="Опасная зона" className="danger-zone">
        <div class="danger-row">
          <div class="op-text">
            <div class="op-title">Удалить remote-control</div>
            <div class="op-desc">Удалить программу и автозапуск; локальные данные — по выбору.</div>
          </div>
          <${Button} kind="danger" icon="trash-2" disabled=${disabled} onClick=${() => act('x')}>Удалить<//>
        </div>
      <//>
    <//>`;
  }}<//>`;
}
