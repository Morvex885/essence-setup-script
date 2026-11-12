// Маршрутизация по `location.hash`. Чистые функции разбора и подписки:
// `document`/`window` не трогаются на верхнем уровне, объект окна передаётся
// в `start` (тесты подставляют заглушку).

/** Разобрать фрагмент в `{ name, param }`; пустой или неизвестный — сводка. */
export function parse(hash) {
  const clean = String(hash || '').replace(/^#/, '').replace(/^\/+/, '');
  if (clean === '') return { name: 'summary', param: null };
  const [name, ...rest] = clean.split('/');
  let param = null;
  if (rest.length > 0) {
    const raw = rest.join('/');
    try { param = decodeURIComponent(raw); } catch { param = raw; }
  }
  return { name, param };
}

/** Собрать фрагмент маршрута. */
export function format(name, param = null) {
  return `#/${name}${param !== null && param !== '' ? `/${encodeURIComponent(param)}` : ''}`;
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
export function navigate(win, name, param = null) {
  win.location.hash = format(name, param);
}

/** Извлечь и стереть `#ticket=…` из адреса (`history.replaceState`). */
export function consumeTicket(win) {
  const hash = String(win.location.hash || '');
  const match = hash.match(/^#ticket=([0-9a-fA-F]+)$/);
  if (!match) return null;
  win.history.replaceState(null, '', win.location.pathname + win.location.search);
  return match[1];
}
