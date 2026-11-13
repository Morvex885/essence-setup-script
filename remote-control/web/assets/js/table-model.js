// Чистая логика таблиц панели (`ui.js::DataTable`): текст ячейки, поиск и
// отметки строк.
import { asList } from './format.js';

/** Текст значения строки: массив — через запятую, `null`/`undefined` — пусто. */
export function cellText(row, key) {
  const value = row ? row[key] : undefined;
  if (value === null || value === undefined) return '';
  if (Array.isArray(value)) return value.map((item) => (item === null || item === undefined ? '' : String(item))).join(', ');
  if (typeof value === 'object') return JSON.stringify(value);
  return String(value);
}

/** Строки, где хотя бы одна колонка `search: true` содержит запрос (без учёта регистра). */
export function filterRows(rows, columns, query) {
  const list = asList(rows);
  const needle = String(query || '').trim().toLowerCase();
  if (needle === '') return list;
  const searchable = (columns || []).filter((column) => column.search);
  return list.filter((row) => searchable.some((column) => cellText(row, column.key).toLowerCase().includes(needle)));
}

/** Все видимые строки отмечены (`visible` — ключи строк после поиска). */
export function allSelected(selected, visible) {
  return visible.length > 0 && visible.every((key) => selected.includes(key));
}

/**
 * «Выбрать все» действует только на видимые строки: снимает их отметки, если
 * все видимые отмечены, иначе добавляет; отметки скрытых поиском строк не меняются.
 */
export function toggleVisible(selected, visible) {
  if (allSelected(selected, visible)) return selected.filter((key) => !visible.includes(key));
  return [...selected, ...visible.filter((key) => !selected.includes(key))];
}
