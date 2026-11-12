// Генерация конфигов (`tui/src/clients.rs::generation`): `group list` в
// контексте, `generate --all|--group|--client` через `shared.js::runGenerate`.
import { html } from '../../vendor/preact-htm.js';
import { Card } from '../ui.js';
import { useCommand, useBusy, Action, Context, Back, Loaded } from './kit.js';
import { runGenerate } from './shared.js';
import { GENERATE_ALL, generateGroup, generateClient, generationContext } from './catalog-model.js';
import { pick } from './clients-model.js';

export function GenerateScreen({ ctx }) {
  const state = useCommand(ctx, ['group', 'list']);
  const [busy, run] = useBusy();
  const generate = (scope) => run(async () => {
    const tail = await scope();
    if (tail === null) return;
    await runGenerate(ctx, tail);
    await state.reload();
  });
  const all = () => generate(async () => GENERATE_ALL);
  const group = () => generate(async () => {
    const name = await pick(ctx, 'group', 'Генерация по группе');
    return name === null ? null : generateGroup(name);
  });
  const client = () => generate(async () => {
    const name = await pick(ctx, 'client', 'Генерация для клиента');
    return name === null ? null : generateClient(name);
  });
  const actions = html`
    <${Action} tone="change" disabled=${busy} onClick=${all}>Всем клиентам<//>
    <${Action} tone="change" disabled=${busy} onClick=${group}>По группе<//>
    <${Action} tone="change" disabled=${busy} onClick=${client}>Одному клиенту<//>
    <${Back} ctx=${ctx} to="summary" />`;
  return html`<${Loaded} title="Генерация конфигов" state=${state} actions=${html`<${Back} ctx=${ctx} to="summary" />`}>${(data) => html`
    <${Card} title="Генерация конфигов" actions=${actions}>
      <${Context} lines=${generationContext(data)} />
    <//>`}<//>`;
}
