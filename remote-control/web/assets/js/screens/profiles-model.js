// Модель экрана «Профили нод» без DOM — паритет с мастером профиля TUI
// (`tui/src/nodes.rs::Profiles`): поля формы, argv `profile add|set|delete`,
// подписи списка и потоки поверх `ctx`. Значения флагов — грамматика ядра
// (`profile add|set`, `reality=self-steal|sni`, `xhttp=off|reality|nginx`,
// протоколы `on|off`, `ipv6=default|enabled|disabled`).
import { asList, strings } from '../format.js';
import { applyFlow, applyProfileArgv } from './apply-model.js';
import { retryable } from '../flows.js';

/**
 * Протоколы формы: значение поля `protocols` → подпись, сокращение списка и
 * объяснение для неспециалиста (`hint`, как `PROTOCOL_HINTS` мастера TUI).
 */
export const PROTOCOLS = [
  { value: 'vless-tcp', label: 'VLESS TCP', short: 'TCP', hint: 'основной протокол: быстрый и надёжный, оставьте включённым' },
  { value: 'xhttp', label: 'VLESS xHTTP', short: 'xHTTP', hint: 'выглядит как обычные HTTP-запросы' },
  { value: 'grpc', label: 'VLESS gRPC', short: 'gRPC', hint: 'выглядит как gRPC-трафик' },
  { value: 'hysteria2', label: 'Hysteria2', short: 'HY2', hint: 'быстрый протокол поверх UDP' },
  { value: 'amneziawg', label: 'AmneziaWG', short: 'AWG', hint: 'VPN на основе WireGuard с маскировкой' },
  { value: 'warp', label: 'WARP', short: 'WARP', hint: 'сайты видят адрес Cloudflare вместо адреса ноды' },
];

// Варианты выбора с объяснением в одно предложение (`hint`) — те же, что у мастера TUI.
export const REALITY_OPTIONS = [
  { value: 'self-steal', label: 'Self-Steal — свой домен',
    hint: 'Нода маскируется под собственный сайт-заглушку на вашем домене; нужен домен, направленный на IP ноды.' },
  { value: 'sni', label: 'SNI — чужой сайт',
    hint: 'Нода выдаёт себя за известный чужой сайт (например, www.microsoft.com); свой домен не нужен.' },
];
export const SITE_SOURCES = [
  { value: 'random', label: 'Случайный шаблон', hint: 'сайт выбирается случайно из всех наборов — подходит почти всегда' },
  { value: 'simple', label: 'Набор simple-web-templates', hint: 'простые сайты-визитки' },
  { value: 'sni', label: 'Набор sni-templates', hint: 'страницы в стиле онлайн-сервисов' },
  { value: 'nothing', label: 'Набор nothing-sni', hint: 'минималистичные страницы-заглушки' },
];
export const XHTTP_TOPOLOGIES = [
  { value: 'reality', label: 'Reality — отдельный порт',
    hint: 'xHTTP работает сам по себе на своём порту и маскируется под чужой сайт, как VLESS TCP. Проще и не зависит от вашего сайта.' },
  { value: 'nginx', label: 'Через ваш сайт (nginx, порт 443)',
    hint: 'xHTTP прячется внутри сайта-заглушки на 443 по секретному адресу: снаружи это обычные заходы на ваш сайт. Лучше проходит строгую фильтрацию, но нужен домен ноды.' },
];
export const IPV6_OPTIONS = [
  { value: 'default', label: 'Как в системе', hint: 'настройки IPv6 сервера не меняются' },
  { value: 'enabled', label: 'Включить', hint: 'нода работает и по IPv6, если провайдер выдал ей IPv6-адрес' },
  { value: 'disabled', label: 'Отключить', hint: 'IPv6 на сервере выключается — если он работает плохо или мешает сайтам верно определять страну' },
];
export const SITE_EXPLAINED = 'Сайт-заглушка — страница, которую увидит обычный посетитель домена ноды: сервер выглядит как обычный сайт.';
export const OBFS_EXPLAINED = 'Скрывает, что это Hysteria2: помогает, если провайдер режет такой трафик; все клиенты должны поддерживать obfs.';
export const MIHOMO_EXPLAINED = 'mihomo — программа-прокси на сервере; обычно выбирайте последнюю версию.';

export const PORT_INVALID = 'Порт должен быть числом от 1 до 65535.';
export const DOMAIN_INVALID = 'Домен — части из латинских букв, цифр и дефисов через точку, например node.example.com.';
export const EMAIL_INVALID = 'Email в виде имя@домен, например admin@example.com.';
export const VERSION_INVALID = 'Версия в виде vX.Y.Z не ниже v1.19.18, например v1.19.18.';
/** Что допустимо в имени (`validation::name_valid` ядра: без ограничения длины). */
export const NAME_RULE = 'Только латинские буквы, цифры и символы . _ - без пробелов. Например: edge-full.';
export const WARP_LICENSE_INVALID = 'Ключ WARP+ состоит из латинских букв, цифр и дефисов (до 64 символов).';

const DOMAIN_RE = /^(?=.{1,253}$)[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$/;
const EMAIL_RE = /^[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$/;
/** Наименьшая версия mihomo (`model::MIHOMO_MIN_VERSION` ядра). */
const MIHOMO_MIN = [1, 19, 18];

const text = (value) => (typeof value === 'string' ? value.trim() : value === null || value === undefined ? '' : String(value));

/** `validation::parse_ssh_port` ядра: 1–5 цифр, 1…65535 (`080` допустим). Пусто — допустимо (умолчание вопроса). Текст ошибки или `null`. */
export function portError(value) {
  const port = text(value);
  if (port === '') return null;
  return /^[0-9]{1,5}$/.test(port) && Number(port) >= 1 && Number(port) <= 65535 ? null : PORT_INVALID;
}

/** Домен (`validation::domain_valid` ядра): метки, минимум одна точка. */
export function domainValid(value) {
  return DOMAIN_RE.test(text(value));
}

export const domainError = (value) => (text(value) === '' || domainValid(value) ? null : DOMAIN_INVALID);
/** Вставленный адрес (`https://host/…`) → его хост, если это верный домен; иначе `null`. */
export function domainSuggestion(value) {
  const host = text(value).split('://').pop().split(/[/:]/)[0].toLowerCase();
  return domainValid(host) && host !== text(value) ? host : null;
}
export const emailError = (value) => (text(value) === '' || EMAIL_RE.test(text(value)) ? null : EMAIL_INVALID);

/** `vX.Y.Z` не ниже v1.19.18 (правило ядра). */
export function versionValid(value) {
  const match = /^v([0-9]{1,9})\.([0-9]{1,9})\.([0-9]{1,9})$/.exec(text(value));
  if (!match) return false;
  const parts = match.slice(1).map(Number);
  for (let i = 0; i < 3; i += 1) if (parts[i] !== MIHOMO_MIN[i]) return parts[i] > MIHOMO_MIN[i];
  return true;
}
export const versionError = (value) => (text(value) === '' || versionValid(value) ? null : VERSION_INVALID);
/** `1.19.20` → `v1.19.20`, если так версия верна; иначе `null`. */
export const versionSuggestion = (value) => (!text(value).startsWith('v') && versionValid(`v${text(value)}`) ? `v${text(value)}` : null);

/** Имя объекта (`validation::name_valid` ядра). */
export function nameValid(value) {
  return typeof value === 'string' && /^[A-Za-z0-9._-]+$/.test(value) && /[^.]/.test(value);
}

/** `validation::TRANSLIT` ядра (общие векторы: `core/tests/validation_vectors.json`). */
const TRANSLIT = {
  а: 'a', б: 'b', в: 'v', г: 'g', д: 'd', е: 'e', ё: 'e', ж: 'zh', з: 'z', и: 'i', й: 'y', к: 'k', л: 'l', м: 'm', н: 'n',
  о: 'o', п: 'p', р: 'r', с: 's', т: 't', у: 'u', ф: 'f', х: 'kh', ц: 'ts', ч: 'ch', ш: 'sh', щ: 'shch', ъ: '', ы: 'y',
  ь: '', э: 'e', ю: 'yu', я: 'ya',
  і: 'i', ї: 'yi', є: 'ye', ґ: 'g', ў: 'u',
  à: 'a', á: 'a', â: 'a', ã: 'a', ä: 'a', å: 'a', ā: 'a', ą: 'a', æ: 'ae', ç: 'c', ć: 'c', č: 'c', ď: 'd', đ: 'd', ð: 'd',
  è: 'e', é: 'e', ê: 'e', ë: 'e', ē: 'e', ę: 'e', ě: 'e', ğ: 'g', ì: 'i', í: 'i', î: 'i', ï: 'i', ī: 'i', ı: 'i', ł: 'l',
  ñ: 'n', ń: 'n', ň: 'n', ò: 'o', ó: 'o', ô: 'o', õ: 'o', ö: 'o', ø: 'o', ō: 'o', ő: 'o', œ: 'oe', ř: 'r',
  ś: 's', š: 's', ş: 's', ș: 's', ß: 'ss', ť: 't', ţ: 't', ț: 't', þ: 'th', ù: 'u', ú: 'u', û: 'u', ü: 'u', ū: 'u',
  ů: 'u', ű: 'u', ý: 'y', ÿ: 'y', ź: 'z', ż: 'z', ž: 'z',
};

/**
 * Верное имя, близкое к введённому (`validation::suggest_name` ядра): буквы
 * строчные и транслитерируются (`TRANSLIT`), комбинируемые знаки ударения
 * отбрасываются («İ» → «i»), прочие символы подряд — один `-`, разделители по
 * краям убираются («VLESS TCP HY2» → «vless-tcp-hy2»), затем имя делается
 * уникальным среди `taken` (`-2`, `-3`, …). `null` — ничего пригодного не осталось.
 */
export function suggestName(value, taken = []) {
  let out = '';
  for (const c of String(value ?? '').toLowerCase()) {
    if (/[a-z0-9._]/.test(c)) out += c;
    else if (c >= '\u0300' && c <= '\u036f') continue;
    else if (Object.hasOwn(TRANSLIT, c)) out += TRANSLIT[c];
    else if (!out.endsWith('-')) out += '-';
  }
  const base = out.replace(/^[-._]+|[-._]+$/g, '');
  if (!nameValid(base)) return null;
  const used = new Set(asList(taken));
  if (!used.has(base)) return base;
  for (let n = 2; ; n += 1) if (!used.has(`${base}-${n}`)) return `${base}-${n}`;
}

/** Живая проверка имени: пусто — без ошибки (обязательность — `required`), иначе `NAME_RULE`. */
export const nameError = (value) => (value === '' || value === undefined || value === null || nameValid(value) ? null : NAME_RULE);

/** Поле имени с живой проверкой и предложением верного имени, которого нет среди `taken`. */
export function nameField({ name = 'name', label, value, required = true, placeholder = 'edge-full', taken = [] } = {}) {
  return { name, label, type: 'text', value, placeholder, required, autofocus: true, live: true, validate: nameError,
    suggest: (typed) => suggestName(typed, taken), hint: 'латинские буквы, цифры и . _ - без пробелов' };
}
/** Ключ WARP+ (`validation::warp_license_valid` ядра): латиница, цифры, дефисы, до 64 символов; без обрезки — ядру уходит как есть. */
export const warpLicenseError = (value) => {
  const key = typeof value === 'string' ? value : '';
  return key === '' || /^[A-Za-z0-9-]{1,64}$/.test(key) ? null : WARP_LICENSE_INVALID;
};

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

// ─── Версия mihomo ──────────────────────────────────────────────────────────

export const MIHOMO_VERSIONS_ARGV = ['profile', 'mihomo-versions'];
/** Значение выбора «Ввести вручную». */
export const MANUAL_VERSION = 'manual';

/**
 * Варианты выбора версии из ответа `profile mihomo-versions` (`{ latest,
 * versions }`): «Последняя (vX)», остальные версии, текущая (`current`,
 * если её нет в списке — сразу после последней, отмечена «(сейчас)»),
 * «Ввести вручную». Пустой массив — списка нет (только ручной ввод).
 */
export function versionOptions(listing, current = '') {
  const latest = listing && typeof listing.latest === 'string' ? listing.latest : '';
  if (!latest) return [];
  const values = [latest, ...strings(listing.versions).filter((v) => v !== latest)];
  const now = text(current);
  if (now && !values.includes(now)) values.splice(1, 0, now);
  const options = values.map((value, index) => {
    const label = index === 0 ? `Последняя (${value})` : value;
    return { value, label: value === now ? `${label} (сейчас)` : label };
  });
  return [...options, { value: MANUAL_VERSION, label: 'Ввести вручную' }];
}

/** Выбранная версия: значение списка или ручной ввод (`''` — последняя по ядру). */
export function chosenVersion(values) {
  const choice = values && values.mihomo_choice;
  return choice && choice !== MANUAL_VERSION ? choice : text(values && values.mihomo_version);
}

/** Список версий для формы: данные `profile mihomo-versions` или `null` (сбой — ручной ввод, причина в журнале). */
export async function loadVersions(ctx) {
  const reply = await ctx.request(MIHOMO_VERSIONS_ARGV, { quiet: true });
  return reply.ok ? reply.data : null;
}

/**
 * Поля версии: выбор из списка (по умолчанию — текущая при правке, иначе
 * последняя) и ручной ввод с подсказкой формата, видимый при «Ввести
 * вручную» или без списка.
 */
export function versionFields(listing, current = '') {
  const options = versionOptions(listing, current);
  const manual = {
    name: 'mihomo_version', label: options.length ? 'Версия mihomo вручную' : 'Версия mihomo', type: 'text',
    placeholder: current ? text(current) : 'пусто — последняя', value: options.length ? '' : text(current),
    hint: 'в виде vX.Y.Z, например v1.19.18 (не ниже)', live: true, validate: versionError, suggest: versionSuggestion,
  };
  if (options.length === 0) return [manual];
  const value = text(current) || options[0].value;
  return [
    { name: 'mihomo_choice', label: 'Версия mihomo', type: 'select', options, value, hint: MIHOMO_EXPLAINED },
    { ...manual, required: 'Укажите версию.', when: (v) => v.mihomo_choice === MANUAL_VERSION },
  ];
}

/**
 * `profile add`: пустой email — `--random-acme-email`, пустая версия mihomo —
 * последняя (ядро спрашивает GitHub), пустые порты — случайные.
 */
export function profileAddArgv(values) {
  const flags = profileFlags(values);
  const email = text(values.acme_email);
  flags.push(email ? ['--acme-email', email] : ['--random-acme-email', null]);
  const version = chosenVersion(values);
  if (version) flags.push(['--mihomo-version', version]);
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
  const version = chosenVersion(values);
  if (version && version !== before.mihomo_version) changed.push(['--mihomo-version', version]);
  return changed.length === 0 ? null : ['profile', 'set', '--name', name, ...flatten(changed)];
}

export const profileDeleteArgv = (name) => ['profile', 'delete', '--name', name];
export const profileShowArgv = (name) => ['profile', 'show', '--name', name];

/**
 * Поля формы профиля (одна форма вместо вопросов мастера TUI): `values` —
 * текущие значения (`profileValues`) или пусто для нового; `editing` прячет
 * имя; `versions` — ответ `profile mihomo-versions` (`null` — ручной ввод).
 * Каждый технический выбор объясняет варианты (`hint`).
 */
export function profileFields(values = {}, { editing = false, random = randomAcmeEmail, versions = null, taken = [] } = {}) {
  const on = (current, protocol) => asList(current.protocols).includes(protocol);
  const fields = [];
  if (!editing) fields.push({ ...nameField({ label: 'Имя профиля', value: values.name, taken }), required: 'Имя профиля не указано.' });
  fields.push(
    { name: 'reality', label: 'Режим Reality', type: 'radio', options: REALITY_OPTIONS, value: values.reality || 'self-steal',
      hint: 'Как нода прячет VPN-трафик от провайдера.' },
    { name: 'sni_domain', label: 'Чужой сайт для маскировки', type: 'text', placeholder: 'www.microsoft.com', value: values.sni_domain,
      required: 'Домен не указан.', live: true, validate: domainError, suggest: domainSuggestion, when: (v) => v.reality === 'sni' },
    { name: 'site_source', label: 'Сайт-заглушка', type: 'radio', options: SITE_SOURCES, value: values.site_source || 'random',
      hint: SITE_EXPLAINED, when: (v) => v.reality !== 'sni' },
    { name: 'protocols', label: 'Протоколы', type: 'multi', required: true,
      options: PROTOCOLS.map(({ value, label, hint }) => ({ value, label, hint: `— ${hint}` })), value: values.protocols || ['vless-tcp'] },
    { name: 'xhttp', label: 'Топология xHTTP', type: 'radio', options: XHTTP_TOPOLOGIES, value: values.xhttp || 'reality',
      hint: 'Как подключение xHTTP будет выглядеть для провайдера.', when: (v) => on(v, 'xhttp') && v.reality !== 'sni' },
    { name: 'xhttp_port', label: 'Порт VLESS xHTTP', type: 'text', placeholder: 'пусто — случайный', value: values.xhttp_port,
      live: true, validate: portError, when: (v) => on(v, 'xhttp') && (v.reality === 'sni' || v.xhttp !== 'nginx') },
    { name: 'grpc_port', label: 'Порт VLESS gRPC', type: 'text', placeholder: 'пусто — случайный', value: values.grpc_port,
      live: true, validate: portError, when: (v) => on(v, 'grpc') },
    { name: 'hysteria2_port', label: 'Порт Hysteria2', type: 'text', placeholder: 'пусто — случайный', value: values.hysteria2_port,
      live: true, validate: portError, when: (v) => on(v, 'hysteria2') },
    { name: 'hysteria2_obfs', label: 'Hysteria2: обфускация (obfs)', type: 'checkbox', value: values.hysteria2_obfs === true,
      hint: OBFS_EXPLAINED, when: (v) => on(v, 'hysteria2') },
    { name: 'amneziawg_port', label: 'Порт AmneziaWG', type: 'text', placeholder: 'пусто — случайный', value: values.amneziawg_port,
      live: true, validate: portError, when: (v) => on(v, 'amneziawg') },
    { name: 'amneziawg_dns', label: 'DNS AmneziaWG', type: 'text', placeholder: '1.1.1.1, 1.0.0.1', value: values.amneziawg_dns,
      when: (v) => on(v, 'amneziawg') },
    { name: 'ipv6', label: 'IPv6', type: 'radio', options: IPV6_OPTIONS, value: values.ipv6 || 'default' },
    { name: 'acme_email', label: 'Email для Let\'s Encrypt', type: 'text', placeholder: 'пусто — случайный адрес', value: values.acme_email,
      hint: 'на него приходят уведомления о сертификатах', live: true, validate: emailError,
      action: { label: 'Случайный адрес', value: () => random() } },
    ...versionFields(versions, editing ? values.mihomo_version : ''),
  );
  return fields;
}

// ─── Потоки ─────────────────────────────────────────────────────────────────

const replyName = (reply, fallback) => (reply.ok && reply.data && typeof reply.data.name === 'string' && reply.data.name ? reply.data.name : fallback);

/**
 * Добавление профиля одной формой (версии mihomo — списком из
 * `profile mihomo-versions`, без него — ручной ввод); успех — `go(имя)`
 * (экран открывает карточку, пока смонтирован). Невыполненная команда
 * (`retryable`) открывает форму снова с введённым, включая имя.
 */
export async function addProfileFlow(ctx, go, taken = []) {
  const versions = await loadVersions(ctx);
  let previous = {};
  for (;;) {
    const values = await ctx.form({ title: 'Добавить профиль', fields: profileFields(previous, { versions, taken }), submit: 'Добавить', wide: true });
    if (values === null || values === undefined) return false;
    previous = values;
    const reply = await ctx.request(profileAddArgv(values), { operation: 'Добавление профиля' });
    if (reply.ok) { go(replyName(reply, values.name)); return true; }
    if (ctx.isFailure(reply)) ctx.failed();
    if (!retryable(reply)) return false;
  }
}

/**
 * «Изменить»: те же поля с текущими значениями (текущая версия mihomo выбрана)
 * → `profile set` только с изменёнными флагами; невыполненная команда
 * (`retryable`) открывает форму снова с введённым. Сбой после локальной записи
 * (например, checkpoint) мог сохранить часть правки: перед повтором профиль
 * перечитывается (`profile show`), и следующая команда считается от сохранённого.
 */
export async function editProfileFlow(ctx, profile) {
  const name = text(profile.name);
  const versions = await loadVersions(ctx);
  let current = profile;
  let previous = profileValues(profile);
  for (;;) {
    const values = await ctx.form({
      title: `Профиль: ${name}`, fields: profileFields(previous, { editing: true, versions }), wide: true,
    });
    if (values === null || values === undefined) return false;
    const argv = profileSetArgv(name, values, current);
    if (argv === null) { ctx.notify('info', 'Изменений нет.'); return false; }
    const reply = await ctx.request(argv);
    if (reply.ok) return true;
    if (ctx.isFailure(reply)) ctx.failed();
    if (!retryable(reply)) return false;
    const shown = await ctx.request(profileShowArgv(name));
    if (!shown.ok) return false;
    current = shown.data || {};
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

// ─── Ключ WARP+ ─────────────────────────────────────────────────────────────

/** Ключ WARP+ — секретом `password`, в argv его нет. */
export const warpLicenseArgv = (name) => ['profile', 'warp-license', '--name', name];
export const warpLicenseClearArgv = (name) => ['profile', 'warp-license', '--name', name, '--clear'];

/** «Ключ WARP+»: скрытый ввод → `profile warp-license` с секретом `password`. `true` — сохранён. */
export async function warpLicenseFlow(ctx, name) {
  const values = await ctx.form({
    title: `Ключ WARP+: ${name}`,
    fields: [{ name: 'password', label: 'Ключ WARP+', type: 'secret', required: true, validate: warpLicenseError, autofocus: true }],
    submit: 'Сохранить',
  });
  if (values === null || values === undefined) return false;
  const reply = await ctx.request(warpLicenseArgv(name), { secrets: { password: values.password } });
  if (ctx.isFailure(reply)) ctx.failed();
  return reply.ok;
}

/** «Убрать ключ WARP+» → `profile warp-license --clear`. `true` — убран. */
export async function clearWarpLicense(ctx, name) {
  const reply = await ctx.request(warpLicenseClearArgv(name));
  if (ctx.isFailure(reply)) ctx.failed();
  return reply.ok;
}

/** Ноды профиля из `profile list|show`. */
export const profileNodes = (profile) => strings(profile && profile.nodes);
