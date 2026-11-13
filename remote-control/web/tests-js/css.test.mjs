// Собственные классы раскладки `css/app.css` не совпадают с классами daisyUI
// (`vendor/daisyui.css`): иначе правила компонента daisyUI ложатся поверх.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const asset = (path) => readFileSync(new URL(`../assets/${path}`, import.meta.url), 'utf8');

/** Классы раскладки из скилла essence-web («Оформление»). */
const OWN = /^(shell.*|topbar.*|page.*|vstack|row|toolbar|facts?|chips?|field.*|danger-zone|op-.*|editor-.*|t-(ok|warn|error|info|dim))$/;

/** Имена классов в селекторах CSS (без содержимого блоков объявлений). */
function classSelectors(css) {
  const selectors = css.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\{[^{}]*\}/g, '{}');
  return new Set([...selectors.matchAll(/\.(-?[_a-zA-Z][\w-]*)/g)].map((match) => match[1]));
}

test('классы раскладки app.css не совпадают с классами daisyUI', () => {
  const own = [...classSelectors(asset('css/app.css'))].filter((name) => OWN.test(name));
  assert.ok(own.includes('vstack') && own.includes('row') && own.includes('t-dim'), 'классы раскладки найдены');
  const daisy = classSelectors(asset('vendor/daisyui.css'));
  assert.deepEqual(own.filter((name) => daisy.has(name)), []);
});
