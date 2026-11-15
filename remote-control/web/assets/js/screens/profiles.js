// Профили нод (`#/profiles`, `#/profiles/<имя>`) — паритет с экраном TUI
// `Profiles` (`tui/src/nodes.rs`): список, добавление одной формой, карточка
// (`profile show`) с действиями «Изменить», «Применить на нодах профиля»,
// «Удалить». Логика — `profiles-model.js`.
import { html, useEffect } from '../../vendor/preact-htm.js';
import { Page, Card, DataTable, MoreMenu, Facts, Badge, Chips, Empty, Button } from '../ui.js';
import { useCommand, useBusy, useMounted, Loaded } from './kit.js';
import * as model from './profiles-model.js';

export function ProfilesScreen({ ctx, param }) {
  return param === null || param === undefined
    ? html`<${ProfileList} ctx=${ctx} />`
    : html`<${ProfileCard} ctx=${ctx} name=${param} key=${param} />`;
}

function NodeChips({ ctx, nodes }) {
  return html`<${Chips} items=${nodes.map((node) => ({ label: node, href: ctx.href('nodes', node) }))} />`;
}

// ─── Список ─────────────────────────────────────────────────────────────────

function ProfileList({ ctx }) {
  const state = useCommand(ctx, ['profile', 'list']);
  const [busy, run] = useBusy();
  const mounted = useMounted();
  const act = (action) => run(async () => { await action(); await state.reload(); });
  const add = () => run(async () => {
    let opened = false;
    await model.addProfileFlow(ctx, (name) => { opened = true; if (mounted.current) ctx.navigate('profiles', name); });
    if (!opened) await state.reload();
  });
  const actions = html`<${Button} kind="primary" icon="plus" disabled=${busy || !state.data} onClick=${add}>Добавить профиль<//>`;
  const menu = (row) => [
    { label: 'Применить на нодах профиля', icon: 'check', disabled: busy || model.profileNodes(row).length === 0,
      onClick: () => act(() => model.applyProfile(ctx, row.name)) },
    { label: 'Изменить', icon: 'pencil', disabled: busy, onClick: () => act(() => model.editProfileFlow(ctx, row)) },
    { label: 'Удалить', icon: 'trash-2', danger: true, disabled: busy, onClick: () => act(() => model.deleteProfile(ctx, row.name)) },
  ];
  return html`<${Loaded} title="Профили нод" state=${state} actions=${actions}>
    ${(data) => {
      const list = model.profileRows(data);
      return html`<${Page} title="Профили нод" actions=${actions}>
        <${Card}>
          ${list.length === 0
            ? html`<${Empty} icon="layers" title="Нет профилей" action=${actions} />`
            : html`<${DataTable} rows=${list} empty="Нет профилей" href=${(row) => ctx.href('profiles', row.name)} menu=${menu}
                columns=${[
                  { key: 'name', label: 'Профиль', search: true },
                  { key: 'reality', label: 'Reality', render: (row) => model.realityLabel(row) },
                  { key: 'protocols', label: 'Протоколы', render: (row) => model.protocolsLabel(row) },
                  { key: 'nodes', label: 'Нод', render: (row) => String(model.profileNodes(row).length) },
                ]} />`}
        <//>
      <//>`;
    }}
  <//>`;
}

// ─── Карточка ───────────────────────────────────────────────────────────────

const onOff = (value) => (value ? 'вкл.' : 'выкл.');

function ProfileCard({ ctx, name }) {
  const state = useCommand(ctx, model.profileShowArgv(name), [name], { expect: 'not_found' });
  const [busy, run] = useBusy();
  const mounted = useMounted();
  useEffect(() => {
    if (state.reply && state.reply.error && state.reply.error.code === 'not_found') ctx.navigate('profiles');
  }, [state.reply]);
  const back = { href: ctx.href('profiles'), label: 'Профили нод' };
  const act = (action) => run(async () => { await action(); await state.reload(); });
  const remove = () => run(async () => {
    if (await model.deleteProfile(ctx, name)) { if (mounted.current) ctx.navigate('profiles'); return; }
    await state.reload();
  });

  return html`<${Loaded} title=${name} back=${back} state=${state}>
    ${(profile) => {
      const nodes = model.profileNodes(profile);
      const xhttp = profile.vless_xhttp;
      const actions = html`
        <${Button} kind="primary" icon="check" disabled=${busy || nodes.length === 0}
          onClick=${() => act(() => model.applyProfile(ctx, name))}>Применить на нодах профиля<//>
        <${Button} icon="pencil" disabled=${busy} onClick=${() => act(() => model.editProfileFlow(ctx, profile))}>Изменить<//>
        <${MoreMenu} items=${[{ label: 'Удалить профиль', icon: 'trash-2', danger: true, disabled: busy, onClick: remove }]} />`;
      return html`<${Page} title=${name} back=${back} actions=${actions}
        badge=${model.needsDomain(profile) && html`<${Badge} tone="info">нужен домен ноды<//>`}>
        <${Card}>
          <${Facts} items=${[
            { label: 'Reality', value: model.realityLabel(profile) },
            { label: 'Сайт-заглушка', value: profile.reality_mode === 'sni' ? '—' : String(profile.site_source || '') },
            { label: 'VLESS TCP', value: onOff(profile.vless_tcp === true) },
            { label: 'VLESS xHTTP', value: xhttp ? `${xhttp.topology === 'nginx' ? 'через nginx' : 'Reality'}${xhttp.port ? `, порт ${xhttp.port}` : ''}` : 'выкл.' },
            { label: 'VLESS gRPC', value: profile.vless_grpc ? `порт ${profile.vless_grpc.port}` : 'выкл.' },
            { label: 'Hysteria2', value: profile.hysteria2 ? `порт ${profile.hysteria2.port}${profile.hysteria2.obfs ? ', obfs' : ''}` : 'выкл.' },
            { label: 'AmneziaWG', value: profile.amneziawg ? `порт ${profile.amneziawg.port}, DNS ${profile.amneziawg.dns || ''}` : 'выкл.' },
            { label: 'WARP', value: profile.warp ? (profile.warp_plus ? 'вкл., ключ WARP+ задан' : 'вкл.') : 'выкл.' },
            { label: 'IPv6', value: (model.IPV6_OPTIONS.find((o) => o.value === profile.ipv6) || { label: String(profile.ipv6 || '') }).label },
            { label: 'Email ACME', value: String(profile.acme_email || '') },
            { label: 'Версия mihomo', value: String(profile.mihomo_version || '') },
            { label: 'Ноды', value: nodes.length ? html`<${NodeChips} ctx=${ctx} nodes=${nodes} />` : 'нет' },
          ]} />
        <//>
      <//>`;
    }}
  <//>`;
}
