// Генерация конфигов (`tui/src/clients.rs::generation`): форма «Кому» и
// `generate --all|--group|--client` через `shared.js::runGenerate`.
import { runGenerate, nameOptions } from './shared.js';
import { generateGroup, generateClient, generateScope } from './catalog-model.js';

const SCOPES = [
  { value: 'all', label: 'Всем клиентам' },
  { value: 'group', label: 'Группе' },
  { value: 'client', label: 'Одному клиенту' },
];

/**
 * Генерация конфигов: `preset` — `{ group }` или `{ client }` — сразу без
 * формы; иначе списки групп и клиентов читаются до формы (сбой — `ctx.failed`).
 */
export async function generateFlow(ctx, preset = null) {
  if (preset && typeof preset.group === 'string') { await runGenerate(ctx, generateGroup(preset.group)); return; }
  if (preset && typeof preset.client === 'string') { await runGenerate(ctx, generateClient(preset.client)); return; }
  const [groups, clients] = await Promise.all([ctx.request(['group', 'list']), ctx.request(['client', 'list'])]);
  if (!groups.ok || !clients.ok) { ctx.failed(); return; }
  const values = await ctx.form({
    title: 'Генерация конфигов',
    submit: 'Сгенерировать',
    fields: [
      { name: 'scope', label: 'Кому', type: 'radio', value: 'all', options: SCOPES },
      { name: 'group', label: 'Группа', type: 'select', options: nameOptions(groups.data), required: true, when: (v) => v.scope === 'group' },
      { name: 'client', label: 'Клиент', type: 'select', options: nameOptions(clients.data), required: true, when: (v) => v.scope === 'client' },
    ],
  });
  if (values === null || values === undefined) return;
  await runGenerate(ctx, generateScope(values));
}
