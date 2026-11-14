// Модель экрана «Профили нод» без DOM — паритет с мастером профиля TUI
// (`tui/src/nodes.rs::Profiles`): поля формы, argv `profile add|set|delete`,
// подписи списка и потоки поверх `ctx`. Значения флагов — грамматика ядра
// (`profile add|set`, `reality=self-steal|sni`, `xhttp=off|reality|nginx`,
// протоколы `on|off`, `ipv6=default|enabled|disabled`).
import { asList, strings } from '../format.js';
import { applyFlow, applyProfileArgv } from './apply-model.js';
import { retryable } from '../flows.js';

/** Протоколы формы: значение поля `protocols` → подпись и сокращение списка. */
export const PROTOCOLS = [
  { value: 'vless-tcp', label: 'VLESS TCP', short: 'TCP' },
  { value: 'xhttp', label: 'VLESS xHTTP', short: 'xHTTP' },
  { value: 'grpc', label: 'VLESS gRPC', short: 'gRPC' },
  { value: 'hysteria2', label: 'Hysteria2', short: 'HY2' },
  { value: 'amneziawg', label: 'AmneziaWG', short: 'AWG' },
  { value: 'warp', label: 'WARP', short: 'WARP' },
];

export const REALITY_OPTIONS = [
  { value: 'self-steal', label: 'Self-Steal — у ноды свой домен' },
  { value: 'sni', label: 'SNI — маскировка под чужой домен, нода без домена' },
];
export const SITE_SOURCES = [
  { value: 'random', label: 'Случайный' },
  { value: 'simple', label: 'simple-web-templates' },
  { value: 'sni', label: 'sni-templates' },
  { value: 'nothing', label: 'nothing-sni' },
];
export const XHTTP_TOPOLOGIES = [
  { value: 'reality', label: 'Reality' },
  { value: 'nginx', label: 'Через nginx сайта' },
];
export const IPV6_OPTIONS = [
  { value: 'default', label: 'Как в системе' },
  { value: 'enabled', label: 'Включить' },
  { value: 'disabled', label: 'Отключить' },
];

export const PORT_INVALID = 'Порт — число от 1 до 65535.';
export const DOMAIN_INVALID = 'Некорректный домен.';
export const EMAIL_INVALID = 'Некорректный email.';
export const VERSION_INVALID = 'Версия в виде vX.Y.Z.';

const DOMAIN_RE = /^(?=.{1,253}$)[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$/;
const EMAIL_RE = /^[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$/;

const text = (value) => (typeof value === 'string' ? value.trim() : value === null || value === undefined ? '' : String(value));

/** Порт: пусто — допустимо (случайный или прежний), иначе 1…65535. Текст ошибки или `null`. */
export function portError(value) {
  const port = text(value);
  if (port === '') return null;
  return /^[0-9]+$/.test(port) && Number(port) >= 1 && Number(port) <= 65535 ? null : PORT_INVALID;
}

/** Домен (`validation::domain_valid` ядра): метки, минимум одна точка. */
export function domainValid(value) {
  return DOMAIN_RE.test(text(value));
}

export const domainError = (value) => (text(value) === '' || domainValid(value) ? null : DOMAIN_INVALID);
export const emailError = (value) => (text(value) === '' || EMAIL_RE.test(text(value)) ? null : EMAIL_INVALID);
export const versionError = (value) => (text(value) === '' || /^v[0-9]+\.[0-9]+\.[0-9]+$/.test(text(value)) ? null : VERSION_INVALID);

/** Случайный ACME email формата ядра `user<8 hex>@<6 hex>.com`; `random(n)` — n байт. */
export function randomAcmeEmail(random = (n) => globalThis.crypto.getRandomValues(new Uint8Array(n))) {
  const hex = (n) => Array.from(random(n), (byte) => byte.toString(16).padStart(2, '0')).join('');
  return `user${hex(4)}@${hex(3)}.com`;
}

/** Профиль из ответа `profile list` (`{ profiles: [...] }`). */
export function profileRows(data) {
  return asList(data && data.profiles).filter((row) => row && typeof row.name === 'string');
}

/** Нужен ли ноде этого профиля домен: Self-Steal и включён Reality-транспорт, xHTTP или Hysteria2. */
export function needsDomain(profile) {
  if (!profile || profile.reality_mode !== 'self-steal') return false;
  return profile.vless_tcp === true || Boolean(profile.vless_xhttp) || Boolean(profile.vless_grpc) || Boolean(profile.hysteria2);
}

/** Включённые протоколы профиля (значения `PROTOCOLS`). */
export function enabledProtocols(profile) {
  const on = [];
  if (profile.vless_tcp === true) on.push('vless-tcp');
  if (profile.vless_xhttp) on.push('xhttp');
  if (profile.vless_grpc) on.push('grpc');
  if (profile.hysteria2) on.push('hysteria2');
  if (profile.amneziawg) on.push('amneziawg');
  if (profile.warp === true) on.push('warp');
  return on;
}

/** Сокращения протоколов для списка: `TCP xHTTP gRPC HY2 AWG WARP`. */
export function protocolsLabel(profile) {
  const on = enabledProtocols(profile);
  return PROTOCOLS.filter((item) => on.includes(item.value)).map((item) => item.short).join(' ') || '—';
}

/** Режим Reality: `Self-Steal` или `SNI <домен>`. */
export function realityLabel(profile) {
  return profile.reality_mode === 'sni' ? `SNI ${text(profile.sni_domain)}`.trim() : 'Self-Steal';
}

const portText = (block) => (block && block.port !== null && block.port !== undefined ? String(block.port) : '');

/** Значения формы из профиля (`profile show`). */
export function profileValues(profile) {
  return {
    name: text(profile.name),
    reality: profile.reality_mode === 'sni' ? 'sni' : 'self-steal',
    sni_domain: text(profile.sni_domain),
    site_source: text(profile.site_source) || 'random',
    protocols: enabledProtocols(profile),
    xhttp: profile.vless_xhttp && profile.vless_xhttp.topology === 'nginx' ? 'nginx' : 'reality',
    xhttp_port: portText(profile.vless_xhttp),
    grpc_port: portText(profile.vless_grpc),
    hysteria2_port: portText(profile.hysteria2),
    hysteria2_obfs: Boolean(profile.hysteria2 && profile.hysteria2.obfs === true),
    amneziawg_port: portText(profile.amneziawg),
    amneziawg_dns: profile.amneziawg ? text(profile.amneziawg.dns) : '',
    ipv6: text(profile.ipv6) || 'default',
    acme_email: text(profile.acme_email),
    mihomo_version: text(profile.mihomo_version),
  };
}

/**
 * Флаги желаемого профиля по значениям формы — пары `[флаг, значение]` в
 * порядке грамматики. Без email и версии mihomo (их правила у add и set разные).
 */
export function profileFlags(values) {
  const on = (protocol) => asList(values.protocols).includes(protocol);
  const flag = (protocol) => (on(protocol) ? 'on' : 'off');
  const flags = [];
  const sni = values.reality === 'sni';
  flags.push(['--reality', sni ? 'sni' : 'self-steal']);
  if (sni) flags.push(['--sni-domain', text(values.sni_domain)]);
  else flags.push(['--site-source', text(values.site_source) || 'random']);
  flags.push(['--vless-tcp', flag('vless-tcp')]);
  // При SNI топология xHTTP всегда Reality: nginx-вариант требует сайта ноды.
  const topology = on('xhttp') ? (sni ? 'reality' : (values.xhttp === 'nginx' ? 'nginx' : 'reality')) : 'off';
  flags.push(['--xhttp', topology]);
  if (topology === 'reality' && text(values.xhttp_port)) flags.push(['--xhttp-port', text(values.xhttp_port)]);
  flags.push(['--grpc', flag('grpc')]);
  if (on('grpc') && text(values.grpc_port)) flags.push(['--grpc-port', text(values.grpc_port)]);
  flags.push(['--hysteria2', flag('hysteria2')]);
  if (on('hysteria2')) {
    if (text(values.hysteria2_port)) flags.push(['--hysteria2-port', text(values.hysteria2_port)]);
    flags.push(['--hysteria2-obfs', values.hysteria2_obfs === true ? 'on' : 'off']);
  }
  flags.push(['--amneziawg', flag('amneziawg')]);
  if (on('amneziawg')) {
    if (text(values.amneziawg_port)) flags.push(['--amneziawg-port', text(values.amneziawg_port)]);
    if (text(values.amneziawg_dns)) flags.push(['--amneziawg-dns', text(values.amneziawg_dns)]);
  }
  flags.push(['--warp', flag('warp')]);
  flags.push(['--ipv6', text(values.ipv6) || 'default']);
  return flags;
}

const flatten = (flags) => flags.flatMap(([flag, value]) => (value === null ? [flag] : [flag, value]));

/**
 * `profile add`: пустой email — `--random-acme-email`, пустая версия mihomo —
 * последняя (ядро спрашивает GitHub), пустые порты — случайные.
 */
export function profileAddArgv(values) {
  const flags = profileFlags(values);
  const email = text(values.acme_email);
  flags.push(email ? ['--acme-email', email] : ['--random-acme-email', null]);
  if (text(values.mihomo_version)) flags.push(['--mihomo-version', text(values.mihomo_version)]);
  return ['profile', 'add', '--name', text(values.name), ...flatten(flags)];
}

/**
 * `profile set` только с изменёнными флагами относительно `current`
 * (`profile show`); `null` — изменений нет. Очищенный порт не передаётся
 * (ядро оставляет прежний), очищенный email — `--random-acme-email`.
 */
export function profileSetArgv(name, values, current) {
  const before = profileValues(current);
  const previous = new Map(profileFlags(before));
  const changed = profileFlags(values).filter(([flag, value]) => !previous.has(flag) || previous.get(flag) !== value);
  const email = text(values.acme_email);
  if (email !== before.acme_email) changed.push(email ? ['--acme-email', email] : ['--random-acme-email', null]);
  const version = text(values.mihomo_version);
  if (version && version !== before.mihomo_version) changed.push(['--mihomo-version', version]);
  return changed.length === 0 ? null : ['profile', 'set', '--name', name, ...flatten(changed)];
}

export const profileDeleteArgv = (name) => ['profile', 'delete', '--name', name];
export const profileShowArgv = (name) => ['profile', 'show', '--name', name];

/**
 * Поля формы профиля (одна форма вместо вопросов мастера TUI): `values` —
 * текущие значения (`profileValues`) или пусто для нового; `editing` прячет имя.
 */
export function profileFields(values = {}, { editing = false, random = randomAcmeEmail } = {}) {
  const on = (current, protocol) => asList(current.protocols).includes(protocol);
  const fields = [];
  if (!editing) fields.push({ name: 'name', label: 'Имя профиля', type: 'text', required: 'Имя профиля не указано.', autofocus: true, value: values.name });
  fields.push(
    { name: 'reality', label: 'Режим Reality', type: 'radio', options: REALITY_OPTIONS, value: values.reality || 'self-steal' },
    { name: 'sni_domain', label: 'Домен-маскировка', type: 'text', placeholder: 'www.example.com', value: values.sni_domain,
      required: 'Домен не указан.', validate: domainError, when: (v) => v.reality === 'sni' },
    { name: 'site_source', label: 'Сайт-заглушка', type: 'select', options: SITE_SOURCES, value: values.site_source || 'random',
      when: (v) => v.reality !== 'sni' },
    { name: 'protocols', label: 'Протоколы', type: 'multi', required: true,
      options: PROTOCOLS.map(({ value, label }) => ({ value, label })), value: values.protocols || ['vless-tcp'] },
    { name: 'xhttp', label: 'Топология xHTTP', type: 'radio', options: XHTTP_TOPOLOGIES, value: values.xhttp || 'reality',
      when: (v) => on(v, 'xhttp') && v.reality !== 'sni' },
    { name: 'xhttp_port', label: 'Порт VLESS xHTTP', type: 'text', placeholder: 'пусто — случайный', value: values.xhttp_port,
      validate: portError, when: (v) => on(v, 'xhttp') && (v.reality === 'sni' || v.xhttp !== 'nginx') },
    { name: 'grpc_port', label: 'Порт VLESS gRPC', type: 'text', placeholder: 'пусто — случайный', value: values.grpc_port,
      validate: portError, when: (v) => on(v, 'grpc') },
    { name: 'hysteria2_port', label: 'Порт Hysteria2', type: 'text', placeholder: 'пусто — случайный', value: values.hysteria2_port,
      validate: portError, when: (v) => on(v, 'hysteria2') },
    { name: 'hysteria2_obfs', label: 'Hysteria2: обфускация (obfs)', type: 'checkbox', value: values.hysteria2_obfs === true,
      when: (v) => on(v, 'hysteria2') },
    { name: 'amneziawg_port', label: 'Порт AmneziaWG', type: 'text', placeholder: 'пусто — случайный', value: values.amneziawg_port,
      validate: portError, when: (v) => on(v, 'amneziawg') },
    { name: 'amneziawg_dns', label: 'DNS AmneziaWG', type: 'text', placeholder: '1.1.1.1, 1.0.0.1', value: values.amneziawg_dns,
      when: (v) => on(v, 'amneziawg') },
    { name: 'ipv6', label: 'IPv6', type: 'radio', options: IPV6_OPTIONS, value: values.ipv6 || 'default' },
    { name: 'acme_email', label: 'Email для ACME', type: 'text', placeholder: 'пусто — случайный адрес', value: values.acme_email,
      validate: emailError, action: { label: 'Случайный адрес', value: () => random() } },
    { name: 'mihomo_version', label: 'Версия mihomo', type: 'text', placeholder: 'пусто — последняя', value: values.mihomo_version,
      validate: versionError },
  );
  return fields;
}

// ─── Потоки ─────────────────────────────────────────────────────────────────

const replyName = (reply, fallback) => (reply.ok && reply.data && typeof reply.data.name === 'string' && reply.data.name ? reply.data.name : fallback);

/**
 * Добавление профиля одной формой; успех — `go(имя)` (экран открывает карточку,
 * пока смонтирован). Невыполненная команда (`retryable`) открывает форму снова
 * с введённым, включая имя.
 */
export async function addProfileFlow(ctx, go) {
  let previous = {};
  for (;;) {
    const values = await ctx.form({ title: 'Добавить профиль', fields: profileFields(previous), submit: 'Добавить', wide: true });
    if (values === null || values === undefined) return false;
    previous = values;
    const reply = await ctx.request(profileAddArgv(values), { operation: 'Добавление профиля' });
    if (reply.ok) { go(replyName(reply, values.name)); return true; }
    if (ctx.isFailure(reply)) ctx.failed();
    if (!retryable(reply)) return false;
  }
}

/**
 * «Изменить»: те же поля с текущими значениями → `profile set` только с
 * изменёнными флагами; невыполненная команда (`retryable`) открывает форму
 * снова с введённым.
 */
export async function editProfileFlow(ctx, profile) {
  const name = text(profile.name);
  let previous = profileValues(profile);
  for (;;) {
    const values = await ctx.form({
      title: `Профиль: ${name}`, fields: profileFields(previous, { editing: true }), wide: true,
    });
    if (values === null || values === undefined) return false;
    const argv = profileSetArgv(name, values, profile);
    if (argv === null) { ctx.notify('info', 'Изменений нет.'); return false; }
    const reply = await ctx.request(argv);
    if (reply.ok) return true;
    if (ctx.isFailure(reply)) ctx.failed();
    if (!retryable(reply)) return false;
    previous = values;
  }
}

/** Удаление по плану ядра; `in_use` (есть ноды) показывает текст ядра. `true` — профиль удалён. */
export async function deleteProfile(ctx, name) {
  const reply = await ctx.runConfirmed('Удаление профиля', 'Удалить профиль?', profileDeleteArgv(name));
  if (ctx.isFailure(reply)) ctx.failed();
  return reply.ok;
}

/** «Применить на нодах профиля» — `node apply --profile P`. */
export function applyProfile(ctx, name) {
  return applyFlow(ctx, applyProfileArgv(name));
}

/** Ноды профиля из `profile list|show`. */
export const profileNodes = (profile) => strings(profile && profile.nodes);
