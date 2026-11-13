// Группы (`#/groups`, `#/groups/<имя>`) — перенос `clients.rs::groups`,
// `group_card`, `group_template`. Редактор созданного шаблона — экран
// «Шаблоны» (`#/templates/<имя>`).
import { html, useEffect } from '../../vendor/preact-htm.js';
import { Page, Card, DataTable, MoreMenu, Facts, Badge, Chips, Empty } from '../ui.js';
import { useCommand, useBusy, useMounted, Action, Loaded } from './kit.js';
import { execute, confirmed, fetchData, nameOptions, showHeaders } from './shared.js';
import { generateFlow } from './generate.js';
import * as model from './clients-model.js';

const DEFAULT_TEMPLATE = 'default.yaml';

export function GroupsScreen({ ctx, param }) {
  return param === null || param === undefined
    ? html`<${GroupList} ctx=${ctx} />`
    : html`<${GroupCard} ctx=${ctx} name=${param} key=${param} />`;
}

function TemplateLink({ ctx, template }) {
  return typeof template === 'string' ? html`<a class="link" href=${ctx.href('templates', template)}>${template}</a>` : '—';
}

function NodeChips({ ctx, nodes }) {
  return html`<${Chips} items=${model.strings(nodes).map((node) => ({ label: node, href: ctx.href('nodes', node) }))} />`;
}

// ─── Список ─────────────────────────────────────────────────────────────────

function GroupList({ ctx }) {
  const state = useCommand(ctx, ['group', 'list']);
  const [busy, run] = useBusy();
  const act = (action) => run(async () => { await action(); await state.reload(); });

  /** Имя и шаблон одной формой: `group add`, затем `group set-template` для не встроенного. */
  const add = () => act(async () => {
    const read = await fetchData(ctx, ['template', 'list']);
    if (!read) return;
    const values = await ctx.form({
      title: 'Добавить группу',
      submit: 'Добавить',
      fields: [
        { name: 'name', label: 'Название группы', type: 'text', required: 'Название не указано.', autofocus: true },
        { name: 'template', label: 'Шаблон', type: 'select', value: DEFAULT_TEMPLATE, options: nameOptions(read.data) },
      ],
    });
    if (values === null || values === undefined) return;
    const reply = await execute(ctx, ['group', 'add', '--name', values.name]);
    if (reply.ok && values.template !== DEFAULT_TEMPLATE) {
      await execute(ctx, ['group', 'set-template', '--name', values.name, '--template', values.template]);
    }
  });
  const remove = (name) => act(() => confirmed(ctx, 'Удаление группы', 'Удалить группу?', ['group', 'delete', '--name', name]));

  const actions = html`<${Action} primary icon="plus" disabled=${busy || !state.data} onClick=${add}>Добавить группу<//>`;
  const menu = (row) => [
    { label: 'Сгенерировать конфиги', icon: 'file-code', disabled: busy, onClick: () => act(() => generateFlow(ctx, { group: row.name })) },
    { label: 'Удалить', icon: 'trash-2', danger: true, disabled: busy, onClick: () => remove(row.name) },
  ];
  return html`<${Loaded} title="Группы" state=${state} actions=${actions}>
    ${(data) => {
      const list = model.rowsOf(data).filter((row) => row && typeof row.name === 'string');
      return html`<${Page} title="Группы" actions=${actions}>
        <${Card}>
          ${list.length === 0
            ? html`<${Empty} icon="folders" title="Нет групп" action=${actions} />`
            : html`<${DataTable} rows=${list} empty="Нет групп" href=${(row) => ctx.href('groups', row.name)} menu=${menu}
                columns=${[
                  { key: 'name', label: 'Группа', search: true },
                  { key: 'template', label: 'Шаблон', render: (row) => html`<${TemplateLink} ctx=${ctx} template=${row.template} />` },
                  { key: 'clients', label: 'Клиентов', render: (row) => model.scalar(row.clients) },
                  { key: 'nodes', label: 'Ноды', render: (row) => html`<${NodeChips} ctx=${ctx} nodes=${row.nodes} />` },
                ]} />`}
        <//>
      <//>`;
    }}
  <//>`;
}

// ─── Карточка ───────────────────────────────────────────────────────────────

function GroupCard({ ctx, name }) {
  const state = useCommand(ctx, ['group', 'list'], [name], { expect: 'not_found' });
  const clients = useCommand(ctx, ['client', 'list', '--group', name], [name], { expect: 'not_found' });
  const [busy, run] = useBusy();
  const mounted = useMounted();
  const reply = state.reply;
  const row = reply && reply.ok ? model.findRow(reply.data, name) : null;
  // Исчезновение объекта возвращает к списку.
  const vanished = Boolean(reply && (reply.ok ? !row : reply.error && reply.error.code === 'not_found'));
  useEffect(() => {
    if (!vanished) return;
    if (reply.ok) ctx.notify('warn', `Группа «${name}» не найдена.`);
    ctx.navigate('groups');
  }, [vanished, reply]);
  if (vanished) return null;

  const back = { href: ctx.href('groups'), label: 'Группы' };
  const act = (action) => run(async () => {
    if ((await action()) === 'left') return;
    await Promise.all([state.reload(), clients.reload()]);
  });
  const leave = (...route) => { if (mounted.current) ctx.navigate(...route); return 'left'; };
  const template = row ? model.str(row.template) : '—';

  const remove = async () => {
    const result = await confirmed(ctx, 'Удаление группы', 'Удалить группу?', ['group', 'delete', '--name', name]);
    return result.ok ? leave('groups') : undefined;
  };
  /** `clients.rs::group_template`: выбор шаблона или новый шаблон группы (редактор — «Шаблоны»). */
  const chooseTemplate = async () => {
    const read = await fetchData(ctx, ['template', 'list']);
    if (!read) return undefined;
    const values = await ctx.form({
      title: `Шаблон группы: ${name}`,
      fields: [
        { name: 'template', label: 'Шаблон', type: 'select', value: template,
          options: [...nameOptions(read.data), { value: model.NEW_TEMPLATE, label: 'Создать новый…' }] },
        { name: 'name', label: 'Имя нового шаблона', type: 'text', required: 'Имя шаблона не указано.',
          when: (v) => v.template === model.NEW_TEMPLATE },
      ],
    });
    if (values === null || values === undefined) return undefined;
    const plan = model.templateChange(template, values);
    if (plan === null) return undefined;
    if (plan.kind === 'set') {
      await execute(ctx, ['group', 'set-template', '--name', name, '--template', plan.template]);
      return undefined;
    }
    const created = await execute(ctx, ['template', 'create', '--name', plan.name, '--group', name]);
    if (created.ok && created.data && typeof created.data.name === 'string') return leave('templates', created.data.name);
    return undefined;
  };
  const move = async (client) => {
    const others = nameOptions(state.data).filter((option) => option.value !== name);
    if (others.length === 0) { ctx.notify('warn', model.EMPTY); return; }
    const values = await ctx.form({
      title: `Перенос клиента: ${client}`,
      submit: 'Перенести',
      fields: [{ name: 'group', label: 'Новая группа', type: 'select', options: others, required: true }],
    });
    if (values === null || values === undefined) return;
    await confirmed(ctx, 'Смена группы клиента', 'Сменить группу?', ['client', 'set-group', '--name', client, '--group', values.group]);
  };

  const actions = html`
    <${Action} primary icon="file-code" disabled=${busy} onClick=${() => act(() => generateFlow(ctx, { group: name }))}>Сгенерировать конфиги группы<//>
    <${Action} icon="scroll-text" disabled=${busy} onClick=${() => act(chooseTemplate)}>Шаблон…<//>
    <${Action} icon="rss" disabled=${busy} onClick=${() => act(() => showHeaders(ctx, 'group', name))}>Заголовки подписки<//>
    <${MoreMenu} items=${[{ label: 'Удалить группу', icon: 'trash-2', danger: true, disabled: busy, onClick: () => act(remove) }]} />`;

  return html`<${Loaded} title=${name} back=${back} state=${state}>
    ${() => html`<${Page} title=${name} back=${back} actions=${actions}>
      <${Card}>
        <${Facts} items=${[
          { label: 'Шаблон', value: html`<${TemplateLink} ctx=${ctx} template=${row.template} />` },
          { label: 'Клиентов', value: model.scalar(row.clients) },
          { label: 'Ноды', value: html`<${NodeChips} ctx=${ctx} nodes=${row.nodes} />` },
        ]} />
      <//>
      <${Loaded} title="Клиенты группы" state=${clients} inline>
        ${(data) => html`<${Card} title="Клиенты группы">
          <${DataTable} rows=${model.rowsOf(data).filter((item) => item && typeof item.name === 'string')} empty="Нет клиентов"
            href=${(item) => ctx.href('clients', item.name)}
            menu=${(item) => [{ label: 'Перенести в группу…', icon: 'folders', disabled: busy, onClick: () => act(() => move(item.name)) }]}
            columns=${[
              { key: 'name', label: 'Клиент', search: true },
              { key: 'subscription', label: 'Подписка', render: (item) => {
                const badge = model.subscriptionBadge(item);
                return html`<${Badge} tone=${badge.tone}>${badge.label}<//>`;
              } },
            ]} />
        <//>`}
      <//>
    <//>`}
  <//>`;
}
