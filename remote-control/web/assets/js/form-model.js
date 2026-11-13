// Чистая логика форм `ctx.form` (`dialogs.js`): начальные значения, видимые
// поля, проверка и итог. Поле: `{ name, label, type, value?, options?,
// required?, validate?, when? }`; `type` — `text|secret|select|radio|multi|
// checkbox|textarea`.
import { asList } from './format.js';

export const REQUIRED = 'Заполните поле.';
export const REQUIRED_MULTI = 'Выберите хотя бы один вариант.';

/** Пустое значение по типу поля. */
function blank(field) {
  if (field.type === 'multi') return [];
  if (field.type === 'checkbox') return false;
  if (field.type === 'select') {
    const first = asList(field.options).find((option) => !option.disabled);
    return first ? first.value : '';
  }
  return '';
}

/** `value` поля `select` есть среди доступных вариантов. */
function offered(field) {
  return asList(field.options).some((option) => !option.disabled && option.value === field.value);
}

/**
 * Значения формы: `value` поля или пустое значение типа. Секретные поля
 * всегда начинаются пустыми; `select` со значением не из доступных вариантов
 * начинается с первого доступного (то, что видно в списке, и уходит в итог).
 */
export function initialValues(fields) {
  const values = {};
  for (const field of asList(fields)) {
    if (field.value === undefined || field.value === null || field.type === 'secret') values[field.name] = blank(field);
    else if (field.type === 'select' && !offered(field)) values[field.name] = blank(field);
    else if (field.type === 'multi') values[field.name] = [...asList(field.value)];
    else values[field.name] = field.value;
  }
  return values;
}

/** Поля, видимые при текущих значениях (`when(values) === false` — скрыто). */
export function visibleFields(fields, values) {
  return asList(fields).filter((field) => typeof field.when !== 'function' || field.when(values) !== false);
}

function empty(field, value) {
  if (field.type === 'multi') return asList(value).length === 0;
  if (field.type === 'checkbox') return value !== true;
  return value === undefined || value === null || value === '';
}

/** Ошибки видимых полей: `{ name: текст }`; пустой объект — форма верна. */
export function validate(fields, values) {
  const errors = {};
  for (const field of visibleFields(fields, values)) {
    const value = values[field.name];
    if (field.required && empty(field, value)) {
      errors[field.name] = typeof field.required === 'string' ? field.required
        : field.type === 'multi' ? REQUIRED_MULTI : REQUIRED;
      continue;
    }
    if (typeof field.validate === 'function') {
      const message = field.validate(value, values);
      if (message) errors[field.name] = message;
    }
  }
  return errors;
}

/** Итог формы: значения только видимых полей. */
export function result(fields, values) {
  const out = {};
  for (const field of visibleFields(fields, values)) {
    const value = values[field.name];
    out[field.name] = field.type === 'multi' ? [...asList(value)] : value;
  }
  return out;
}
