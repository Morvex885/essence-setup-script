// Ноды (`#/nodes`) и карточка ноды (`#/nodes/<имя>/<вкладка>`) — перенос
// `tui/src/nodes.rs`: `Nodes`, `NodeCard`, `delete_node`, `add_node_with`,
// `harden`, `setup_ssh`, `offer_upload`, `interactive`. Вкладки карточки:
// обзор, подключения (`connections.js`), AmneziaWG (`awg.js`), обслуживание.
import { html, useEffect } from '../../vendor/preact-htm.js';
import { Page, Card, DataTable, MoreMenu, Facts, Badge, Chips, Empty, Button } from '../ui.js';
import { handleNodeCodes, reviewReply, setFlag, decisionFlag, isFailure } from '../flows.js';
import { errorMessage } from '../format.js';
import { useCommand, useBusy, useMounted, Action, Actions, Loaded, rows } from './kit.js';
import { NodeConnections } from './connections.js';
import { NodeAwg } from './awg.js';
import * as model from './nodes-model.js';

export const nodeLabel = model.nodeLabel;

/** Зависимости `flows.js` из контекста экрана. */
function deps(ctx) {
  return { request: (words, options) => ctx.request(words, options), confirm: ctx.confirm, askSecret: ctx.askSecret, notify: ctx.notify };
}

function code(reply) {
  return reply && reply.error ? reply.error.code : null;
}

/** `nodes.rs::outcome`: текст ядра уже показан; отказ от плана — не сбой. */
function outcome(ctx, reply) {
  if (isFailure(reply)) ctx.failed();
}

const checkArgv = (name) => ['node', 'check', '--name', name];

// ─── Терминал и скрипты ──────────────────────────────────────────────────────

/**
 * `node shell` / `telegram menu` в оверлее терминала (`nodes.rs::interactive`).
 * Состояния ноды разрешаются и команда повторяется; устаревшие скрипты —
 * предложение загрузки; `conflict` — терминал этой ноды уже открыт.
 */
export async function interactive(ctx, name, telegram) {
  const argv = model.interactiveArgv(name, telegram);
  const title = telegram ? `Telegram Proxy: ${name}` : `Меню сервера: ${name}`;
  for (;;) {
    const reply = await ctx.terminal(argv, title, { expect: ['conflict', 'invalid'] });
    if (reply.ok) return;
    if (await handleNodeCodes(reply, name, deps(ctx))) continue;
    if (code(reply) === 'conflict') {
      ctx.notify('warn', 'Терминал этой ноды уже открыт');
      return;
    }
    if (code(reply) === 'invalid') {
      if (typeof reply.error.state === 'string') {
        await offerUpload(ctx, name, reply.error.state);
        return;
      }
      ctx.notify('error', errorMessage(reply));
    }
    outcome(ctx, reply);
    return;
  }
}

/** Явная загрузка скриптов (`nodes.rs::offer_upload`); меню заново не открывается. */
async function offerUpload(ctx, name, state) {
  const offer = model.uploadOffer(name, state);
  const choice = await ctx.choose({
    title: offer.title,
    context: [offer.condition],
    options: [{ value: 'u', label: offer.label, tone: 'change' }],
    cancel: 'Назад',
  });
  if (choice !== 'u') return;
  const reply = await ctx.nodeRequest(name, offer.argv, { title: 'Загрузка скриптов', question: 'Загрузить скрипты?' });
  if (reply.ok) ctx.notify('success', 'Скрипты загружены. Откройте меню снова.');
}

// ─── Добавление ──────────────────────────────────────────────────────────────

const ADD_TITLE = 'Добавление ноды';

/**
 * Попытки `node add` (`nodes.rs::add_node_with`): первый ключ сервера
 * принимается, изменённый заменяется только через план, `remote_failed` —
 * повтор с согласия (и, при входе по паролю, с новым паролем),
 * `onboarding_failed` — повтор или отложенная настройка. `true` — нода сохранена.
 */
async function addNode(ctx, base, password) {
  const secrets = password ? { password } : undefined;
  let hostKey = [...model.ACCEPT_HOST_KEY];
  let defer = false;
  for (;;) {
    const words = model.addAttemptArgv(base, hostKey, defer);
    const reply = !defer && hostKey[0] === '--replace-host-key'
      ? await ctx.runConfirmed('Ключ сервера изменился', 'Обновить ключ ноды?', words, { secrets })
      : await ctx.request(words, { secrets });
    if (reply.ok) {
      if (reply.data && reply.data.needs_setup === true) {
        ctx.notify('warn', 'Нода сохранена, но требует SSH-настройки: раздел «Ноды» → «Завершить SSH-настройку».');
      }
      return true;
    }
    switch (code(reply)) {
      case 'host_key_changed': {
        if (defer) { outcome(ctx, reply); return false; }
        const fingerprint = rows(reply.error.fingerprints)[0];
        if (typeof fingerprint !== 'string') { ctx.failed(); return false; }
        hostKey = ['--replace-host-key', fingerprint];
        break;
      }
      case 'remote_failed': {
        if (!(await ctx.confirm({ title: ADD_TITLE, question: 'Повторить попытку?' }))) return false;
        if (secrets) {
          const value = await ctx.askSecret({ title: ADD_TITLE, label: 'Новый пароль (пусто — прежний)', allowEmpty: true });
          if (value === null) return false;
          if (value) secrets.password = value;
        }
        break;
      }
      case 'onboarding_failed': {
        const choice = await ctx.choose({
          title: 'Не удалось настроить переносимый SSH-ключ',
          options: [
            { value: 'retry', label: 'Повторить', tone: 'change' },
            { value: 'defer', label: 'Сохранить ноду и настроить позже', tone: 'create' },
          ],
        });
        if (choice === null) return false;
        if (choice === 'defer') defer = true;
        break;
      }
      default:
        outcome(ctx, reply);
        return false;
    }
  }
}

/** Поля формы добавления (умолчания v1); `values` — прежний ввод без пароля. */
function addFields(values) {
  const keep = (name) => (values[name] === undefined ? undefined : values[name]);
  return [
    { name: 'name', label: 'Название', type: 'text', placeholder: 'vps-1', value: keep('name') },
    { name: 'ip', label: 'IP', type: 'text', required: true, value: keep('ip') },
    { name: 'port', label: 'SSH-порт', type: 'text', placeholder: '22', value: keep('port') },
    { name: 'user', label: 'Логин', type: 'text', placeholder: 'root', value: keep('user') },
    { name: 'tag', label: 'Тег', type: 'text', required: true, value: keep('tag') },
    {
      name: 'auth',
      label: 'Способ входа',
      type: 'radio',
      value: keep('auth') || 'key',
      options: [{ value: 'key', label: 'SSH-ключ' }, { value: 'password', label: 'Пароль' }],
    },
    { name: 'password', label: 'Пароль', type: 'secret', required: true, when: (current) => current.auth === 'password' },
  ];
}

/**
 * Добавление ноды одной формой (`nodes.rs::add_node_with`). Замечание
 * проверки — предупреждение и форма заново с прежним вводом (кроме пароля).
 * Сохранённая нода открывается; `true` — нода добавлена.
 */
export async function addNodeFlow(ctx) {
  let previous = {};
  for (;;) {
    const values = await ctx.form({ title: ADD_TITLE, fields: addFields(previous), submit: 'Добавить' });
    if (values === null) return false;
    const built = model.addNodeArgv(values);
    if (built.warning) {
      ctx.notify('warn', built.warning);
      previous = { ...values, password: undefined };
      continue;
    }
    if (!(await addNode(ctx, built.argv, built.password))) return false;
    ctx.navigate('nodes', values.name || 'vps-1');
    return true;
  }
}

// ─── Отложенная SSH-настройка ────────────────────────────────────────────────

/** `node setup-ssh` под планом (`nodes.rs::setup_ssh`). */
export async function setupSsh(ctx) {
  const words = ['node', 'setup-ssh'];
  for (;;) {
    const reply = await ctx.runConfirmed('Завершение SSH-настройки', 'Выполнить?', words);
    if (reply.ok) {
      if (reply.data && reply.data.ready === true) {
        ctx.notify('success', 'SSH-настройка завершена.');
      } else {
        for (const node of rows(reply.data && reply.data.deferred)) {
          ctx.notify('warn', `Отложено: ${model.plain(node.name)} — ${model.plain(node.issue)}`);
        }
      }
      return;
    }
    switch (code(reply)) {
      case 'key_provisioning_required': {
        const provision = await ctx.confirm({
          title: 'Переносимый SSH-ключ',
          context: [`Ноды: ${model.joinedPlain(reply.error.nodes)}`],
          question: 'Создать переносимый SSH-ключ для этих нод?',
        });
        setFlag(words, decisionFlag(code(reply)), provision ? 'yes' : 'no');
        break;
      }
      case 'onboarding_failed': {
        const choice = await ctx.choose({
          title: 'Не удалось настроить переносимый SSH-ключ',
          options: [
            { value: 'retry', label: 'Повторить', tone: 'change' },
            { value: 'defer', label: 'Отложить проблемные ноды', tone: 'change' },
          ],
        });
        if (choice === null) return;
        if (choice === 'defer') setFlag(words, '--on-failure', 'defer');
        break;
      }
      // Сообщение ядра уже показано; сбоя нет.
      case 'nothing_pending':
        return;
      default:
        outcome(ctx, reply);
        return;
    }
  }
}

// ─── Действия над нодой ──────────────────────────────────────────────────────

/** Объём удаления из `delete_options`; `true`, если ноды больше нет (`nodes.rs::delete_node`). */
async function deleteNode(ctx, name, node) {
  const options = model.deleteOptions(node);
  if (options.length === 0) {
    ctx.notify('warn', 'Нет доступных вариантов удаления.');
    return false;
  }
  const values = await ctx.form({
    title: `Удаление ноды: ${name}`,
    fields: [{ name: 'scope', label: 'Объём удаления', type: 'radio', options, required: true }],
    submit: 'Далее',
    tone: 'danger',
  });
  if (values === null) return false;
  const argv = model.deleteArgv(name, node.delete_options[values.scope]);
  const reply = await ctx.nodeRequest(name, argv, { title: 'Удаление ноды', question: 'Удалить ноду в выбранном объёме?' });
  return reply.ok || (reply.error && reply.error.deleted === true);
}

/** Удаление из списка: варианты удаления есть только в `node show`. */
async function deleteListed(ctx, name) {
  const shown = await ctx.request(['node', 'show', '--name', name]);
  if (!shown.ok) return false;
  return deleteNode(ctx, name, shown.data);
}

/**
 * «Изменить»: название и тег одной формой. Сначала `node rename` (сбой
 * останавливает), затем `node tag` под новым именем. Итог — текущее имя
 * ноды или `null` при отмене и сбое переименования.
 */
async function editNode(ctx, node) {
  const name = model.plain(node.name);
  const tag = model.plain(node.tag);
  const values = await ctx.form({
    title: `Изменение ноды: ${name}`,
    fields: [
      { name: 'name', label: 'Название', type: 'text', value: name, required: true },
      { name: 'tag', label: 'Тег', type: 'text', value: tag },
    ],
  });
  if (values === null) return null;
  let current = name;
  if (values.name !== name) {
    const renamed = await ctx.call('node', 'rename', '--name', name, '--new-name', values.name);
    if (!renamed.ok) {
      outcome(ctx, renamed);
      return null;
    }
    current = (renamed.data && typeof renamed.data.name === 'string' && renamed.data.name) || values.name;
  }
  if (values.tag !== tag) outcome(ctx, await ctx.call('node', 'tag', '--name', current, '--tag', values.tag));
  return current;
}

/** Сохранение пароля SSH: значение — только в `secrets` запроса. */
export async function setNodePassword(ctx, name) {
  const values = await ctx.form({
    title: `Пароль SSH: ${name}`,
    fields: [{ name: 'password', label: 'Пароль SSH', type: 'secret', required: true }],
  });
  if (values === null) return;
  outcome(ctx, await ctx.request(['node', 'password', '--name', name], { secrets: { password: values.password } }));
}

/** Порт задаётся явно или подбирается ядром; план подтверждается (`nodes.rs::harden`). */
async function harden(ctx, name) {
  const title = 'Усиление защиты SSH';
  const ask = async () => {
    const values = await ctx.form({
      title,
      fields: [{ name: 'port', label: 'SSH-порт (пусто — подобрать свободный)', type: 'text' }],
      submit: 'Далее',
    });
    return values === null ? null : values.port;
  };
  const port = await ask();
  if (port === null) return;
  let words = model.hardenArgv(name, port);
  for (;;) {
    let reply = await ctx.request(words);
    if (model.hardenAsksPort(words, reply)) {
      const again = await ask();
      if (again === null) return;
      words = model.hardenArgv(name, again);
      continue;
    }
    reply = await reviewReply(title, 'Усилить защиту SSH?', words, reply, deps(ctx), 2);
    if (reply.ok) return;
    if (code(reply) === 'hardening_failed') {
      if (reply.error.console_required === true) ctx.notify('warn', 'Проверьте доступ через консоль провайдера.');
      ctx.failed();
      return;
    }
    if (await handleNodeCodes(reply, name, deps(ctx))) continue;
    outcome(ctx, reply);
    return;
  }
}

// ─── Список нод ──────────────────────────────────────────────────────────────

function NodeList({ ctx }) {
  const list = useCommand(ctx, ['node', 'list']);
  const [busy, run] = useBusy();
  const pending = Boolean(ctx.status && ctx.status.ssh_setup_pending === true);
  const reload = () => { list.reload(); ctx.refreshStatus(); };
  const then = (action) => run(async () => {
    await action();
    reload();
  });
  const add = () => run(async () => {
    if (!(await addNodeFlow(ctx))) reload();
  });
  const addButton = html`<${Button} kind="primary" icon="plus" disabled=${busy} onClick=${add}>Добавить ноду<//>`;
  const actions = html`
    ${pending && html`<${Button} icon="key-round" disabled=${busy} onClick=${() => then(() => setupSsh(ctx))}>Завершить SSH-настройку<//>`}
    ${addButton}
  `;
  const columns = [
    { key: 'name', label: 'Название', search: true },
    { key: 'address', label: 'Адрес', search: true, render: (row) => html`<span class="mono">${row.address}</span>` },
    { key: 'tag', label: 'Тег', search: true },
    { key: 'auth', label: 'Вход' },
    { key: 'state', label: 'Состояние', render: (row) => html`<${Badge} tone=${row.state.tone}>${row.state.label}<//>` },
  ];
  const menu = (row) => [
    { label: 'Проверить подключение', icon: 'refresh-cw', disabled: busy, onClick: () => then(() => ctx.nodeRequest(row.name, checkArgv(row.name))) },
    { label: 'Изменить', icon: 'pencil', disabled: busy, onClick: () => then(() => editNode(ctx, row.node)) },
    { label: 'Удалить', icon: 'trash-2', danger: true, disabled: busy, onClick: () => then(() => deleteListed(ctx, row.name)) },
  ];
  return html`<${Loaded} title="Ноды" state=${list} actions=${actions}>${(data) => {
    const table = rows(data).map((node) => ({
      node,
      name: model.plain(node.name),
      address: `${model.plain(node.ip)}:${model.plain(node.port)}`,
      tag: model.plain(node.tag),
      auth: model.authLabel(node),
      state: model.nodeStatus(node),
    }));
    return html`<${Page} title="Ноды" actions=${actions}>
      <${Card}>
        ${table.length === 0
          ? html`<${Empty} icon="server" title="Нет нод" action=${addButton} />`
          : html`<${DataTable} columns=${columns} rows=${table} href=${(row) => ctx.href('nodes', row.name)} menu=${menu} />`}
      <//>
    <//>`;
  }}<//>`;
}

// ─── Карточка ноды ───────────────────────────────────────────────────────────

const TABS = [
  { id: 'overview', label: 'Обзор' },
  { id: 'connections', label: 'Подключения' },
  { id: 'awg', label: 'AmneziaWG' },
  { id: 'maintenance', label: 'Обслуживание' },
];

function Overview({ ctx, node }) {
  const password = model.passwordStatus(node);
  const issues = model.joinedPlain(node.issues);
  return html`<${Card}>
    <${Facts} items=${[
      { label: 'Адрес', value: html`<span class="mono">${model.plain(node.ip)}:${model.plain(node.port)}</span>` },
      { label: 'Пользователь', value: model.plain(node.user) },
      { label: 'Вход', value: model.authLabel(node) },
      { label: 'Пароль SSH', value: password && html`<${Badge} tone=${password.tone}>${password.label}<//>` },
      { label: 'Тег', value: model.plain(node.tag) || '—' },
      { label: 'Требует настройки', value: issues && html`<${Badge} tone="warn">${issues}<//>` },
      { label: 'Группы', value: html`<${Chips} items=${rows(node.groups).map((group) => ({ label: model.plain(group), href: ctx.href('groups', model.plain(group)) }))} />` },
      { label: 'Клиентов', value: model.plain(node.clients) },
    ]} />
  <//>`;
}

function OpRow({ title, desc, children }) {
  return html`<div class="op-row">
    <div class="op-text"><div class="op-title">${title}</div><div class="op-desc">${desc}</div></div>
    ${children}
  </div>`;
}

function Maintenance({ busy, act, remove }) {
  return html`
    <${Card} title="Обслуживание">
      <div class="op-list">
        <${OpRow} title="Проверить подключение" desc="Проверить SSH-подключение к ноде.">
          <${Action} icon="refresh-cw" disabled=${busy} onClick=${act.check}>Проверить<//>
        <//>
        <${OpRow} title="Загрузить скрипты принудительно" desc="Заново загрузить скрипты Essence на ноду, даже если версия совпадает.">
          <${Action} icon="upload" disabled=${busy} onClick=${act.upload}>Загрузить<//>
        <//>
        <${OpRow} title="Усилить защиту SSH" desc="Перенести SSH на другой порт и закрыть вход по паролю — по плану ядра.">
          <${Action} icon="shield" disabled=${busy} onClick=${act.harden}>Усилить<//>
        <//>
        <${OpRow} title="Telegram Proxy на ноде" desc="Меню Telegram Proxy этой ноды в терминале.">
          <${Action} icon="send" disabled=${busy} onClick=${act.telegram}>Открыть<//>
        <//>
      </div>
    <//>
    <${Card} title="Опасная зона" className="danger-zone">
      <div class="danger-row">
        <span>Удалить ноду из remote-control и, по выбору, компоненты Essence на сервере.</span>
        <${Action} tone="danger" icon="trash-2" disabled=${busy} onClick=${remove}>Удалить ноду<//>
      </div>
    <//>
  `;
}

function NodeCard({ ctx, name, tab }) {
  const show = useCommand(ctx, ['node', 'show', '--name', name], [], { expect: 'not_found' });
  const [busy, run] = useBusy();
  const mounted = useMounted();
  useEffect(() => {
    if (show.reply && code(show.reply) === 'not_found') ctx.navigate('nodes');
  }, [show.reply]);
  const back = { href: ctx.href('nodes'), label: 'Ноды' };
  const active = TABS.some((item) => item.id === tab) ? tab : TABS[0].id;
  const tabs = TABS.map((item) => ({ ...item, href: ctx.href('nodes', name, item.id), active: item.id === active }));
  /** Действие и перечитывание карточки. */
  const then = (action) => run(async () => {
    await action();
    show.reload();
  });
  const go = (...route) => { if (mounted.current) ctx.navigate(...route); };

  return html`<${Loaded} title=${name} back=${back} state=${show}>${(node) => {
    const password = node.auth === 'password';
    const status = model.nodeStatus(node);
    const act = {
      check: () => then(() => ctx.nodeRequest(name, checkArgv(name))),
      upload: () => then(() => ctx.nodeRequest(name, ['node', 'upload-scripts', '--name', name, '--force'],
        { title: 'Принудительная загрузка скриптов', question: 'Загрузить скрипты?' })),
      harden: () => then(() => harden(ctx, name)),
      telegram: () => then(() => interactive(ctx, name, true)),
    };
    const remove = () => run(async () => {
      if (await deleteNode(ctx, name, node)) { go('nodes'); return; }
      show.reload();
    });
    const edit = () => run(async () => {
      const current = await editNode(ctx, node);
      if (current !== null && current !== name) { go('nodes', current, active); return; }
      show.reload();
    });
    const actions = active === 'overview' && html`
      <${Button} kind="primary" icon="terminal" disabled=${busy} onClick=${() => then(() => interactive(ctx, name, false))}>Меню сервера<//>
      <${Button} icon="pencil" disabled=${busy} onClick=${edit}>Изменить<//>
      ${password && html`<${Button} icon="key-round" disabled=${busy} onClick=${() => then(() => setNodePassword(ctx, name))}>Пароль SSH<//>`}
      <${MoreMenu} items=${[
        { label: 'Проверить подключение', icon: 'refresh-cw', disabled: busy, onClick: act.check },
        { label: 'Удалить ноду', icon: 'trash-2', danger: true, disabled: busy, onClick: remove },
      ]} />
    `;
    let body;
    switch (active) {
      case 'connections': body = html`<${NodeConnections} ctx=${ctx} name=${name} />`; break;
      case 'awg': body = html`<${NodeAwg} ctx=${ctx} name=${name} />`; break;
      case 'maintenance': body = html`<${Maintenance} busy=${busy} act=${act} remove=${remove} />`; break;
      default: body = html`<${Overview} ctx=${ctx} node=${node} />`;
    }
    return html`<${Page} title=${name} back=${back} tabs=${tabs} actions=${actions}
      subtitle=${`${model.plain(node.ip)}:${model.plain(node.port)}`}
      badge=${html`<${Badge} tone=${status.tone}>${status.label}<//>`}>
      ${body}
    <//>`;
  }}<//>`;
}

/** `#/nodes` — список, `#/nodes/<имя>/<вкладка>` — карточка. */
export function NodesScreen({ ctx, param, tab }) {
  return param
    ? html`<${NodeCard} key=${param} ctx=${ctx} name=${param} tab=${tab} />`
    : html`<${NodeList} ctx=${ctx} />`;
}
