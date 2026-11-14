// Тесты form-model.js: начальные значения, `when`, обязательность, проверка, итог.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { initialValues, visibleFields, validate, result, refill, REQUIRED, REQUIRED_MULTI } from '../assets/js/form-model.js';

const fields = [
  { name: 'name', label: 'Имя', type: 'text', required: true },
  { name: 'auth', label: 'Вход', type: 'radio', value: 'key', options: [{ value: 'key', label: 'Ключ' }, { value: 'password', label: 'Пароль' }] },
  { name: 'password', label: 'Пароль', type: 'secret', required: 'Пароль не может быть пустым.', when: (values) => values.auth === 'password' },
  { name: 'groups', label: 'Группы', type: 'multi', required: true, options: [{ value: 'a', label: 'a' }, { value: 'b', label: 'b' }] },
  { name: 'group', label: 'Группа', type: 'select', options: [{ value: 'x', label: 'x', disabled: true }, { value: 'y', label: 'y' }] },
  { name: 'keep', label: 'Сохранить', type: 'checkbox' },
];

test('initialValues: значения полей и пустые значения по типу', () => {
  const values = initialValues(fields);
  assert.deepEqual(values, { name: '', auth: 'key', password: '', groups: [], group: 'y', keep: false });
  const preset = [{ name: 'm', type: 'multi', value: ['a'] }];
  const copy = initialValues(preset);
  copy.m.push('b');
  assert.deepEqual(preset[0].value, ['a'], 'исходный массив не меняется');
});

test('when: скрытые поля не показываются, не проверяются и не возвращаются', () => {
  const values = { ...initialValues(fields), name: 'n', groups: ['a'] };
  assert.deepEqual(visibleFields(fields, values).map((field) => field.name), ['name', 'auth', 'groups', 'group', 'keep']);
  assert.deepEqual(validate(fields, values), {});
  assert.ok(!('password' in result(fields, values)));
  const password = { ...values, auth: 'password' };
  assert.deepEqual(validate(fields, password), { password: 'Пароль не может быть пустым.' });
  assert.equal(result(fields, { ...password, password: 'pw' }).password, 'pw');
});

test('required: общий текст, свой текст и мультивыбор', () => {
  const errors = validate(fields, initialValues(fields));
  assert.deepEqual(errors, { name: REQUIRED, groups: REQUIRED_MULTI });
});

test('validate: своя проверка получает значение и все значения', () => {
  const pair = [
    { name: 'password', type: 'secret', required: true },
    { name: 'repeat', type: 'secret', validate: (value, values) => (value === values.password ? null : 'differ') },
  ];
  assert.deepEqual(validate(pair, { password: 'a', repeat: 'b' }), { repeat: 'differ' });
  assert.deepEqual(validate(pair, { password: 'a', repeat: 'a' }), {});
  // Пустое обязательное поле — только «обязательно», без своей проверки.
  assert.deepEqual(validate([{ name: 'x', type: 'text', required: true, validate: () => 'bad' }], { x: '' }), { x: REQUIRED });
});

test('result: копия значений видимых полей', () => {
  const values = { ...initialValues(fields), name: 'n', groups: ['a', 'b'], keep: true };
  const out = result(fields, values);
  assert.deepEqual(out, { name: 'n', auth: 'key', groups: ['a', 'b'], group: 'y', keep: true });
  out.groups.push('c');
  assert.deepEqual(values.groups, ['a', 'b']);
});

test('initialValues: select не из доступных вариантов — первый доступный, секрет — всегда пусто', () => {
  const options = [{ value: 'x', label: 'x', disabled: true }, { value: 'y', label: 'y' }, { value: 'z', label: 'z' }];
  assert.deepEqual(initialValues([
    { name: 'gone', type: 'select', value: 'missing', options },
    { name: 'off', type: 'select', value: 'x', options },
    { name: 'kept', type: 'select', value: 'z', options },
    { name: 'secret', type: 'secret', value: 'leaked' },
  ]), { gone: 'y', off: 'y', kept: 'z', secret: '' });
});

test('refill: форма после сбоя — с прежним вводом, секреты пустые, без черновика — те же поля', () => {
  const form = [
    { name: 'name', type: 'text', value: 'a' },
    { name: 'nodes', type: 'multi', value: ['x'] },
    { name: 'password', type: 'secret' },
    { name: 'mode', type: 'radio', value: 'own' },
  ];
  assert.equal(refill(form, null), form);
  const again = refill(form, { name: 'b', nodes: ['y', 'z'], password: 'pw' });
  assert.deepEqual(again.map((field) => field.value), ['b', ['y', 'z'], undefined, 'own']);
  assert.deepEqual(initialValues(again), { name: 'b', nodes: ['y', 'z'], password: '', mode: 'own' });
  assert.equal(form[0].value, 'a', 'исходные поля не меняются');
});
