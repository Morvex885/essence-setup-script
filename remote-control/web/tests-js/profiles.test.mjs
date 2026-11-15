// Модель «Профили нод» (`screens/profiles-model.js`): argv `profile add|set`,
// поля формы, `needsDomain` и потоки поверх поддельного `ctx`.
import test from 'node:test';
import assert from 'node:assert/strict';
import * as model from '../assets/js/screens/profiles-model.js';
import { initialValues, result, liveErrors, suggestion } from '../assets/js/form-model.js';
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
  // Все протоколы edge включены: сокращения — из экспортированных PROTOCOLS, в их порядке.
  assert.equal(model.protocolsLabel(edge), model.PROTOCOLS.map((p) => p.short).join(' '));
  assert.notEqual(model.protocolsLabel({}), model.protocolsLabel(edge));
  const sni = model.realityLabel({ reality_mode: 'sni', sni_domain: 'www.example.com' });
  assert.notEqual(model.realityLabel(edge), sni);
  assert.ok(sni.includes('www.example.com'));
  assert.ok(!model.realityLabel(edge).includes('www.example.com'));
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

const VERSIONS = ['profile', 'mihomo-versions'];
const listing = { latest: 'v1.19.20', versions: ['v1.19.20', 'v1.19.19', 'v1.19.18'] };

test('добавление профиля: успех открывает карточку, сбой — форма снова с прежним вводом', async () => {
  const values = submitted(model.profileFields(), { name: 'edge' });
  const argv = model.profileAddArgv(values);
  // Список версий недоступен — только ручной ввод (пусто — последняя по ядру).
  const s = scripted([[VERSIONS, fail('failed')], [argv, fail('exists')], [argv, ok({ name: 'edge' })]], [values, values]);
  const opened = [];
  assert.equal(await model.addProfileFlow(s.ctx, (name) => opened.push(name)), true);
  assert.deepEqual(opened, ['edge']);
  assert.equal(s.record.failed, 1);
  assert.equal(s.record.calls[0][1].quiet, true);
  assert.equal(s.record.dialogs[1].fields.find((f) => f.name === 'name').value, 'edge');
  assert.equal(s.record.dialogs[0].fields.some((f) => f.name === 'mihomo_choice'), false);
  s.done();
});

test('изменение профиля: profile set только с изменёнными, без изменений — без команды', async () => {
  const current = { ...model.profileValues(edge), mihomo_choice: 'v1.19.18' };
  let s = scripted([[VERSIONS, ok(listing)], [['profile', 'set', '--name', 'edge', '--warp', 'off'], ok()]],
    [{ ...current, protocols: current.protocols.filter((p) => p !== 'warp') }]);
  assert.equal(await model.editProfileFlow(s.ctx, edge), true);
  // Текущая версия выбрана в списке.
  const choice = s.record.dialogs[0].fields.find((f) => f.name === 'mihomo_choice');
  assert.equal(choice.value, 'v1.19.18');
  assert.equal(choice.options.find((o) => o.value === 'v1.19.18').label, 'v1.19.18 (сейчас)');
  s.done();
  s = scripted([[VERSIONS, ok(listing)]], [current]);
  assert.equal(await model.editProfileFlow(s.ctx, edge), false);
  assert.equal(s.record.notices.length, 1);
  s.done();
});

test('изменение профиля: сбой profile set — форма снова с введённым, отказ формы — без команды', async () => {
  const current = model.profileValues(edge);
  const changed = { ...current, protocols: current.protocols.filter((p) => p !== 'warp'), hysteria2_port: '31000' };
  const argv = model.profileSetArgv('edge', changed, edge);
  const show = [['profile', 'show', '--name', 'edge'], ok(edge)];
  const s = scripted([[VERSIONS, fail('failed')], [argv, fail('locked')], show, [argv, ok()]], [changed, changed]);
  assert.equal(await model.editProfileFlow(s.ctx, edge), true);
  assert.equal(s.record.failed, 1);
  const refilled = s.record.dialogs[1].fields;
  assert.deepEqual(refilled.find((f) => f.name === 'protocols').value, changed.protocols);
  assert.equal(refilled.find((f) => f.name === 'hysteria2_port').value, '31000');
  s.done();
  const cancelled = scripted([[VERSIONS, fail('failed')], [argv, fail('locked')], show], [changed, null]);
  assert.equal(await model.editProfileFlow(cancelled.ctx, edge), false);
  cancelled.done();
  // partial не повторяет форму.
  const partial = scripted([[VERSIONS, fail('failed')], [argv, fail('partial')]], [changed]);
  assert.equal(await model.editProfileFlow(partial.ctx, edge), false);
  assert.equal(partial.record.dialogs.length, 1);
  partial.done();
  // Сбой после записи (checkpoint) сохранил ipv6=disabled: повтор считается от
  // перечитанного профиля — возврат к default уходит вместе с новым email;
  // форма показывает введённое пользователем.
  const first = { ...current, ipv6: 'disabled' };
  const second = { ...first, ipv6: 'default', acme_email: 'b@example.com' };
  const saved = { ...edge, ipv6: 'disabled' };
  const persisted = scripted([[VERSIONS, fail('failed')], 
    [['profile', 'set', '--name', 'edge', '--ipv6', 'disabled'], fail('checkpoint_failed')],
    [['profile', 'show', '--name', 'edge'], ok(saved)],
    [['profile', 'set', '--name', 'edge', '--ipv6', 'default', '--acme-email', 'b@example.com'], ok()],
  ], [first, second]);
  assert.equal(await model.editProfileFlow(persisted.ctx, edge), true);
  assert.equal(persisted.record.dialogs[1].fields.find((f) => f.name === 'ipv6').value, 'disabled');
  persisted.done();
});

test('версии mihomo: «Последняя», список, текущая, «Ввести вручную»; выбор и ручной ввод', () => {
  assert.deepEqual(model.versionOptions(listing).map((o) => [o.value, o.label]), [
    ['v1.19.20', 'Последняя (v1.19.20)'], ['v1.19.19', 'v1.19.19'], ['v1.19.18', 'v1.19.18'], [model.MANUAL_VERSION, 'Ввести вручную'],
  ]);
  // Текущая версия, которой нет в списке, — сразу после последней.
  assert.deepEqual(model.versionOptions({ latest: 'v1.19.30', versions: ['v1.19.30'] }, 'v1.19.18').map((o) => o.label),
    ['Последняя (v1.19.30)', 'v1.19.18 (сейчас)', 'Ввести вручную']);
  assert.deepEqual(model.versionOptions(null), []);
  assert.deepEqual(model.versionOptions({ message: 'x' }), []);
  const fields = Object.fromEntries(model.versionFields(listing).map((f) => [f.name, f]));
  assert.equal(fields.mihomo_choice.value, 'v1.19.20');
  assert.equal(fields.mihomo_version.when({ mihomo_choice: model.MANUAL_VERSION }), true);
  assert.equal(fields.mihomo_version.when({ mihomo_choice: 'v1.19.20' }), false);
  assert.match(fields.mihomo_version.hint, /vX\.Y\.Z.*v1\.19\.18/);
  assert.equal(model.chosenVersion({ mihomo_choice: 'v1.19.19', mihomo_version: 'v9.9.9' }), 'v1.19.19');
  assert.equal(model.chosenVersion({ mihomo_choice: model.MANUAL_VERSION, mihomo_version: ' v1.19.25 ' }), 'v1.19.25');
  assert.equal(model.chosenVersion({ mihomo_version: '' }), '');
  const values = submitted(model.profileFields({}, { versions: listing }), { name: 'edge' });
  assert.deepEqual(model.profileAddArgv(values).slice(-2), ['--mihomo-version', 'v1.19.20']);
  // Ручной ввод: формат и наименьшая версия, `1.19.20` → предложение `v1.19.20`.
  for (const bad of ['1.19', 'v1.19', 'v1.19.17', 'v0.99.99', 'latest']) assert.equal(model.versionError(bad), model.VERSION_INVALID, bad);
  for (const good of ['', 'v1.19.18', 'v1.20.0', 'v2.0.0']) assert.equal(model.versionError(good), null, good);
  assert.equal(model.versionSuggestion('1.19.20'), 'v1.19.20');
  assert.equal(model.versionSuggestion('1.19.1'), null);
});

test('имя профиля: живая проверка, понятное правило и предложение верного имени', () => {
  const name = model.profileFields().find((f) => f.name === 'name');
  assert.equal(name.live, true);
  assert.equal(name.validate('VLESS TCP HY2'), model.NAME_RULE);
  assert.equal(name.suggest('VLESS TCP HY2'), 'vless-tcp-hy2');
  assert.equal(name.validate('edge-full'), null);
  assert.equal(name.validate(''), null);
  assert.match(model.NAME_RULE, /без пробелов/);
  assert.equal(model.suggestName('Мой сервер №1'), 'moy-server-1');
  assert.equal(model.suggestName('  edge//full  '), 'edge-full');
  assert.equal(model.suggestName('Щука.ru'), 'shchuka.ru');
  assert.equal(model.suggestName('..'), null);
  for (const good of ['-', '_', 'a1._-b']) assert.ok(model.nameValid(good), good);
  for (const bad of ['', '.', '..', 'my client', 'клиент', 'x;id']) assert.ok(!model.nameValid(bad), bad);
  // Живые ошибки формы: невалидное имя выключает отправку, пустое — нет.
  const fields = model.profileFields();
  assert.deepEqual(Object.keys(liveErrors(fields, { ...initialValues(fields), name: 'my profile' })), ['name']);
  assert.deepEqual(liveErrors(fields, { ...initialValues(fields), name: '' }), {});
  assert.equal(suggestion(fields[0], 'my profile'), 'my-profile');
  assert.equal(suggestion(fields[0], 'edge'), null);
});

test('объяснения выборов: Reality, сайт-заглушка, протоколы, топология xHTTP, obfs, IPv6', () => {
  const fields = Object.fromEntries(model.profileFields().map((f) => [f.name, f]));
  for (const name of ['reality', 'site_source', 'xhttp', 'ipv6', 'protocols']) {
    assert.ok(fields[name].options.every((o) => typeof o.hint === 'string' && o.hint.length > 0), name);
  }
  assert.equal(fields.site_source.type, 'radio');
  assert.ok(fields.hysteria2_obfs.hint);
  assert.deepEqual(model.XHTTP_TOPOLOGIES.map((o) => o.label), ['Reality — отдельный порт', 'Через ваш сайт (nginx, порт 443)']);
  assert.equal(model.domainSuggestion('https://WWW.Example.com/path'), 'www.example.com');
  assert.equal(model.domainSuggestion('www.example.com'), null);
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

test('ключ WARP+: argv без ключа, ключ — секретом password; --clear; отмена — без команды', async () => {
  assert.deepEqual(model.warpLicenseArgv('edge'), ['profile', 'warp-license', '--name', 'edge']);
  assert.deepEqual(model.warpLicenseClearArgv('edge'), ['profile', 'warp-license', '--name', 'edge', '--clear']);
  let s = scripted([[model.warpLicenseArgv('edge'), ok({ name: 'edge', warp_plus: true })]], [{ password: 'KEY-1' }]);
  assert.equal(await model.warpLicenseFlow(s.ctx, 'edge'), true);
  assert.equal(s.record.dialogs[0].fields[0].type, 'secret');
  assert.deepEqual(s.record.calls[0][1], { secrets: { password: 'KEY-1' } });
  assert.ok(!s.record.calls[0][0].includes('KEY-1'));
  // Формат ключа — проверкой поля (как `warp_license_valid` ядра), не сбоем после закрытия формы.
  const validate = s.record.dialogs[0].fields[0].validate;
  assert.equal(validate, model.warpLicenseError);
  assert.equal(validate('KEY-1'), null);
  assert.equal(validate('a'.repeat(64)), null);
  assert.equal(validate('KEY!'), model.WARP_LICENSE_INVALID);
  assert.equal(validate('a'.repeat(65)), model.WARP_LICENSE_INVALID);
  assert.equal(validate(' KEY-1'), model.WARP_LICENSE_INVALID);
  s.done();
  s = scripted([], [null]);
  assert.equal(await model.warpLicenseFlow(s.ctx, 'edge'), false);
  s.done();
  s = scripted([[model.warpLicenseArgv('edge'), fail('invalid')]], [{ password: 'bad' }]);
  assert.equal(await model.warpLicenseFlow(s.ctx, 'edge'), false);
  assert.equal(s.record.failed, 1);
  s.done();
  s = scripted([[model.warpLicenseClearArgv('edge'), ok({ name: 'edge', warp_plus: false })]], []);
  assert.equal(await model.clearWarpLicense(s.ctx, 'edge'), true);
  s.done();
});
