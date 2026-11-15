// Каскады (`#/cascades`): список `cascade list`, добавление одной формой и
// удаление по плану; после правки — предложение `node apply` на нодах
// каскада. Логика — `cascades-model.js`.
import { html } from '../../vendor/preact-htm.js';
import { Page, Card, DataTable, Empty, Button } from '../ui.js';
import { useCommand, useBusy, Loaded } from './kit.js';
import * as model from './cascades-model.js';

export function CascadesScreen({ ctx }) {
  const state = useCommand(ctx, model.CASCADE_LIST);
  const [busy, run] = useBusy();
  const act = (action) => run(async () => { await action(); await state.reload(); });
  const nodeLink = (name) => html`<a class="link" href=${ctx.href('nodes', name)}>${name}</a>`;
  const actions = html`<${Button} kind="primary" icon="plus" disabled=${busy || !state.data}
    onClick=${() => act(() => model.addCascadeFlow(ctx))}>Добавить каскад<//>`;
  const menu = (row) => [
    { label: 'Удалить', icon: 'trash-2', danger: true, disabled: busy, onClick: () => act(() => model.deleteCascade(ctx, row)) },
  ];
  return html`<${Loaded} title="Каскады" state=${state} actions=${actions}>
    ${(data) => {
      const rows = model.cascadeRows(data);
      return html`<${Page} title="Каскады" actions=${actions}>
        <${Card}>
          ${rows.length === 0
            ? html`<${Empty} icon="route" title="Нет каскадов"
                hint="Клиенты входной ноды выходят в интернет через другую ноду или внешний сервер." action=${actions} />`
            : html`<${DataTable} rows=${rows} empty="Нет каскадов" menu=${menu}
                columns=${[
                  { key: 'name', label: 'Каскад', search: true },
                  { key: 'entry', label: 'Входная нода', search: true, render: (row) => nodeLink(row.entry) },
                  { key: 'listener', label: 'Вход', render: (row) => model.listenerLabel(row.listener) },
                  { key: 'exit', label: 'Выход', render: (row) => (row.exit && typeof row.exit.node === 'string'
                    ? html`${nodeLink(row.exit.node)} · ${String(row.exit.proxy ?? '')}`
                    : model.exitLabel(row.exit)) },
                ]} />`}
        <//>
      <//>`;
    }}
  <//>`;
}
