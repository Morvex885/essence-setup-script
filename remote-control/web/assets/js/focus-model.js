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

/**
 * Остановки Tab в порядке документа: из radio-группы — только её отмеченный
 * вариант на его месте; без отмеченного — первый вариант (вперёд) или
 * последний (назад). Элементы между вариантами группы остаются остановками.
 */
function stops(items, backward) {
  return items.filter((item) => {
    const group = stopOf(item, items);
    if (group.length === 1) return true;
    const checked = group.find((other) => other.checked);
    if (checked) return item === checked;
    return item === (backward ? group[group.length - 1] : group[0]);
  });
}

/**
 * Края круга Tab: `atFirst`/`atLast` — `active` в первой/последней остановке
 * (любой вариант её radio-группы), `first`/`last` — куда переходит фокус при
 * переходе через край вперёд/назад. Пустой список — `first`/`last` равны `null`.
 */
export function tabEdges(items, active) {
  if (items.length === 0) return { atFirst: false, atLast: false, first: null, last: null };
  const forward = stops(items, false);
  const backward = stops(items, true);
  const first = forward[0];
  const last = backward[backward.length - 1];
  return {
    atFirst: stopOf(backward[0], items).includes(active),
    atLast: stopOf(forward[forward.length - 1], items).includes(active),
    first,
    last,
  };
}
