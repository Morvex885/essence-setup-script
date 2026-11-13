// Маршрутизация по `location.hash`: `#/раздел/параметр/вкладка`. Чистые
// функции разбора и подписки: `document`/`window` не трогаются на верхнем
// уровне, объект окна передаётся в `start` (тесты подставляют заглушку).

function decode(part) {
  try { return decodeURIComponent(part); } catch { return part; }
}

/** Разобрать фрагмент в `{ name, param, tab }`; пустой — сводка, лишние сегменты отбрасываются. */
export function parse(hash) {
  const clean = String(hash || '').replace(/^#/, '').replace(/^\/+/, '');
  if (clean === '') return { name: 'summary', param: null, tab: null };
  const [name, param = '', tab = ''] = clean.split('/').map(decode);
  return { name, param: param === '' ? null : param, tab: param === '' || tab === '' ? null : tab };
}

const present = (value) => value !== null && value !== undefined && value !== '';

/** Собрать фрагмент маршрута; вкладка — только при параметре. */
export function format(name, param = null, tab = null) {
  let hash = `#/${encodeURIComponent(name || '')}`;
  if (present(param)) {
    hash += `/${encodeURIComponent(param)}`;
    if (present(tab)) hash += `/${encodeURIComponent(tab)}`;
  }
  return hash;
}

/**
 * Подписка на смену маршрута; вызывает `handler(route)` сразу и при каждом
 * изменении хеша. Возвращает функцию отписки.
 */
export function start(win, handler) {
  const changed = () => handler(parse(win.location.hash));
  changed();
  win.addEventListener('hashchange', changed);
  return () => win.removeEventListener('hashchange', changed);
}

/** Перейти на маршрут (меняет `location.hash`). */
export function navigate(win, name, param = null, tab = null) {
  win.location.hash = format(name, param, tab);
}

/** Извлечь и стереть `#ticket=…` из адреса (`history.replaceState`). */
export function consumeTicket(win) {
  const hash = String(win.location.hash || '');
  const match = hash.match(/^#ticket=([0-9a-fA-F]+)$/);
  if (!match) return null;
  win.history.replaceState(null, '', win.location.pathname + win.location.search);
  return match[1];
}
