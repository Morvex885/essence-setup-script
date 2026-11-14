// Маршрут (`router.parse(location.hash).name`) → компонент экрана.
// Каждый экран: `function XScreen({ ctx, param, tab })`, `param` — второй
// сегмент маршрута (`#/nodes/<имя>`), `tab` — третий (`#/nodes/<имя>/awg`)
// либо `null`. Неизвестный маршрут — сводка.
import { SummaryScreen } from './summary.js';
import { NodesScreen } from './nodes.js';
import { ClientsScreen } from './clients.js';
import { GroupsScreen } from './groups.js';
import { TemplatesScreen } from './templates.js';
import { SubscriptionsScreen } from './subscriptions.js';
import { TelegramScreen } from './telegram.js';
import { SourceScreen } from './source.js';
import { SettingsScreen } from './settings.js';
import { JournalScreen } from './journal.js';

export const SCREENS = {
  summary: SummaryScreen,
  nodes: NodesScreen,
  clients: ClientsScreen,
  groups: GroupsScreen,
  templates: TemplatesScreen,
  subscriptions: SubscriptionsScreen,
  telegram: TelegramScreen,
  source: SourceScreen,
  settings: SettingsScreen,
  journal: JournalScreen,
};
