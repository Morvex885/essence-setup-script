// Тесты focus-model.js: края круга Tab модального слоя с radio-группами.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { tabEdges } from '../assets/js/focus-model.js';

const form = {};
const radio = (name, value, checked = false) => ({ type: 'radio', name, value, checked, form });
const button = (label) => ({ type: 'button', label });

test('без radio: края — первый и последний элемент', () => {
  const [a, b, c] = [button('a'), button('b'), button('c')];
  assert.deepEqual(tabEdges([a, b, c], a), { atFirst: true, atLast: false, first: a, last: c });
  assert.deepEqual(tabEdges([a, b, c], c), { atFirst: false, atLast: true, first: a, last: c });
  assert.deepEqual(tabEdges([], null), { atFirst: false, atLast: false, first: null, last: null });
});

test('форма начинается radio-группой с отмеченным не первым вариантом: Shift+Tab с него — на последний элемент', () => {
  const [one, two, three] = [radio('auth', 'key'), radio('auth', 'password', true), radio('auth', 'other')];
  const submit = button('submit');
  const edges = tabEdges([one, two, three, submit], two);
  assert.equal(edges.atFirst, true, 'отмеченный вариант первой группы — первая остановка');
  assert.equal(edges.first, two, 'вперёд через край — на отмеченный вариант');
  assert.equal(edges.last, submit);
});

test('radio-группа в конце: последняя остановка; без отмеченного — крайний по направлению', () => {
  const name = button('name');
  const [x, y] = [radio('mode', 'x'), radio('mode', 'y')];
  const edges = tabEdges([name, x, y], x);
  assert.deepEqual([edges.atLast, edges.first, edges.last], [true, name, y]);
  const [p, q] = [radio('first', 'p'), radio('first', 'q')];
  assert.equal(tabEdges([p, q, name], name).first, p);
  // Группы с одним именем в разных формах — разные остановки.
  const other = { ...radio('mode', 'z'), form: {} };
  assert.equal(tabEdges([other, name, x, y], x).atFirst, false);
});

test('элемент между вариантами группы — своя остановка: края по месту отмеченного варианта', () => {
  const [r1, r2] = [radio('auth', 'key'), radio('auth', 'password', true)];
  const [middle, submit] = [button('middle'), button('submit')];
  const items = [r1, middle, r2, submit];
  // Остановки: middle, r2, submit — первая middle, r1 пропускается.
  assert.deepEqual(tabEdges(items, middle), { atFirst: true, atLast: false, first: middle, last: submit });
  const fromRadio = tabEdges(items, r2);
  assert.deepEqual([fromRadio.atFirst, fromRadio.atLast], [false, false], 'с r2 Shift+Tab идёт на middle, а не через край');
  assert.equal(tabEdges(items, submit).atLast, true);
});
