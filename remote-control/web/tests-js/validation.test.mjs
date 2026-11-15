// Общие векторы проверок ввода (`core/tests/validation_vectors.json`):
// те же значения проверяют тесты ядра и меню — копии правил в панели не расходятся с ядром.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import * as profiles from '../assets/js/screens/profiles-model.js';
import * as nodes from '../assets/js/screens/nodes-model.js';

const vectors = JSON.parse(readFileSync(new URL('../../core/tests/validation_vectors.json', import.meta.url), 'utf8'));

function check(kind, rule) {
  for (const value of vectors[kind].valid) assert.ok(rule(value), `${kind} valid: ${JSON.stringify(value)}`);
  for (const value of vectors[kind].invalid) assert.ok(!rule(value), `${kind} invalid: ${JSON.stringify(value)}`);
}

test('общие векторы: имена, домены, порты, email и версии — как в ядре', () => {
  check('names', profiles.nameValid);
  check('domains', (value) => value === value.trim() && profiles.domainValid(value));
  // Пустой порт — умолчание вопроса, в векторах — значение для ядра.
  check('ports', (value) => value !== '' && profiles.portError(value) === null);
  check('ports', (value) => value !== '' && nodes.portError(value) === null);
  check('emails', (value) => value !== '' && profiles.emailError(value) === null);
  check('versions', profiles.versionValid);
});

test('общие векторы: предложение имени — транслитерация, ударения и уникальность', () => {
  for (const { value, taken, suggestion } of vectors.suggestions) {
    assert.equal(profiles.suggestName(value, taken), suggestion, value);
  }
  // Поле имени предлагает имя, которого нет среди существующих.
  const field = profiles.nameField({ label: 'Имя', taken: ['vless-tcp'] });
  assert.equal(field.suggest('VLESS TCP'), 'vless-tcp-2');
});
