// Тема панели: выбор пользователя (`system|light|dark`) хранится в
// `localStorage` — единственное, что панель кладёт туда. Тема документа —
// `data-theme` (`essence-light|essence-dark`, переменные daisyUI в app.css).
// Ранняя установка до отрисовки — классический `theme-boot.js` (та же логика).

export const THEME_KEY = 'essence-rc-theme';
const CHOICES = ['system', 'light', 'dark'];
const DARK_QUERY = '(prefers-color-scheme: dark)';

/** Сохранённый выбор; неизвестное, пустое или недоступное хранилище — `system`. */
export function readChoice(storage) {
  let value = null;
  try { value = storage ? storage.getItem(THEME_KEY) : null; } catch { value = null; }
  return CHOICES.includes(value) ? value : 'system';
}

/** Сохранить выбор (`system` — тоже значение, не удаление). */
export function storeChoice(storage, choice) {
  try { if (storage) storage.setItem(THEME_KEY, CHOICES.includes(choice) ? choice : 'system'); } catch { /* хранилище недоступно */ }
}

/** Тема документа по выбору и системной настройке. */
export function resolve(choice, prefersDark) {
  const dark = choice === 'dark' || (choice !== 'light' && Boolean(prefersDark));
  return dark ? 'essence-dark' : 'essence-light';
}

export function apply(doc, theme) {
  doc.documentElement.dataset.theme = theme;
}

/** Системная настройка: `true` — тёмная. */
export function prefersDark(win) {
  return Boolean(win && typeof win.matchMedia === 'function' && win.matchMedia(DARK_QUERY).matches);
}

/**
 * Применить тему сейчас и при смене системной настройки; `onChange(choice,
 * theme)` после каждого применения. Возвращает функцию отписки.
 */
export function watch(win, storage, onChange = null) {
  const media = win && typeof win.matchMedia === 'function' ? win.matchMedia(DARK_QUERY) : null;
  const update = () => {
    const choice = readChoice(storage);
    const theme = resolve(choice, Boolean(media && media.matches));
    apply(win.document, theme);
    if (onChange) onChange(choice, theme);
  };
  update();
  if (media && typeof media.addEventListener === 'function') media.addEventListener('change', update);
  return () => {
    if (media && typeof media.removeEventListener === 'function') media.removeEventListener('change', update);
  };
}
