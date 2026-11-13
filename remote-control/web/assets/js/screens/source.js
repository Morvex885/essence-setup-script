// Источник конфигурации `#/source` — `tui/src/source.rs` (`Source`,
// `source_view`, `recovery_run`) и мастер GitHub (`github_wizard`). Логика
// действий и мастера — `system-model.js` (клавиши действий `sourceAction`);
// здесь — разметка, выбор файла ключа и окно ссылки для ручных действий.
import { html, useState } from '../../vendor/preact-htm.js';
import { Page, Card, Facts, Badge, Button, MoreMenu, Empty, FileText } from '../ui.js';
import { Linkified } from '../dialogs.js';
import { syncState } from '../format.js';
import { useCommand, useBusy, Loaded } from './kit.js';
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

/** Окно импорта ключа восстановления: файл читается в браузере (ключ `k`). */
function KeyImport({ ctx, onDone }) {
  const [state, setState] = useState(null); // null | 'busy' | 'ok' | 'failed'
  const pick = async (text, reason) => {
    setState('busy');
    const reply = await importRecoveryKey(ctx, text, reason);
    setState(reply && reply.ok ? 'ok' : 'failed');
    onDone();
  };
  return html`<div class="stack">
    <p>Выберите файл ключа восстановления age. Содержимое уходит демону полем запроса; путь к файлу не передаётся.</p>
    <div class="row"><${FileText} kind="primary" label="Выбрать файл ключа" accept="" disabled=${state === 'busy'} onText=${pick} /></div>
    ${state === 'ok' && html`<p class="t-ok">Ключ импортирован.</p>`}
    ${state === 'failed' && html`<p class="t-warn">Ключ не импортирован.</p>`}
  </div>`;
}

const LABELS = {
  c: 'Сменить аккаунт', r: 'Сменить пароль доступа', k: 'Импортировать ключ восстановления',
  e: 'Работать локально без синхронизации',
};

const DANGER = [
  { key: 'v', title: 'Новый ключ шифрования', button: 'Создать ключ', desc: 'Перешифровать конфигурацию новым ключом и паролем.' },
  { key: 'l', title: 'Заменить GitHub локальной конфигурацией', button: 'Заменить', desc: 'Конфигурация в репозитории будет заменена данными с этого устройства.' },
  { key: 'd', title: 'Удалить репозиторий', button: 'Удалить', desc: 'Удалить репозиторий конфигурации в GitHub.' },
];

export function SourceScreen({ ctx }) {
  const state = useCommand(ctx, ['source', 'status']);
  const [busy, run] = useBusy();
  const act = (key) => run(async () => {
    await sourceAction(ctx, key, state.data, { link: (label, url) => showLink(ctx, label, url) });
    await state.reload();
  });
  const importKey = () => ctx.show({ title: LABELS.k, body: html`<${KeyImport} ctx=${ctx} onDone=${() => state.reload()} />` });
  return html`<${Loaded} title="Источник конфигурации" state=${state}>${(data) => {
    const view = sourceView(data);
    const { keys } = view;
    const disabled = busy || state.loading;
    if (!view.github) {
      return html`<${Page} title="Источник конфигурации">
        <${Card}>
          <${Empty} icon="git-branch" title="Конфигурация хранится локально"
            hint="Подключите GitHub, чтобы хранить конфигурацию в приватном репозитории и работать с нескольких устройств."
            action=${html`<${Button} kind="primary" icon="git-branch" disabled=${disabled} onClick=${() => act('g')}>Подключить GitHub<//>`} />
        <//>
      <//>`;
    }
    const sync = syncState(data.sync);
    const more = ['c', 'r', 'k', 'e'].filter((key) => keys.includes(key)).map((key) => ({
      label: LABELS[key], disabled, onClick: () => (key === 'k' ? importKey() : act(key)),
    }));
    const actions = html`
      <${Button} icon="download" disabled=${disabled} onClick=${() => act('f')}>Загрузить из GitHub<//>
      <${Button} kind="primary" icon="upload" disabled=${disabled} onClick=${() => act('p')}>Отправить в GitHub<//>
      <${MoreMenu} items=${more} />`;
    return html`<${Page} title="Источник конфигурации" actions=${actions}>
      <${Card}>
        <${Facts} items=${[
          { label: 'Репозиторий', value: data.repo || '—' },
          { label: 'Ветка', value: data.branch || '—' },
          { label: 'Хранение', value: view.encrypted ? 'зашифровано' : 'без шифрования' },
          { label: 'Синхронизация', value: html`<${Badge} tone=${sync.tone}>${sync.label}<//>` },
        ]} />
      <//>
      <${Card} title="Опасная зона" className="danger-zone">
        <div class="op-list">
          ${DANGER.filter((item) => keys.includes(item.key)).map((item) => html`<div key=${item.key} class="op-row">
            <div class="op-text"><div class="op-title">${item.title}</div><div class="op-desc">${item.desc}</div></div>
            <${Button} kind="danger" disabled=${disabled} onClick=${() => act(item.key)}>${item.button}<//>
          </div>`)}
        </div>
      <//>
    <//>`;
  }}<//>`;
}
