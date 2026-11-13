// Действия редактора шаблонов (`tui/src/clients.rs::edit_template`,
// `template_groups`, удаление) без DOM: зависимости — объект `ctx` экрана
// (`runConfirmed`, `isFailure`, `failed`, `notify`, `request`, `confirm`, `form`).
// Экран `templates.js` только перечитывает данные и обновляет черновик.
import { asList } from '../format.js';
import {
  TEMPLATE_FILE_UNREADABLE, DEFAULT_TEMPLATE, templateImport, templateInput, templateDelete, templateGroups,
  templateKind, groupOptions,
} from './catalog-model.js';

export const GROUPS_UNCHANGED = 'Изменений нет.';
export const DRAFT_REPLACED = 'Импорт заменит несохранённые изменения в редакторе.';

/**
 * Черновик после успешного сохранения текста `sent`: тот же текст — сохранён
 * (`null`), более новая правка, сделанная во время сохранения, остаётся.
 */
export function settleDraft(current, sent) {
  return current === sent ? null : current;
}

/**
 * Нужна ли защита ухода: черновик отличается от сохранённого `content` либо
 * идёт запись `saving` (текст сохранения или импорта из файла, пока команда
 * идёт; иначе `null`), а в редакторе уже другой текст — даже совпавший с
 * прежним сохранённым: после ухода команда запишет `saving`, а не последнюю правку.
 */
export function unsavedChanges(draft, content, saving) {
  const text = draft !== null ? draft : content;
  return (draft !== null && draft !== content) || (saving !== null && saving !== text);
}

/**
 * «Сохранить»: `template import --name T` с черновиком; план ядро просит при
 * перезаписи или ошибках шаблона (одни предупреждения — без плана).
 * `true` — сохранено.
 */
export async function saveTemplate(ctx, name, text) {
  const reply = await ctx.runConfirmed('Сохранение шаблона', 'Сохранить шаблон?', templateImport(name), { input: templateInput(text) });
  // Отказ от плана — не сбой; черновик остаётся.
  if (ctx.isFailure(reply)) ctx.failed();
  return reply.ok === true;
}

/**
 * «Импорт из файла» (`FileText`: текст или `null` и причина). Несохранённый
 * черновик заменяется только после вопроса; затем — импорт (план — по решению ядра).
 * `onSend(text)` вызывается перед командой: экран считает этот текст идущей
 * записью (`unsavedChanges`) до конца импорта. `true` — шаблон перезаписан.
 */
export async function importTemplateFile(ctx, name, fileText, reason, dirty, onSend = () => {}) {
  if (fileText === null) {
    ctx.notify('warn', reason || TEMPLATE_FILE_UNREADABLE);
    return false;
  }
  if (dirty && !(await ctx.confirm({
    title: 'Несохранённые изменения', plan: [], question: `${DRAFT_REPLACED} Продолжить?`, yes: 'Импортировать', tone: 'danger',
  }))) return false;
  onSend(fileText);
  const reply = await ctx.runConfirmed('Импорт шаблона', 'Перезаписать шаблон?', templateImport(name), { input: templateInput(fileText) });
  if (ctx.isFailure(reply)) ctx.failed();
  return reply.ok === true;
}

/** Пункт удаления: пользовательский — «Удалить», перекрывающий встроенный — «Сбросить к встроенному». */
export function deleteLabel(row) {
  return templateKind(row) === 'override' ? 'Сбросить к встроенному' : 'Удалить';
}

/** `template delete` по плану; вопрос — по виду шаблона. `true` — удалено. */
export async function deleteTemplate(ctx, row) {
  const reset = templateKind(row) === 'override';
  const reply = await ctx.runConfirmed(reset ? 'Сброс шаблона' : 'Удаление шаблона',
    reset ? 'Сбросить шаблон к встроенному?' : 'Удалить шаблон?', templateDelete(row.name));
  if (ctx.isFailure(reply)) ctx.failed();
  return reply.ok === true;
}

/**
 * «Группы…» (`clients.rs::template_groups`): мультивыбор из `group list`,
 * затем `template groups` по плану. Пустой выбор возвращает все группы
 * шаблона к `default.yaml`. `true` — группы изменились.
 */
export async function editTemplateGroups(ctx, name) {
  const groups = await ctx.request(['group', 'list']);
  if (!groups.ok) { ctx.failed(); return false; }
  const { options, selected } = groupOptions(groups.data, name);
  const values = await ctx.form({
    title: `Группы шаблона: ${name}`,
    submit: 'Далее',
    context: name === DEFAULT_TEMPLATE
      ? ['Группы без своего шаблона используют default.yaml. Чтобы убрать группу отсюда, назначьте ей другой шаблон.']
      : ['Снятые группы вернутся к default.yaml.'],
    fields: [{ name: 'groups', label: 'Группы', type: 'multi', options, value: selected }],
  });
  if (values === null) return false;
  const reply = await ctx.runConfirmed('Группы шаблона', 'Применить?', templateGroups(name, values.groups));
  if (ctx.isFailure(reply)) ctx.failed();
  if (!reply.ok) return false;
  const changed = asList(reply.data && reply.data.assigned).length > 0 || asList(reply.data && reply.data.reset).length > 0;
  if (!changed) ctx.notify('info', GROUPS_UNCHANGED);
  return changed;
}

/**
 * Очередь проверок черновика: одновременно не больше одного запроса
 * `run(text)`, из ожидающих остаётся только последний текст. `deliver(reply,
 * text)` получает ответ, если за время запроса новый текст не пришёл.
 * `close()` — экран ушёл, ответы больше не доставляются.
 */
export function checkRunner(run, deliver) {
  let busy = false;
  let pending = null;
  let waiting = false;
  let closed = false;
  const pump = async () => {
    busy = true;
    try {
      while (waiting && !closed) {
        const text = pending;
        waiting = false;
        pending = null;
        const reply = await run(text);
        if (!closed && !waiting) deliver(reply, text);
      }
    } finally {
      busy = false;
    }
  };
  return {
    submit(text) {
      if (closed) return;
      pending = text;
      waiting = true;
      if (!busy) pump();
    },
    close() { closed = true; },
  };
}
