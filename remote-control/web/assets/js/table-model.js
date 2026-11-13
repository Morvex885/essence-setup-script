// Чистая логика таблиц панели (`ui.js::DataTable`): текст ячейки и поиск.

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
  const list = Array.isArray(rows) ? rows : [];
  const needle = String(query || '').trim().toLowerCase();
  if (needle === '') return list;
  const searchable = (columns || []).filter((column) => column.search);
  return list.filter((row) => searchable.some((column) => cellText(row, column.key).toLowerCase().includes(needle)));
}
