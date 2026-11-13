// Настройки `#/settings` — `tui/src/system.rs::Settings` / `settings_view`:
// `self version` один раз за визит, `status` и `daemon status` при входе и
// после каждого действия; веб-блоки «Оформление» и «Демон». После успешного
// `self update` / `self uninstall` — `ctx.restart`.
import { html } from '../../vendor/preact-htm.js';
import { Page, Card, Facts, Badge, Button, Segmented } from '../ui.js';
import { versionLabel } from '../format.js';
import { THEME_OPTIONS } from '../theme.js';
import { useCommand, useCommands, useBusy, ReadFailed } from './kit.js';
import { updateAvailable, updateState, settingsAction, daemonLines } from './system-model.js';

const UPDATE_BADGES = {
  available: () => html`<${Badge} tone="info">доступно<//>`,
  none: () => html`<${Badge} tone="neutral">нет<//>`,
  unchecked: () => html`<span class="t-dim">не проверено</span>`,
};

/** Чтение одной карточки: «Загрузка…», «Не удалось получить данные» или `children(data)`. */
function Part({ reply, data, loading, reload, children }) {
  if (!reply) return html`<p class="t-dim">Загрузка…</p>`;
  if (!reply.ok || data === null || data === undefined) return html`<${ReadFailed} reply=${reply} loading=${loading} reload=${reload} />`;
  return children(data);
}

export function SettingsScreen({ ctx }) {
  const version = useCommand(ctx, ['self', 'version']);
  const state = useCommands(ctx, { status: ['status'], daemon: ['daemon', 'status'] });
  const [busy, run] = useBusy();
  // Пароль запуска известен только из успешного `status`: при ошибке карточка
  // пароля — «Не удалось получить данные» с повтором и без действий;
  // остальные карточки от `status` не зависят.
  const replies = state.replies || {};
  const data = state.data || {};
  const statusData = data.status && typeof data.status === 'object' ? data.status : null;
  const password = statusData !== null && statusData.script_password === true;
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
              { label: 'Обновление', value: UPDATE_BADGES[updateState(version.reply)]() },
            ]} />`}
    <//>
    <${Card} title="Пароль запуска" actions=${statusData !== null && html`
      <${Button} kind=${password ? 'neutral' : 'primary'} icon="key-round" disabled=${disabled} onClick=${() => act('l')}>${password ? 'Сменить' : 'Установить'}<//>
      ${password && html`<${Button} kind="danger" disabled=${disabled} onClick=${() => act('r')}>Убрать<//>`}`}>
      <${Part} reply=${replies.status} data=${statusData} loading=${state.loading} reload=${state.reload}>${() => html`
        <div class="row">
          ${password ? html`<${Badge} tone="ok">установлен<//>` : html`<${Badge} tone="warn">не установлен<//>`}
          <span class="t-dim">Пароль спрашивается при открытии меню и панели.</span>
        </div>`}<//>
    <//>
    <${Card} title="Оформление">
      <${Segmented} label="Тема" options=${THEME_OPTIONS} value=${ctx.theme.choice} onChange=${(choice) => ctx.theme.set(choice)} />
    <//>
    <${Card} title="Демон">
      <${Part} reply=${replies.daemon} data=${data.daemon} loading=${state.loading} reload=${state.reload}>${(daemon) => html`
        <${Facts} items=${daemonLines(daemon).map((line) => ({ label: line.label, value: line.value }))} />`}<//>
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
}
