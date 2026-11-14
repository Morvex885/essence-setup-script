// Вкладка «Подключения» карточки ноды (`#/nodes/<нода>/connections`) —
// перенос `nodes.rs::connection_node`, `assign_connections`, `aliases`.
// `conn sync --name` идёт по SSH и чистит устаревшее; после действий
// перечитывается только `conn list --name`.
import { html, useEffect, useRef, useState } from '../../vendor/preact-htm.js';
import { Card, DataTable, Chips, Button, Badge } from '../ui.js';
import { Icon } from '../icons.js';
import { useBusy, useMounted, ReadFailed } from './kit.js';
import { connectionView, assignConnections, syncConnections, connListArgv } from './nodeops-model.js';
import { editAliases } from './nodes-model.js';

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

  /** `conn sync --name` (`syncConnections`); `false` — сбой чтения. */
  const refresh = async () => {
    const result = await syncConnections(ctx, name);
    if (result.failed) {
      failure(result.failed);
      return false;
    }
    synced.current = result.synced;
    return true;
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
    { key: 'proxy', label: 'Подключение', search: true,
      render: (row) => (row.stale ? html`${row.proxy} <${Badge} tone="warn">не найдено на ноде<//>` : row.proxy) },
    {
      key: 'groups',
      label: 'Группы',
      render: (row) => html`<${Chips} items=${row.groups.map((group) => ({ label: group, href: ctx.href('groups', group) }))} />`,
    },
  ];
  const actions = html`<div class="row">
    <${Button} kind="primary" icon="git-branch" disabled=${busy}
      onClick=${() => act(() => assignConnections(ctx, name, view.proxies, view.assigned, view.stale))}>Назначить группам<//>
    <${Button} icon="pencil" disabled=${busy} onClick=${() => act(() => editAliases(ctx, name))}>Псевдонимы<//>
    <${Button} icon="refresh-cw" disabled=${busy} onClick=${() => run(synchronize)}>Синхронизировать<//>
  </div>`;
  // Сбой повторного чтения — над прежней таблицей: она могла устареть.
  return html`<${Card} title="Подключения" actions=${actions}>
    ${failed && html`<${ReadFailed} reply=${failed} loading=${busy} reload=${() => run(synchronize)} />`}
    ${view.problem && html`<div role="alert" class="alert alert-warning alert-soft">
      <${Icon} name="triangle-alert" size=${18} /><span>Нода ${view.problem}</span>
    </div>`}
    <${DataTable} columns=${columns} rows=${view.table} rowKey="proxy" empty="Подключения не найдены" />
  <//>`;
}
