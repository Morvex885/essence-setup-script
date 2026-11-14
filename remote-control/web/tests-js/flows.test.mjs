// Тесты flows.js: таблица флагов решений, подтверждение плана и обработка
// состояний нод (`confirm.rs`, `nodes.rs`).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  decisionFlag, setFlag, clearFlag, runConfirmed, reviewReply, nodeRequest, setNodeDomain,
  handleNodeCodes, PLAN_KEEPS_CHANGING, PLAN_CHANGED, BROKEN_PLAN, NODE_CODES, OPERATION_FAILED, screenDialogs, retryable,
} from '../assets/js/flows.js';

const plan = (code, token, extra = {}) => ({
  ok: false,
  data: null,
  sync: null,
  exit: 2,
  error: { code, plan_token: token, plan: ['Удалить группу LAB'], ...extra },
});
const ok = () => ({ ok: true, data: {}, error: null, sync: null, exit: 0 });

/** `request`, отвечающий по сценарию: массив `{ argv, reply }`. */
function scripted(steps) {
  const sent = [];
  const remaining = [...steps];
  const request = async (argv) => {
    sent.push(argv);
    const index = remaining.findIndex((step) => JSON.stringify(step.argv) === JSON.stringify(argv));
    if (index < 0) throw new Error(`неожиданный argv: ${JSON.stringify(argv)}`);
    return remaining.splice(index, 1)[0].reply;
  };
  return { request, sent, assertDone: () => assert.equal(remaining.length, 0, 'не все шаги сценария выполнены') };
}

test('таблица decisionFlag совпадает с confirm.rs::decision_flag', () => {
  assert.deepEqual(
    NODE_CODES.map((code) => [code, decisionFlag(code)]),
    [
      ['missing_secret', null],
      ['host_key_changed', null],
      ['host_key_unknown', null],
      ['needs_setup', null],
    ],
  );
  assert.equal(decisionFlag('repo_create_required'), '--create-repo');
  assert.equal(decisionFlag('repo_private_required'), '--make-private');
  assert.equal(decisionFlag('storage_mode_required'), '--storage');
  assert.equal(decisionFlag('existing_config_action_required'), '--existing');
  assert.equal(decisionFlag('key_provisioning_required'), '--provision-keys');
  assert.equal(decisionFlag('cache_skip_required'), '--without-cache');
  assert.equal(decisionFlag('target_replace_required'), '--replace-target');
  assert.equal(decisionFlag('delete_scope_required'), '--scope');
  assert.equal(decisionFlag('on_failure_required'), '--on-failure');
  assert.equal(decisionFlag('auth_required'), null);
  assert.equal(decisionFlag(''), null);
  assert.equal(decisionFlag('unknown_required'), null);
});

test('setFlag не дублирует флаг и обновляет значение', () => {
  const argv = [];
  setFlag(argv, '--provision-keys', 'no');
  setFlag(argv, '--provision-keys', 'yes');
  assert.deepEqual(argv, ['--provision-keys', 'yes']);
  setFlag(argv, '--yes');
  setFlag(argv, '--yes');
  assert.deepEqual(argv, ['--provision-keys', 'yes', '--yes']);
  const withOld = ['node', 'harden', '--name', 'n', '--port', '22'];
  setFlag(withOld, '--port', '2222');
  assert.deepEqual(withOld, ['node', 'harden', '--name', 'n', '--port', '2222']);
  assert.deepEqual(clearFlag(['--yes', 'x', '--yes'], '--yes'), ['x']);
});

test('runConfirmed: отказ не отправляет мутацию и возвращает последний ответ', async () => {
  const words = ['group', 'delete', '--name', 'LAB'];
  const engine = scripted([{ argv: words, reply: plan('confirmation_required', 'one') }]);
  const result = await runConfirmed('Удаление', 'Удалить группу?', words, {
    request: engine.request,
    confirm: async () => false,
  });
  assert.equal(result.ok, false);
  assert.equal(engine.sent.length, 1);
  engine.assertDone();
});

test('runConfirmed: план, повтор с --yes --plan-token, успех', async () => {
  const words = ['group', 'delete', '--name', 'LAB'];
  const confirmed = [...words, '--yes', '--plan-token', 'one'];
  const engine = scripted([
    { argv: words, reply: plan('confirmation_required', 'one') },
    { argv: confirmed, reply: ok() },
  ]);
  const answers = [];
  const result = await runConfirmed('Удаление', 'Удалить группу?', words, {
    request: engine.request,
    confirm: async (question) => { answers.push(question); return true; },
  });
  assert.equal(result.ok, true);
  assert.deepEqual(answers, [{ title: 'Удаление', plan: ['Удалить группу LAB'], question: 'Удалить группу?' }]);
});
test('runConfirmed: plan_changed дважды, на третий — сообщение и отказ', async () => {
  const words = ['node', 'delete', '--name', 'de'];
  const base = [...words, '--yes'];
  const engine = scripted([
    { argv: words, reply: plan('confirmation_required', 'one') },
    { argv: [...base, '--plan-token', 'one'], reply: plan('plan_changed', 'two') },
    { argv: [...base, '--plan-token', 'two'], reply: plan('plan_changed', 'three') },
    { argv: [...base, '--plan-token', 'three'], reply: plan('plan_changed', 'four') },
  ]);
  const notices = [];
  const result = await runConfirmed('Удаление', 'Удалить ноду?', words, {
    request: engine.request,
    confirm: async () => true,
    notify: (level, text) => notices.push([level, text]),
  });
  assert.equal(result.ok, false);
  assert.equal(result.error.plan_token, 'four');
  assert.deepEqual(notices, [
    ['warn', PLAN_CHANGED],
    ['warn', PLAN_CHANGED],
    ['warn', PLAN_KEEPS_CHANGING],
  ]);
  engine.assertDone();
});

test('runConfirmed: plan_changed обновляет --port из error.port', async () => {
  const words = ['node', 'harden', '--name', 'n', '--port', '22'];
  const changed = plan('plan_changed', 'new', { port: 2222 });
  const engine = scripted([
    { argv: ['node', 'harden', '--name', 'n', '--port', '2222', '--yes', '--plan-token', 'new'], reply: ok() },
  ]);
  const result = await reviewReply('Укрепление', 'Продолжить?', words, changed, {
    request: engine.request,
    confirm: async () => true,
  });
  assert.equal(result.ok, true);
  engine.assertDone();
});

test('runConfirmed: сломанный план (без токена) — сообщение об ошибке', async () => {
  const broken = { ok: false, error: { code: 'confirmation_required', plan: [] }, data: null, sync: null };
  const notices = [];
  const result = await runConfirmed('x', 'y?', ['a'], {
    request: async () => broken,
    confirm: async () => true,
    notify: (level, text) => notices.push([level, text]),
  });
  assert.equal(result, broken);
  assert.deepEqual(notices, [['error', BROKEN_PLAN]]);
});

function nodeDeps(engine) {
  return {
    request: engine.request,
    confirm: async ({ question }) => question === 'Доверять новому ключу?' || question.startsWith('Пароль SSH'),
    askSecret: async () => 's3cret',
    notify: () => {},
  };
}

test('nodeRequest missing_secret: сохранение пароля и повтор команды', async () => {
  const words = ['node', 'check', '--name', 'de'];
  const engine = scripted([
    { argv: words, reply: plan('missing_secret', '', { secret: 'password' }) },
    { argv: ['node', 'password', '--name', 'de'], reply: ok() },
    { argv: words, reply: ok() },
  ]);
  const secrets = [];
  const result = await nodeRequest('de', words, null, {
    ...nodeDeps(engine),
    request: async (argv, options) => {
      if (options && options.secrets) secrets.push(options.secrets);
      return engine.request(argv);
    },
    askSecret: async () => 'pw',
  });
  assert.equal(result.ok, true);
  assert.deepEqual(secrets, [{ password: 'pw' }]);
  engine.assertDone();
});

test('nodeRequest missing_secret: отказ не сохраняет и не повторяет', async () => {
  const words = ['node', 'check', '--name', 'de'];
  const engine = scripted([{ argv: words, reply: plan('missing_secret', '') }]);
  const result = await nodeRequest('de', words, null, {
    request: engine.request,
    confirm: async () => false,
  });
  assert.equal(result.ok, false);
  engine.assertDone();
});

test('nodeRequest host_key_changed: доверие ключу через подтверждение и повтор', async () => {
  const words = ['node', 'check', '--name', 'de'];
  const trust = ['node', 'trust-host-key', '--name', 'de', '--host-key', 'SHA256:first'];
  const engine = scripted([
    { argv: words, reply: plan('host_key_changed', '', { fingerprints: ['SHA256:first', 'SHA256:second'] }) },
    { argv: trust, reply: plan('confirmation_required', 'tok') },
    { argv: [...trust, '--yes', '--plan-token', 'tok'], reply: ok() },
    { argv: words, reply: ok() },
  ]);
  const result = await nodeRequest('de', words, null, nodeDeps(engine));
  assert.equal(result.ok, true);
  engine.assertDone();
});

test('nodeRequest host_key_unknown без отпечатков — ответ как есть', async () => {
  const words = ['node', 'check', '--name', 'de'];
  const reply = plan('host_key_unknown', '', { fingerprints: [] });
  const engine = scripted([{ argv: words, reply }]);
  const result = await nodeRequest('de', words, null, nodeDeps(engine));
  assert.equal(result, reply);
  engine.assertDone();
});

test('nodeRequest needs_setup: уведомление без повтора', async () => {
  const words = ['node', 'check', '--name', 'de'];
  const engine = scripted([{ argv: words, reply: plan('needs_setup', '') }]);
  const notices = [];
  const result = await nodeRequest('de', words, null, {
    request: engine.request,
    confirm: async () => true,
    askSecret: async () => null,
    notify: (level, text) => notices.push([level, text]),
  });
  assert.equal(result.ok, false);
  // `nodes.rs`: уведомление `needs_setup`, затем `outcome` → `ctx.failed()`.
  assert.equal(notices.length, 2);
  assert.match(notices[0][1], /SSH-настройки/);
  assert.deepEqual(notices[1], ['warn', OPERATION_FAILED]);
  engine.assertDone();
});

test('nodeRequest: оставшийся сбой — OPERATION_FAILED, отказ от плана — без сообщения', async () => {
  const words = ['node', 'check', '--name', 'de'];
  const failing = scripted([{ argv: words, reply: plan('ssh_failed', '') }]);
  const notices = [];
  const deps = (engine) => ({ request: engine.request, confirm: async () => false, askSecret: async () => null, notify: (level, text) => notices.push([level, text]) });
  await nodeRequest('de', words, null, deps(failing));
  assert.deepEqual(notices, [['warn', OPERATION_FAILED]]);
  failing.assertDone();
  notices.length = 0;
  const refused = scripted([{ argv: words, reply: plan('confirmation_required', 'tok') }]);
  const result = await nodeRequest('de', words, { title: 'T', question: 'Q?' }, deps(refused));
  assert.equal(result.error.code, 'confirmation_required');
  assert.deepEqual(notices, []);
  refused.assertDone();
});

test('nodeRequest expect: ожидаемый код — ответ экрану без OPERATION_FAILED, request получает expect', async () => {
  const words = ['awg', 'status', '--name', 'de'];
  const sent = [];
  const notices = [];
  const deps = {
    request: async (argv, options) => { sent.push([argv, options]); return { ok: false, error: { code: 'not_found', message: '' } }; },
    confirm: async () => false, askSecret: async () => null, notify: (level, text) => notices.push([level, text]),
  };
  const result = await nodeRequest('de', words, null, deps, { expect: 'not_found' });
  assert.equal(result.error.code, 'not_found');
  assert.deepEqual(sent, [[words, { expect: 'not_found' }]]);
  assert.deepEqual(notices, []);
  // Без expect — прежнее поведение.
  await nodeRequest('de', words, null, deps);
  assert.deepEqual(sent[1], [words, {}]);
  assert.deepEqual(notices, [['warn', OPERATION_FAILED]]);
});

test('handleNodeCodes: прочий код не обрабатывается', async () => {
  assert.equal(await handleNodeCodes(ok(), 'de', { request: async () => ok(), confirm: async () => true }), false);
  assert.equal(await handleNodeCodes({ ok: false, error: { code: 'not_found' } }, 'de', { request: async () => ok(), confirm: async () => true }), false);
});

test('screenDialogs: после ухода с экрана окна сразу отменяются, операции и прочее — как есть', async () => {
  const opened = [];
  const api = {
    confirm: async () => { opened.push('confirm'); return true; },
    askSecret: async () => { opened.push('secret'); return 's'; },
    ask: async () => { opened.push('text'); return 't'; },
    choose: async () => { opened.push('choose'); return 'x'; },
    form: async () => { opened.push('form'); return {}; },
    show: async () => { opened.push('show'); return 'shown'; },
    operation: () => 'operation',
    dialogOpen: () => false,
  };
  let alive = true;
  const scoped = screenDialogs(api, () => alive);
  assert.equal(await scoped.confirm({}), true);
  assert.deepEqual(await scoped.form({}), {});
  alive = false;
  assert.equal(await scoped.confirm({}), false);
  assert.equal(await scoped.askSecret({}), null);
  assert.equal(await scoped.ask({}), null);
  assert.equal(await scoped.choose({}), null);
  assert.equal(await scoped.form({}), null);
  assert.equal(await scoped.show({}), undefined);
  assert.deepEqual(opened, ['confirm', 'form'], 'окна ушедшего экрана не открываются');
  assert.equal(scoped.operation(), 'operation');
  assert.equal(scoped.dialogOpen, api.dialogOpen);
});

test('screenDialogs: цикл заголовков подписки завершается после ухода с экрана', async () => {
  const { showHeaders } = await import('../assets/js/screens/clients-model.js');
  let alive = true;
  const requests = [];
  const api = {
    // «Установить», затем форма, закрытая уходом с экрана (`cancelAll` → `null`).
    choose: async () => 'set',
    form: async () => { alive = false; return null; },
  };
  const ctx = {
    ...screenDialogs(api, () => alive),
    request: async (argv) => { requests.push(argv); return { ok: true, data: { headers: [] } }; },
    failed: () => assert.fail('нет сбоя'),
  };
  await showHeaders(ctx, 'client', 'alice');
  assert.equal(requests.length, 2, 'после ухода — одно перечитывание и выход без окна');
});

test('retryable: сбой без изменений — да; успех, отказ от плана, partial — нет', () => {
  const failed = (code) => ({ ok: false, data: null, error: { code, message: '' } });
  assert.equal(retryable(failed('locked')), true);
  for (const reply of [{ ok: true, data: null }, failed('confirmation_required'), failed('plan_changed'), failed('partial')]) {
    assert.equal(retryable(reply), false, JSON.stringify(reply));
  }
});

test('handleNodeCodes domain_required у node apply --name: node domain и повтор', async () => {
  const words = ['node', 'apply', '--name', 'de'];
  const engine = scripted([
    { argv: words, reply: { ok: false, error: { code: 'domain_required', name: 'de' } } },
    { argv: ['node', 'domain', '--name', 'de', '--domain', 'de.example.com'], reply: ok() },
    { argv: words, reply: ok() },
  ]);
  const asked = [];
  const result = await nodeRequest('de', words, null, {
    request: engine.request, confirm: async () => true, askSecret: async () => null,
    ask: async (props) => { asked.push(props); return ' de.example.com '; },
  });
  assert.equal(result.ok, true);
  assert.equal(asked.length, 1);
  engine.assertDone();
  // Отказ от ввода — без повтора.
  const refused = scripted([{ argv: words, reply: { ok: false, error: { code: 'domain_required', name: 'de' } } }]);
  const again = await nodeRequest('de', words, null, { request: refused.request, confirm: async () => true, ask: async () => null });
  assert.equal(again.error.code, 'domain_required');
  refused.assertDone();
});

test('setNodeDomain: пустой ввод и пустое имя — без запроса', async () => {
  const engine = scripted([{ argv: ['node', 'domain', '--name', 'de', '--domain', 'de.example.com'], reply: ok() }]);
  assert.equal(await setNodeDomain('de', { request: engine.request, ask: async () => '  ' }), false);
  assert.equal(await setNodeDomain('', { request: engine.request, ask: async () => 'de.example.com' }), false);
  assert.equal(await setNodeDomain('de', { request: engine.request, ask: async () => 'de.example.com' }), true);
  engine.assertDone();
});

test('nodeRequest под планом: expect и operation — expect у обоих запросов, operation только у подтверждённого', async () => {
  const words = ['node', 'apply', '--name', 'de'];
  const sent = [];
  const replies = [plan('confirmation_required', 't'), { ok: false, error: { code: 'partial', failed: [] } }];
  const notices = [];
  const result = await nodeRequest('de', words, { title: 'T', question: 'Q?' }, {
    request: async (argv, options) => { sent.push([argv, options]); return replies.shift(); },
    confirm: async () => true, notify: (level, text) => notices.push([level, text]),
  }, { expect: ['partial'], operation: 'Применение' });
  assert.equal(result.error.code, 'partial');
  assert.deepEqual(sent[0][1].expect, ['partial']);
  assert.equal(sent[0][1].operation, undefined);
  assert.deepEqual(sent[1][0], [...words, '--yes', '--plan-token', 't']);
  assert.equal(sent[1][1].operation, 'Применение');
  assert.deepEqual(notices, []);
});
