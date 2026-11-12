// Ноды (`#/nodes`) и карточка ноды (`#/nodes/<имя>`) — перенос
// `tui/src/nodes.rs`: `Nodes`, `NodeCard`, `delete_node`, `add_node_with`,
// `harden`, `setup_ssh`, `aliases`, `offer_upload`, `interactive`.
import { html, useEffect, useState } from '../../vendor/preact-htm.js';
import { Card, Picker, SecretField, Field } from '../ui.js';
import { handleNodeCodes, reviewReply, setFlag, decisionFlag, isFailure } from '../flows.js';
import { errorMessage } from '../format.js';
import { useCommand, useBusy, Action, Actions, Context, Back, Loaded, rows } from './kit.js';
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
        ctx.notify('warn', 'Нода сохранена, но требует SSH-настройки: раздел «Ноды» → «Завершить отложенную SSH-настройку».');
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

const EMPTY_FORM = { name: '', ip: '', port: '', user: '', auth: 'key', password: '', tag: '' };

/** Форма добавления: поля и умолчания v1; пароль живёт только в состоянии формы. */
function AddForm({ ctx, busy, run, onClose }) {
  const [form, setForm] = useState(EMPTY_FORM);
  const update = (key) => (event) => setForm({ ...form, [key]: event.target.value });
  const submit = (event) => {
    event.preventDefault();
    const built = model.addNodeArgv(form);
    if (built.warning) {
      ctx.notify('warn', built.warning);
      return;
    }
    run(async () => {
      // Неудача оставляет форму открытой с введёнными полями для исправления.
      if (!(await addNode(ctx, built.argv, built.password))) return;
      setForm(EMPTY_FORM);
      onClose(true);
    });
  };
  const input = (key, label, placeholder = '') => html`<${Field} label=${label}>
    <input type="text" autocomplete="off" placeholder=${placeholder} value=${form[key]} onInput=${update(key)} />
  <//>`;
  return html`<${Card} title=${ADD_TITLE}>
    <form class="form" onSubmit=${submit}>
      ${input('name', 'Название', 'vps-1')}
      ${input('ip', 'IP')}
      ${input('port', 'SSH-порт', '22')}
      ${input('user', 'Логин', 'root')}
      <${Picker} label="Способ входа" value=${form.auth}
        options=${[{ value: 'key', label: 'SSH-ключ' }, { value: 'password', label: 'Пароль' }]}
        onChange=${(auth) => setForm({ ...form, auth, password: '' })} />
      ${form.auth === 'password' && html`<${SecretField} label="Пароль" value=${form.password}
        onInput=${(password) => setForm({ ...form, password })} />`}
      ${input('tag', 'Тег')}
      <${Actions}>
        <${Action} tone="create" disabled=${busy} onClick=${submit}>Добавить<//>
        <${Action} tone="plain" disabled=${busy} onClick=${() => { setForm(EMPTY_FORM); onClose(false); }}>Отмена<//>
      <//>
    </form>
  <//>`;
}

// ─── Отложенная SSH-настройка ────────────────────────────────────────────────

/** `node setup-ssh` под планом (`nodes.rs::setup_ssh`). */
async function setupSsh(ctx) {
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

// ─── Список нод ──────────────────────────────────────────────────────────────

function NodeList({ ctx }) {
  const list = useCommand(ctx, ['node', 'list']);
  const status = useCommand(ctx, ['status']);
  const [busy, run] = useBusy();
  const [adding, setAdding] = useState(false);
  const back = html`<${Back} ctx=${ctx} to="summary" />`;
  const reload = () => { list.reload(); status.reload(); };
  return html`<${Loaded} title="Ноды" state=${list} actions=${back}>${(data) => {
    const items = model.nodeItems(data);
    const actions = model.listActions(status.data);
    const act = (key) => {
      if (key === 'a') setAdding(true);
      else if (key === 'h') run(async () => { await setupSsh(ctx); reload(); });
    };
    return html`<div>
      <${Card} title="Ноды" actions=${back}>
        ${items.length === 0
          ? html`<${Context} lines=${[{ text: 'Нет нод', tone: 'dim' }]} />`
          : html`<${Actions} column>
              ${items.map((item) => html`<${Action} key=${item.name} tone=${item.tone} disabled=${busy}
                onClick=${() => ctx.navigate('nodes', item.name)}>${item.label}<//>`)}
            <//>`}
        <${Actions}>
          ${actions.map((action) => html`<${Action} key=${action.key} tone=${action.tone} disabled=${busy || (action.key === 'a' && adding)}
            onClick=${() => act(action.key)}>${action.label}<//>`)}
        <//>
      <//>
      ${adding && html`<${AddForm} ctx=${ctx} busy=${busy} run=${run}
        onClose=${(done) => { setAdding(false); if (done) reload(); }} />`}
    </div>`;
  }}<//>`;
}

// ─── Карточка ноды ───────────────────────────────────────────────────────────

/** Объём удаления из `delete_options`; `true`, если ноды больше нет (`nodes.rs::delete_node`). */
async function deleteNode(ctx, name, node) {
  const options = model.deleteOptions(node);
  if (options.length === 0) {
    ctx.notify('warn', 'Нет доступных вариантов удаления.');
    return false;
  }
  const index = await ctx.choose({ title: 'Объём удаления ноды', options });
  if (index === null) return false;
  const argv = model.deleteArgv(name, node.delete_options[index]);
  const reply = await ctx.nodeRequest(name, argv, { title: 'Удаление ноды', question: 'Удалить ноду в выбранном объёме?' });
  return reply.ok || (reply.error && reply.error.deleted === true);
}

/** Порт задаётся явно или подбирается ядром; план подтверждается (`nodes.rs::harden`). */
async function harden(ctx, name) {
  const title = 'Усиление защиты SSH';
  const label = 'SSH-порт (пусто — подобрать свободный)';
  const port = await ctx.ask({ title, label });
  if (port === null) return;
  let words = model.hardenArgv(name, port);
  for (;;) {
    let reply = await ctx.request(words);
    if (model.hardenAsksPort(words, reply)) {
      const again = await ctx.ask({ title, label });
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

/** Псевдонимы подключений ноды (`nodes.rs::aliases`): `''` — без изменений, `-` — удалить. */
export async function aliases(ctx, name) {
  const reply = await ctx.nodeRequest(name, ['node', 'aliases', '--name', name]);
  if (!reply.ok) return;
  const entries = rows(reply.data);
  if (entries.length === 0) {
    ctx.notify('info', 'Подключения на ноде не найдены.');
    return;
  }
  const title = `Псевдонимы подключений: ${name}`;
  const values = [];
  for (const entry of entries) {
    const value = await ctx.ask({ title, label: model.aliasPrompt(entry) });
    if (value === null) return;
    values.push(value);
  }
  const argv = model.aliasArgv(name, entries, values);
  if (!argv) {
    ctx.notify('info', 'Изменений нет.');
    return;
  }
  outcome(ctx, await ctx.request(argv));
}

/** Сохранение пароля SSH: значение — только в `secrets` запроса. */
async function storePassword(ctx, name) {
  const password = await ctx.askSecret({ title: `Нода: ${name}`, label: 'Пароль SSH' });
  if (!password) return;
  outcome(ctx, await ctx.request(['node', 'password', '--name', name], { secrets: { password } }));
}

function NodeCard({ ctx, name }) {
  const show = useCommand(ctx, ['node', 'show', '--name', name], [], { expect: 'not_found' });
  const [busy, run] = useBusy();
  useEffect(() => {
    if (show.reply && code(show.reply) === 'not_found') ctx.navigate('nodes');
  }, [show.reply]);
  const title = `Нода: ${name}`;
  const back = html`<${Back} ctx=${ctx} to="nodes" />`;
  const act = (key, node) => run(async () => {
    switch (key) {
      case 'o': await interactive(ctx, name, false); break;
      case 't': await interactive(ctx, name, true); break;
      case 'p': ctx.navigate('connections', name); return;
      case 'a': ctx.navigate('awg', name); return;
      case 'k': await ctx.nodeRequest(name, ['node', 'check', '--name', name]); break;
      case 'u':
        await ctx.nodeRequest(name, ['node', 'upload-scripts', '--name', name, '--force'],
          { title: 'Принудительная загрузка скриптов', question: 'Загрузить скрипты?' });
        break;
      case 'h': await harden(ctx, name); break;
      case 'r': {
        const next = await ctx.ask({ title: 'Переименование ноды', label: 'Новое имя ноды' });
        if (!next) return;
        const renamed = await ctx.call('node', 'rename', '--name', name, '--new-name', next);
        if (renamed.ok) {
          ctx.navigate('nodes', (renamed.data && typeof renamed.data.name === 'string' && renamed.data.name) || next);
          return;
        }
        outcome(ctx, renamed);
        break;
      }
      case 'e': {
        const tag = await ctx.ask({ title: 'Тег ноды', label: 'Тег' });
        if (tag === null) return;
        outcome(ctx, await ctx.call('node', 'tag', '--name', name, '--tag', tag));
        break;
      }
      case 'w': await storePassword(ctx, name); break;
      case 'l': await aliases(ctx, name); break;
      case 'd':
        if (await deleteNode(ctx, name, node)) { ctx.navigate('nodes'); return; }
        break;
      default: return;
    }
    show.reload();
  });
  return html`<${Loaded} title=${title} state=${show} actions=${back}>${(node) => html`
    <${Card} title=${title} actions=${back}>
      <${Context} lines=${model.cardContext(node)} />
      <${Actions}>
        ${model.cardActions(node).map((action) => html`<${Action} key=${action.key} tone=${action.tone} disabled=${busy}
          onClick=${() => act(action.key, node)}>${action.label}<//>`)}
      <//>
    <//>
  `}<//>`;
}

/** `#/nodes` — список, `#/nodes/<имя>` — карточка. */
export function NodesScreen({ ctx, param }) {
  return param
    ? html`<${NodeCard} key=${param} ctx=${ctx} name=${param} />`
    : html`<${NodeList} ctx=${ctx} />`;
}
