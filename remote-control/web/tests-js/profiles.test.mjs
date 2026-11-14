// Модель «Профили нод» (`screens/profiles-model.js`): argv `profile add|set`,
// поля формы, `needsDomain` и потоки поверх поддельного `ctx`.
import test from 'node:test';
import assert from 'node:assert/strict';
import * as model from '../assets/js/screens/profiles-model.js';
import { initialValues, result } from '../assets/js/form-model.js';
import { isFailure } from '../assets/js/flows.js';

const edge = {
  name: 'edge', reality_mode: 'self-steal', sni_domain: null, site_source: 'random', vless_tcp: true,
  vless_xhttp: { topology: 'nginx', port: null }, vless_grpc: { port: 20000 }, hysteria2: { port: 30000, obfs: true },
  amneziawg: { port: 40000, dns: '1.1.1.1, 1.0.0.1' }, warp: true, warp_plus: false, ipv6: 'default',
  mihomo_version: 'v1.19.18', acme_email: 'a@example.com', nodes: ['de'],
};

/** Значения формы как после отправки: умолчания полей + `patch` (видимые поля). */
function submitted(fields, patch) {
  const values = { ...initialValues(fields), ...patch };
  return result(fields, values);
}

test('profile add: умолчания мастера — Self-Steal, VLESS TCP, случайный email, последняя версия', () => {
  const values = submitted(model.profileFields(), { name: 'edge' });
  assert.deepEqual(model.profileAddArgv(values), [
    'profile', 'add', '--name', 'edge', '--reality', 'self-steal', '--site-source', 'random',
    '--vless-tcp', 'on', '--xhttp', 'off', '--grpc', 'off', '--hysteria2', 'off', '--amneziawg', 'off',
    '--warp', 'off', '--ipv6', 'default', '--random-acme-email',
  ]);
});

test('profile add: SNI, все протоколы, порты, obfs, DNS, email и версия', () => {
  const values = submitted(model.profileFields(), {
    name: 'sni', reality: 'sni', sni_domain: 'www.example.com', xhttp: 'nginx',
    protocols: ['vless-tcp', 'xhttp', 'grpc', 'hysteria2', 'amneziawg', 'warp'],
    xhttp_port: '18443', grpc_port: '20000', hysteria2_port: '', hysteria2_obfs: true, amneziawg_port: '40000',
    amneziawg_dns: '9.9.9.9', ipv6: 'disabled', acme_email: 'me@example.com', mihomo_version: 'v1.19.20',
  });
  assert.deepEqual(model.profileAddArgv(values), [
    'profile', 'add', '--name', 'sni', '--reality', 'sni', '--sni-domain', 'www.example.com',
    '--vless-tcp', 'on', '--xhttp', 'reality', '--xhttp-port', '18443', '--grpc', 'on', '--grpc-port', '20000',
    '--hysteria2', 'on', '--hysteria2-obfs', 'on', '--amneziawg', 'on', '--amneziawg-port', '40000',
    '--amneziawg-dns', '9.9.9.9', '--warp', 'on', '--ipv6', 'disabled',
    '--acme-email', 'me@example.com', '--mihomo-version', 'v1.19.20',
  ]);
});

test('profile set: только изменённые флаги; без изменений — null', () => {
  const current = model.profileValues(edge);
  assert.equal(model.profileSetArgv('edge', current, edge), null);
  // Выключить gRPC и сменить IPv6.
  const changed = { ...current, protocols: current.protocols.filter((p) => p !== 'grpc'), ipv6: 'enabled' };
  assert.deepEqual(model.profileSetArgv('edge', changed, edge), ['profile', 'set', '--name', 'edge', '--grpc', 'off', '--ipv6', 'enabled']);
  // Переход на SNI: режим, домен; xHTTP становится Reality.
  const toSni = { ...current, reality: 'sni', sni_domain: 'www.example.com' };
  assert.deepEqual(model.profileSetArgv('edge', toSni, edge),
    ['profile', 'set', '--name', 'edge', '--reality', 'sni', '--sni-domain', 'www.example.com', '--xhttp', 'reality']);
  // Новый порт Hysteria2, очищенный порт gRPC не передаётся, очищенный email — случайный.
  const ports = { ...current, hysteria2_port: '31000', grpc_port: '', acme_email: '' };
  assert.deepEqual(model.profileSetArgv('edge', ports, edge),
    ['profile', 'set', '--name', 'edge', '--hysteria2-port', '31000', '--random-acme-email']);
  // Версия mihomo: новая — флаг, пустая — без флага.
  assert.deepEqual(model.profileSetArgv('edge', { ...current, mihomo_version: 'v1.20.0' }, edge),
    ['profile', 'set', '--name', 'edge', '--mihomo-version', 'v1.20.0']);
  assert.equal(model.profileSetArgv('edge', { ...current, mihomo_version: '' }, edge), null);
});

test('needsDomain: Self-Steal с Reality-транспортом, xHTTP или Hysteria2', () => {
  assert.equal(model.needsDomain(edge), true);
  assert.equal(model.needsDomain({ ...edge, reality_mode: 'sni' }), false);
  const awgOnly = { reality_mode: 'self-steal', vless_tcp: false, vless_xhttp: null, vless_grpc: null, hysteria2: null, amneziawg: { port: 1 } };
  assert.equal(model.needsDomain(awgOnly), false);
  assert.equal(model.needsDomain({ ...awgOnly, hysteria2: { port: 2 } }), true);
  assert.equal(model.needsDomain(undefined), false);
});

test('поля формы: условия видимости и проверки', () => {
  const fields = Object.fromEntries(model.profileFields().map((f) => [f.name, f]));
  assert.equal(fields.sni_domain.when({ reality: 'sni' }), true);
  assert.equal(fields.site_source.when({ reality: 'sni' }), false);
  assert.equal(fields.xhttp.when({ reality: 'sni', protocols: ['xhttp'] }), false);
  assert.equal(fields.xhttp_port.when({ reality: 'self-steal', xhttp: 'nginx', protocols: ['xhttp'] }), false);
  assert.equal(fields.xhttp_port.when({ reality: 'sni', xhttp: 'nginx', protocols: ['xhttp'] }), true);
  assert.equal(fields.hysteria2_obfs.when({ protocols: ['hysteria2'] }), true);
  assert.equal(fields.grpc_port.validate('70000'), model.PORT_INVALID);
  assert.equal(fields.grpc_port.validate(''), null);
  assert.equal(fields.sni_domain.validate('nodot'), model.DOMAIN_INVALID);
  assert.equal(fields.acme_email.validate('bad'), model.EMAIL_INVALID);
  assert.equal(fields.mihomo_version.validate('1.19'), model.VERSION_INVALID);
  assert.equal(model.profileFields({}, { editing: true }).some((f) => f.name === 'name'), false);
  // Кнопка «Случайный адрес» подставляет адрес формата ядра.
  assert.match(fields.acme_email.action.value(), /^user[0-9a-f]{8}@[0-9a-f]{6}\.com$/);
  assert.equal(model.randomAcmeEmail((n) => new Uint8Array(n).fill(0xab)), 'userabababab@ababab.com');
});

test('подписи списка: протоколы и Reality', () => {
  assert.equal(model.protocolsLabel(edge), 'TCP xHTTP gRPC HY2 AWG WARP');
  assert.equal(model.protocolsLabel({}), '—');
  assert.equal(model.realityLabel(edge), 'Self-Steal');
  assert.equal(model.realityLabel({ reality_mode: 'sni', sni_domain: 'www.example.com' }), 'SNI www.example.com');
  assert.deepEqual(model.profileRows({ profiles: [edge, null, { x: 1 }] }).map((p) => p.name), ['edge']);
  assert.deepEqual(model.profileRows([]), []);
});

/** Поддельный ctx: `steps` — `[argv, reply]`, `answers` — ответы окон по порядку. */
function scripted(steps, answers) {
  const queue = [...steps];
  const replies = [...answers];
  const record = { dialogs: [], notices: [], failed: 0, calls: [] };
  const dialog = (kind) => async (props) => { record.dialogs.push({ kind, ...props }); return replies.shift(); };
  const ctx = {
    async request(argv, options = {}) {
      const [expected, reply] = queue.shift();
      assert.deepEqual(argv, expected);
      record.calls.push([argv, options]);
      return reply;
    },
    runConfirmed: (_t, _q, argv, options) => ctx.request(argv, options),
    nodeRequest: (_n, argv, _r, options) => ctx.request(argv, options),
    form: dialog('form'), confirm: dialog('confirm'), show: dialog('show'),
    notify: (level, text) => record.notices.push([level, text]),
    failed: () => { record.failed += 1; },
    isFailure,
  };
  return { ctx, record, done: () => assert.equal(queue.length, 0, 'не все шаги пройдены') };
}

const ok = (data = {}) => ({ ok: true, data });
const fail = (code) => ({ ok: false, error: { code, message: '' } });

test('добавление профиля: успех открывает карточку, сбой — форма снова с прежним вводом', async () => {
  const values = submitted(model.profileFields(), { name: 'edge' });
  const argv = model.profileAddArgv(values);
  const s = scripted([[argv, fail('exists')], [argv, ok({ name: 'edge' })]], [values, values]);
  const opened = [];
  assert.equal(await model.addProfileFlow(s.ctx, (name) => opened.push(name)), true);
  assert.deepEqual(opened, ['edge']);
  assert.equal(s.record.failed, 1);
  assert.equal(s.record.dialogs[1].fields.find((f) => f.name === 'name').value, 'edge');
  s.done();
});

test('изменение профиля: profile set только с изменёнными, без изменений — без команды', async () => {
  const current = model.profileValues(edge);
  let s = scripted([[['profile', 'set', '--name', 'edge', '--warp', 'off'], ok()]],
    [{ ...current, protocols: current.protocols.filter((p) => p !== 'warp') }]);
  assert.equal(await model.editProfileFlow(s.ctx, edge), true);
  s.done();
  s = scripted([], [current]);
  assert.equal(await model.editProfileFlow(s.ctx, edge), false);
  assert.equal(s.record.notices.length, 1);
  s.done();
});

test('удаление и применение профиля', async () => {
  let s = scripted([[['profile', 'delete', '--name', 'edge'], fail('in_use')]], []);
  assert.equal(await model.deleteProfile(s.ctx, 'edge'), false);
  assert.equal(s.record.failed, 1);
  s.done();
  s = scripted([[['node', 'apply', '--profile', 'edge'], ok({ applied: ['de'], failed: [], unchanged: [] })]], [undefined]);
  await model.applyProfile(s.ctx, 'edge');
  assert.deepEqual(s.record.dialogs.map((d) => d.kind), ['show']);
  s.done();
});
