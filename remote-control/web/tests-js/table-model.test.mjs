// Тесты table-model.js: текст ячейки, поиск по колонкам `search: true` и отметки строк.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { cellText, filterRows, allSelected, toggleVisible } from '../assets/js/table-model.js';

const columns = [
  { key: 'name', label: 'Название', search: true },
  { key: 'tags', label: 'Теги', search: true },
  { key: 'secret', label: 'Скрыто' },
];
const rows = [
  { name: 'VPS-Alpha', tags: ['de', 'fast'], secret: 'zzz' },
  { name: 'beta', tags: [], secret: 'alpha' },
  { name: 'gamma', tags: null },
];

test('cellText: массивы через запятую, пустые значения — пусто', () => {
  assert.equal(cellText(rows[0], 'tags'), 'de, fast');
  assert.equal(cellText(rows[2], 'tags'), '');
  assert.equal(cellText(rows[2], 'missing'), '');
  assert.equal(cellText({ port: 22 }, 'port'), '22');
});

test('filterRows: без учёта регистра и только по колонкам поиска', () => {
  assert.deepEqual(filterRows(rows, columns, 'alpha').map((row) => row.name), ['VPS-Alpha']);
  assert.deepEqual(filterRows(rows, columns, 'FAST').map((row) => row.name), ['VPS-Alpha']);
  assert.deepEqual(filterRows(rows, columns, 'a').map((row) => row.name), ['VPS-Alpha', 'beta', 'gamma']);
  assert.deepEqual(filterRows(rows, columns, 'zzz'), []);
  assert.equal(filterRows(rows, columns, '  ').length, 3);
  assert.equal(filterRows(rows, columns, ''), rows);
  assert.deepEqual(filterRows(null, columns, 'x'), []);
});

test('«Выбрать все» действует только на видимые строки', () => {
  assert.equal(allSelected(['a'], []), false);
  assert.equal(allSelected(['a', 'b', 'x'], ['a', 'b']), true);
  // Поиск показывает a и b: отметка x (скрыта) остаётся, видимые добавляются.
  assert.deepEqual(toggleVisible(['x'], ['a', 'b']), ['x', 'a', 'b']);
  assert.deepEqual(toggleVisible(['x', 'a'], ['a', 'b']), ['x', 'a', 'b']);
  // Все видимые отмечены — снимаются только они.
  assert.deepEqual(toggleVisible(['x', 'a', 'b'], ['a', 'b']), ['x']);
});
