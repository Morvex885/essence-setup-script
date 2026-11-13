// Редактор YAML на Ace (вендоренный классический скрипт, глобальный `ace`;
// `mode-yaml`, `ext-searchbox` и обе темы подключены в index.html — Ace
// ничего не догружает сам). Без воркера (`useWorker: false`); проверка
// шаблона — командой ядра `template check`, её итог приходит отметками.
import { html, useEffect, useRef } from '../vendor/preact-htm.js';

/**
 * Команды Ace, которые догружают невендоренные расширения (`ext/prompt`,
 * `ext/error_marker`, `ext/settings_menu`): убираются, чтобы редактор не
 * запрашивал отсутствующие файлы.
 */
const UNAVAILABLE_COMMANDS = [
  'gotoline', 'goToNextError', 'goToPreviousError', 'showSettingsMenu',
  'openCommandPallete', 'openCommandPalette', 'modeSelect',
];

const THEME_DARK = 'ace/theme/github_dark';
const THEME_LIGHT = 'ace/theme/github_light_default';

/**
 * `value` — текст снаружи (ставится только если отличается от текста
 * редактора), `onChange(text)` — правка пользователя, `annotations` — отметки
 * Ace (`{row,column,text,type}`), `dropped` — строки `[от, до]` (с единицы),
 * выпадающие из выбранного варианта, `dark` — тема, `onSave` — Ctrl/Cmd+S.
 * `api.current = { goto(line, column) }` — переход к строке и столбцу (с единицы).
 */
export function AceEditor({ value, onChange, annotations = [], dropped = [], dark = false, onSave = null, api = null, label = 'Редактор' }) {
  const host = useRef(null);
  const editor = useRef(null);
  const markers = useRef([]);
  const applying = useRef(false);
  const latest = useRef({ onChange, onSave });
  latest.current = { onChange, onSave };

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
      theme: dark ? THEME_DARK : THEME_LIGHT,
    });
    instance.commands.removeCommands(UNAVAILABLE_COMMANDS);
    instance.commands.addCommand({
      name: 'save',
      bindKey: { win: 'Ctrl-S', mac: 'Command-S' },
      exec: () => { if (latest.current.onSave) latest.current.onSave(); },
    });
    instance.textInput.getElement().setAttribute('aria-label', label);
    applying.current = true;
    instance.session.setValue(value ?? '');
    applying.current = false;
    instance.session.on('change', () => {
      if (!applying.current) latest.current.onChange(instance.getValue());
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
    if (!instance || value === null || value === undefined || value === instance.getValue()) return;
    // Замена снаружи (импорт, сброс, сохранение) — не правка пользователя.
    applying.current = true;
    instance.setValue(value, -1);
    applying.current = false;
  }, [value]);

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
