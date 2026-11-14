// Вкладка «AmneziaWG» карточки ноды (`#/nodes/<нода>/awg`) — перенос
// `nodes.rs::awg_node`. Команды над нодой — `ctx.nodeRequest`.
import { html, useEffect, useState } from '../../vendor/preact-htm.js';
import { Card, DataTable, Badge, Empty, Button } from '../ui.js';
import { useBusy, useMounted, ReadFailed } from './kit.js';
import {
  awgStatusArgv, awgSyncArgv, awgRemovePeerArgv, awgOrphansArgv, awgView, AWG_REMOVE_TITLE, AWG_ORPHANS_TITLE,
} from './nodeops-model.js';

export function NodeAwg({ ctx, name }) {
  const [reply, setReply] = useState(null);
  const [busy, run] = useBusy();
  const mounted = useMounted();

  /**
   * `awg status`; исчезнувшая нода (`not_found`) — к списку нод, пока вкладка
   * открыта; прочий отказ (уже показан `nodeRequest`) — «Повторить чтение».
   */
  const load = async () => {
    const answer = await ctx.nodeRequest(name, awgStatusArgv(name), null, { expect: 'not_found' });
    if (!mounted.current) return;
    if (answer.error && answer.error.code === 'not_found') ctx.navigate('nodes');
    else setReply(answer);
  };

  useEffect(() => { run(load); }, [name]);

  const then = (action) => run(async () => {
    await action();
    await load();
  });
  const sync = () => then(() => ctx.nodeRequest(name, awgSyncArgv(name), null));
  const remove = (peer) => then(() => ctx.nodeRequest(name, awgRemovePeerArgv(name, peer), { title: AWG_REMOVE_TITLE, question: 'Удалить?' }));
  const orphans = () => then(() => ctx.nodeRequest(name, awgOrphansArgv(name), { title: AWG_ORPHANS_TITLE, question: 'Удалить?' }));

  if (!reply || !reply.ok) {
    return html`<${Card} title="AmneziaWG">
      ${reply
        ? html`<${ReadFailed} reply=${reply} loading=${busy} reload=${() => run(load)} />`
        : html`<p class="t-dim">Загрузка…</p>`}
    <//>`;
  }
  const view = awgView(reply.data);
  const actions = html`<div class="row">
    ${view.installed && html`<${Button} kind=${view.missing ? 'primary' : 'neutral'} icon="plus" disabled=${busy} onClick=${sync}>Создать недостающих<//>`}
    ${view.orphans && html`<${Button} kind="danger" icon="trash-2" disabled=${busy} onClick=${orphans}>Удалить неиспользуемых<//>`}
    <${Button} icon="refresh-cw" disabled=${busy} onClick=${() => run(load)}>Обновить<//>
  </div>`;
  if (!view.installed) {
    return html`<${Card} title="AmneziaWG" actions=${actions}>
      <${Empty} icon="shield" title="AmneziaWG на ноде не установлен" />
    <//>`;
  }
  const columns = [
    { key: 'name', label: 'Клиент', search: true },
    { key: 'label', label: 'Состояние', render: (row) => html`<${Badge} tone=${row.tone}>${row.label}<//>` },
  ];
  // У клиента, ещё не созданного на ноде, удалять нечего: пункт недоступен.
  const menu = (row) => [{ label: 'Удалить', icon: 'trash-2', danger: true, disabled: busy || !row.removable, onClick: () => remove(row.name) }];
  return html`<${Card} title="AmneziaWG" actions=${actions}>
    <${DataTable} columns=${columns} rows=${view.table} empty="Нет клиентов" menu=${menu} />
  <//>`;
}
