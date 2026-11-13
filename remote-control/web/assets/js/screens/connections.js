// Вкладка «Подключения» карточки ноды (`#/nodes/<нода>/connections`) —
// перенос `nodes.rs::connection_node`, `assign_connections`, `aliases`.
// `conn sync --name` идёт по SSH и чистит устаревшее; после действий
// перечитывается только `conn list --name`.
import { html, useEffect, useRef, useState } from '../../vendor/preact-htm.js';
import { Card, DataTable, Chips } from '../ui.js';
import { Icon } from '../icons.js';
import { NODE_CODES } from '../flows.js';
import { useBusy, useMounted, Action, Actions, ReadFailed, rows } from './kit.js';
import { syncedNode, connectionView, assignConnections, connSyncArgv, connListArgv, nodeCheckArgv } from './nodeops-model.js';
import { aliasArgv, aliasValues, plain } from './nodes-model.js';

/** Псевдонимы подключений ноды одной формой (`nodes.rs::aliases`). */
async function editAliases(ctx, name) {
  const reply = await ctx.nodeRequest(name, ['node', 'aliases', '--name', name]);
  if (!reply.ok) return;
  const entries = rows(reply.data);
  if (entries.length === 0) {
    ctx.notify('info', 'Подключения на ноде не найдены.');
    return;
  }
  const form = await ctx.form({
    title: `Псевдонимы подключений: ${name}`,
    fields: entries.map((entry, index) => ({
      name: `a${index}`,
      label: plain(entry.proxy),
      type: 'text',
      value: plain(entry.alias),
      hint: 'пусто — без псевдонима',
    })),
  });
  if (form === null) return;
  const argv = aliasArgv(name, entries, aliasValues(entries, form));
  if (!argv) {
    ctx.notify('info', 'Изменений нет.');
    return;
  }
  const saved = await ctx.request(argv);
  if (ctx.isFailure(saved)) ctx.failed();
}

export function NodeConnections({ ctx, name }) {
  const [state, setState] = useState({ view: null, failed: null });
  const [busy, run] = useBusy();
  const synced = useRef(null);
  const mounted = useMounted();
  /** Исчезнувшая нода возвращает к списку — только пока вкладка открыта. */
  const gone = () => { if (mounted.current) ctx.navigate('nodes'); };
  const fail = (reply) => { if (mounted.current) setState((current) => ({ ...current, failed: reply })); };
  /** Сбой чтения: `not_found` — к списку нод, иначе итог сбоя и «Повторить чтение». */
  const failure = (reply) => {
    if (reply.error && reply.error.code === 'not_found') { gone(); return; }
    if (ctx.isFailure(reply)) ctx.failed();
    fail(reply);
  };

  /** `conn sync --name`; при `partial` с кодом ноды — один раз `node check`. */
  const refresh = async () => {
    let resolve = true;
    for (;;) {
      const reply = await ctx.request(connSyncArgv(name), { expect: 'not_found' });
      if (reply.ok) {
        synced.current = syncedNode(reply.data, name);
        return true;
      }
      if (reply.error && reply.error.code === 'partial') {
        synced.current = syncedNode(reply.error, name);
        const code = synced.current && typeof synced.current.error === 'string' ? synced.current.error : '';
        if (resolve && NODE_CODES.includes(code)) {
          // Строка синхронизации называет только код; `node check` вернёт
          // состояние с подробностями (отпечатками) для обработчика.
          resolve = false;
          if ((await ctx.nodeRequest(name, nodeCheckArgv(name), null)).ok) continue;
        } else {
          ctx.failed();
        }
        return true;
      }
      failure(reply);
      return false;
    }
  };

  const list = async () => {
    const listed = await ctx.request(connListArgv(name), { expect: 'not_found' });
    if (!listed.ok) {
      failure(listed);
      return;
    }
    if (mounted.current) setState({ view: connectionView(listed.data, synced.current, name), failed: null });
  };

  const synchronize = async () => {
    if (await refresh()) await list();
  };

  useEffect(() => { run(synchronize); }, [name]);

  const act = (action) => run(async () => {
    await action();
    await list();
  });

  const { view, failed } = state;
  if (!view) {
    return html`<${Card} title="Подключения">
      ${failed
        ? html`<${ReadFailed} reply=${failed} loading=${busy} reload=${() => run(synchronize)} />`
        : html`<p class="t-dim">Загрузка…</p>`}
    <//>`;
  }
  const columns = [
    { key: 'proxy', label: 'Подключение', search: true },
    {
      key: 'groups',
      label: 'Группы',
      render: (row) => html`<${Chips} items=${row.groups.map((group) => ({ label: group, href: ctx.href('groups', group) }))} />`,
    },
  ];
  const actions = html`<${Actions}>
    <${Action} primary icon="git-branch" disabled=${busy}
      onClick=${() => act(() => assignConnections(ctx, name, view.proxies, view.assigned))}>Назначить группам<//>
    <${Action} icon="pencil" disabled=${busy} onClick=${() => act(() => editAliases(ctx, name))}>Псевдонимы<//>
    <${Action} icon="refresh-cw" disabled=${busy} onClick=${() => run(synchronize)}>Синхронизировать<//>
  <//>`;
  return html`<${Card} title="Подключения" actions=${actions}>
    ${view.problem && html`<div role="alert" class="alert alert-warning alert-soft">
      <${Icon} name="triangle-alert" size=${18} /><span>Нода ${view.problem}</span>
    </div>`}
    <${DataTable} columns=${columns} rows=${view.table} rowKey="proxy" empty="Подключения не найдены" />
  <//>`;
}
