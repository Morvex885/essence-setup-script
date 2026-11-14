// Последовательность Tab модального слоя без DOM: `items` — фокусируемые
// элементы слоя в порядке документа (видимые, без `disabled`), `active` —
// элемент с фокусом.

/**
 * Группа radio с именем (`name`, та же форма) — одна остановка Tab: браузер
 * переходит на её отмеченный вариант (без отмеченного — на крайний по
 * направлению) и пропускает остальные. Остальные элементы — по одному.
 */
function stopOf(item, items) {
  if (!item || item.type !== 'radio' || !item.name) return [item];
  return items.filter((other) => other.type === 'radio' && other.name === item.name && other.form === item.form);
}

const entry = (stop, backward) => stop.find((item) => item.checked) || (backward ? stop[stop.length - 1] : stop[0]);

/**
 * Края круга Tab: `atFirst`/`atLast` — `active` в первой/последней остановке
 * (любой вариант её radio-группы), `first`/`last` — куда переходит фокус при
 * переходе через край вперёд/назад. Пустой список — `first`/`last` равны `null`.
 */
export function tabEdges(items, active) {
  if (items.length === 0) return { atFirst: false, atLast: false, first: null, last: null };
  const firstStop = stopOf(items[0], items);
  const lastStop = stopOf(items[items.length - 1], items);
  return {
    atFirst: firstStop.includes(active),
    atLast: lastStop.includes(active),
    first: entry(firstStop, false),
    last: entry(lastStop, true),
  };
}
