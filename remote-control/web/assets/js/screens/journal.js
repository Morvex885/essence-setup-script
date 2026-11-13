// Журнал `#/journal`: записи сессии панели (сообщения ядра, итоги операций,
// события активности) с фильтром по уровню, копированием и очисткой.
import { html, useState } from '../../vendor/preact-htm.js';
import { Page, Button, CopyButton, Segmented, Empty } from '../ui.js';
import { Linkified } from '../dialogs.js';
import { filterJournal } from '../format.js';

const FILTERS = [
  { value: 'all', label: 'Все' },
  { value: 'error', label: 'Ошибки' },
  { value: 'warn', label: 'Предупреждения' },
];

const LEVEL_CLASS = { error: 'level-error', warn: 'level-warn', success: 'level-success' };

const time = (value) => new Date(value).toLocaleTimeString('ru-RU', { hour12: false });

export function JournalScreen({ ctx }) {
  const [level, setLevel] = useState('all');
  const entries = filterJournal(ctx.journal, level);
  const text = entries.map((entry) => `${time(entry.time)}  ${entry.text}`).join('\n');
  const actions = html`
    ${entries.length > 0 && html`<${CopyButton} text=${text} />`}
    <${Button} icon="trash-2" kind="ghost" disabled=${ctx.journal.length === 0} onClick=${() => ctx.clearJournal()}>Очистить<//>`;
  return html`<${Page} title="Журнал" actions=${actions}>
    <div class="toolbar"><${Segmented} label="Уровень записей" options=${FILTERS} value=${level} onChange=${setLevel} /></div>
    ${entries.length === 0
      ? html`<${Empty} icon="scroll-text" title="Журнал пуст" />`
      : html`<div class="journal" role="log">
          ${entries.map((entry) => html`<div key=${entry.id} class="journal-row ${LEVEL_CLASS[entry.level] || ''}">
            <span class="journal-time">${time(entry.time)}</span>
            <span><${Linkified} text=${entry.text} /></span>
          </div>`)}
        </div>`}
  <//>`;
}
