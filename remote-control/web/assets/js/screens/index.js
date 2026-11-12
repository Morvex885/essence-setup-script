// Маршрут (`router.parse(location.hash).name`) → компонент экрана.
// Каждый экран: `function XScreen({ ctx, param })`, `param` — второй сегмент
// маршрута (`#/nodes/<имя>`) либо `null`.
import { SummaryScreen } from './summary.js';
import { NodesScreen } from './nodes.js';
import { ConnectionsScreen } from './connections.js';
import { AwgScreen } from './awg.js';
import { TelegramScreen } from './telegram.js';
import { ClientsScreen } from './clients.js';
import { GroupsScreen } from './groups.js';
import { TemplatesScreen } from './templates.js';
import { GenerateScreen } from './generate.js';
import { SubscriptionsScreen } from './subscriptions.js';
import { SourceScreen } from './source.js';
import { SettingsScreen } from './settings.js';

export const SCREENS = {
  summary: SummaryScreen,
  nodes: NodesScreen,
  connections: ConnectionsScreen,
  awg: AwgScreen,
  telegram: TelegramScreen,
  clients: ClientsScreen,
  groups: GroupsScreen,
  templates: TemplatesScreen,
  generate: GenerateScreen,
  subscriptions: SubscriptionsScreen,
  source: SourceScreen,
  settings: SettingsScreen,
};
