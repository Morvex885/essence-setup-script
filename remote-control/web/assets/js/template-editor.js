// Редактор YAML на Ace (вендоренный классический скрипт, глобальный `ace`;
// `mode-yaml`, `ext-searchbox` и обе темы подключены в index.html, модуль
// `ext/error_marker` встроен в `ace.js` — Ace ничего не догружает сам). Без
// воркера (`useWorker: false`); проверка шаблона — командой ядра
// `template check`, её итог приходит отметками.
import { html, useEffect, useRef } from '../vendor/preact-htm.js';

/**
 * Команды Ace, которые догружают невендоренные расширения (`ext/prompt`,
 * `ext/settings_menu`): убираются, чтобы редактор не запрашивал отсутствующие
 * файлы. Переход к ошибкам (`goToNextError`: Alt+E, на macOS F4) работает: его модуль в `ace.js`.
 */
const UNAVAILABLE_COMMANDS = ['gotoline', 'showSettingsMenu', 'openCommandPallete', 'openCommandPalette', 'modeSelect'];

const THEME_DARK = 'ace/theme/github_dark';
const THEME_LIGHT = 'ace/theme/github_light_default';

/**
 * Редактор без обратной связи по тексту: `value` ставится при создании и
 * затем только при смене `version` (замена снаружи: сброс, импорт, новый
 * текст с сервера без черновика) — с сохранением позиции курсора. Иначе
 * поздняя отрисовка с устаревшим `value` откатывала бы набранное.
 * `onChange(text)` — правка пользователя (при ней устаревшие отметки
 * снимаются до нового отчёта), `annotations` — отметки Ace
 * (`{row,column,text,type}`), `dropped` — строки `[от, до]` (с единицы),
 * выпадающие из выбранного варианта, `dark` — тема, `label` — подпись поля.
 * `api.current = { goto(line, column) }` — переход к строке и столбцу (с единицы).
 * Клавиатура: Tab в тексте — отступ; Esc выводит фокус на рамку редактора,
 * откуда Tab идёт дальше по странице, Enter возвращает в текст.
 */
export function AceEditor({ value, version = 0, onChange, annotations = [], dropped = [], dark = false, api = null, label = 'Редактор' }) {
  const host = useRef(null);
  const editor = useRef(null);
  const markers = useRef([]);
  const applying = useRef(false);
  const applied = useRef(version);
  const latest = useRef(onChange);
  latest.current = onChange;

  const clearMarks = (instance) => {
    for (const id of markers.current) instance.session.removeMarker(id);
    markers.current = [];
    instance.session.clearAnnotations();
  };

  useEffect(() => {
    const ace = window.ace;
    // `useWorker` раньше `mode`: иначе режим успевает запустить воркер (CSP его запрещает).
    const instance = ace.edit(host.current, {
      useWorker: false,
      mode: 'ace/mode/yaml',
      tabSize: 2,
      useSoftTabs: true,
      showPrintMargin: false,
      fontSize: 13,
      enableKeyboardAccessibility: true,
      theme: dark ? THEME_DARK : THEME_LIGHT,
    });
    instance.commands.removeCommands(UNAVAILABLE_COMMANDS);
    instance.textInput.getElement().setAttribute('aria-label', label);
    applying.current = true;
    instance.session.setValue(value ?? '');
    applying.current = false;
    instance.session.on('change', () => {
      if (applying.current) return;
      if (markers.current.length > 0 || instance.session.getAnnotations().length > 0) clearMarks(instance);
      latest.current(instance.getValue());
    });
    editor.current = instance;
    if (api) {
      api.current = {
        goto(line, column = 1) {
          instance.gotoLine(line, Math.max(0, column - 1), true);
          instance.focus();
        },
      };
    }
    return () => {
      if (api) api.current = null;
      editor.current = null;
      instance.destroy();
    };
  }, []);

  useEffect(() => {
    const instance = editor.current;
    if (!instance || version === applied.current) return;
    applied.current = version;
    if (value === null || value === undefined || value === instance.getValue()) return;
    const cursor = instance.getCursorPosition();
    applying.current = true;
    instance.setValue(value, -1);
    applying.current = false;
    instance.moveCursorToPosition(cursor);
    instance.clearSelection();
  }, [version]);

  useEffect(() => {
    if (editor.current) editor.current.setTheme(dark ? THEME_DARK : THEME_LIGHT);
  }, [dark]);

  useEffect(() => {
    if (editor.current) editor.current.session.setAnnotations(annotations);
  }, [annotations]);

  useEffect(() => {
    const instance = editor.current;
    if (!instance) return;
    const { Range } = window.ace.require('ace/range');
    for (const id of markers.current) instance.session.removeMarker(id);
    // Поверх текста: строки, которых нет в выбранном варианте, бледнее.
    markers.current = dropped.map(([from, to]) => instance.session.addMarker(new Range(from - 1, 0, to - 1, 1), 'ace-dropped', 'fullLine', true));
  }, [dropped]);

  return html`<div class="template-ace" ref=${host}></div>`;
}
