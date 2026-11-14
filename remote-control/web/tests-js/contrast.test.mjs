// Контраст тем `css/app.css` (WCAG 2.2, 1.4.3: обычный текст — не ниже
// 4,5:1). Цвета тем — oklch; вне sRGB цвет приводится уменьшением хромы, как
// в браузере (CSS Color 4). Проверяются пары, которые панель рисует: цвет
// статуса и primary как текст на base-100, base-200 и мягкой заливке (8% —
// badge-soft, alert-soft, btn-soft), X-content на заливке X, --muted.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const CSS = readFileSync(new URL('../assets/css/app.css', import.meta.url), 'utf8');
const MIN = 4.5;

const labToLinear = ([L, a, b]) => {
  const l = (L + 0.3963377774 * a + 0.2158037573 * b) ** 3;
  const m = (L - 0.1055613458 * a - 0.0638541728 * b) ** 3;
  const s = (L - 0.0894841775 * a - 1.2914855480 * b) ** 3;
  return [
    4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
    -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
    -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
  ];
};
const linearToLab = ([r, g, b]) => {
  const [l, m, s] = [
    0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b,
    0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b,
    0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b,
  ].map(Math.cbrt);
  return [
    0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
  ];
};
const clamp = (rgb) => rgb.map((c) => Math.min(1, Math.max(0, c)));
const inGamut = (rgb) => rgb.every((c) => c >= -1e-4 && c <= 1 + 1e-4);
const lchLab = (L, C, h) => [L, C * Math.cos((h * Math.PI) / 180), C * Math.sin((h * Math.PI) / 180)];

/** oklch → линейный sRGB; вне охвата — меньшая хрома при той же светлоте и тоне. */
function oklch([L, C, h]) {
  if (inGamut(labToLinear(lchLab(L, C, h)))) return clamp(labToLinear(lchLab(L, C, h)));
  let [low, high] = [0, C];
  for (let i = 0; i < 40; i += 1) {
    const mid = (low + high) / 2;
    if (inGamut(labToLinear(lchLab(L, mid, h)))) low = mid; else high = mid;
  }
  return clamp(labToLinear(lchLab(L, low, h)));
}

const luminance = ([r, g, b]) => 0.2126 * r + 0.7152 * g + 0.0722 * b;
function ratio(a, b) {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
}
const encode = (c) => (c <= 0.0031308 ? 12.92 * c : 1.055 * c ** (1 / 2.4) - 0.055);
const decode = (c) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
/** `color-mix(in oklab, fg p, bg)`. */
const mixOklab = (fg, p, bg) => {
  const [x, y] = [linearToLab(fg), linearToLab(bg)];
  return clamp(labToLinear(x.map((v, i) => p * v + (1 - p) * y[i])));
};
/** Полупрозрачный цвет поверх фона (наложение в sRGB). */
const over = (fg, alpha, bg) => fg.map((c, i) => decode(alpha * encode(c) + (1 - alpha) * encode(bg[i])));

function themes() {
  const found = {};
  for (const [, name, body] of CSS.matchAll(/\[data-theme="(essence-\w+)"\]\s*\{([^}]*)\}/g)) {
    const vars = {};
    for (const [, key, L, C, h] of body.matchAll(/--color-([\w-]+):\s*oklch\(([\d.]+)%\s+([\d.]+)\s+([\d.]+)\)/g)) {
      vars[key] = oklch([Number(L) / 100, Number(C), Number(h)]);
    }
    found[name] = vars;
  }
  return found;
}

test('темы: каждая пара текста и фона — не ниже 4,5:1', () => {
  const all = themes();
  assert.deepEqual(Object.keys(all), ['essence-light', 'essence-dark']);
  const muted = CSS.match(/--muted:\s*color-mix\(in oklch, var\(--color-base-content\) (\d+)%, transparent\)/);
  assert.ok(muted, '--muted — base-content с прозрачностью');
  const low = [];
  for (const [name, color] of Object.entries(all)) {
    const check = (label, fg, bg) => {
      const value = ratio(fg, bg);
      if (value < MIN) low.push(`${name}: ${label} — ${value.toFixed(2)}`);
    };
    for (const key of ['primary', 'secondary', 'info', 'success', 'warning', 'error']) {
      check(`${key} на base-100`, color[key], color['base-100']);
      check(`${key} на base-200`, color[key], color['base-200']);
      check(`${key} на мягкой заливке`, color[key], mixOklab(color[key], 0.08, color['base-100']));
      check(`${key}-content на ${key}`, color[`${key}-content`], color[key]);
    }
    for (const key of ['accent', 'neutral']) check(`${key}-content на ${key}`, color[`${key}-content`], color[key]);
    for (const base of ['base-100', 'base-200']) {
      check(`base-content на ${base}`, color['base-content'], color[base]);
      check(`--muted на ${base}`, over(color['base-content'], Number(muted[1]) / 100, color[base]), color[base]);
    }
  }
  assert.deepEqual(low, []);
});

test('текст предупреждений — сам цвет warning (его контраст проверен выше)', () => {
  assert.match(CSS, /\.t-warn \{ color: var\(--color-warning\); \}/);
  assert.match(CSS, /\.level-warn \{ color: var\(--color-warning\); \}/);
});
