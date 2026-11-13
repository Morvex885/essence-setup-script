---
name: essence-web
description: "Правила веб-панели essence-rc (remote-control/web): экраны на Preact+htm и daisyUI без сборки, контекст ctx и формы ctx.form, страницы с вкладками, подтверждения и коды решений, вход и токены, тема, журнал, редактор шаблонов на Ace, вендоренные библиотеки, модели и JS-тесты node --test, слушатель essence-rc-web. Использовать при создании и изменении экранов и модулей remote-control/web; не для команд ядра (essence-commands) и терминального меню (essence-menus)."
---

# Essence web

## Когда применять

Используйте этот skill для экранов, модулей, CSS и вендоренных файлов веб-панели (`remote-control/web/assets`) и для слушателя `remote-control/web/src/lib.rs` (крейт `essence-rc-web`). Панель — только слой экранов: вся логика — в командах ядра. Новое действие — сначала команда ядра (скилл `essence-commands`), экран TUI (скилл `essence-menus`), затем экран панели; паритет меню и панели обязателен: те же argv, коды и переходы, меняется только сбор значений (одна форма вместо цепочки вопросов) и раскладка.

Порядок работы: прочитайте `AGENTS.md`, соседний экран панели, его модель и тест, а также экран TUI того же раздела (`remote-control/tui/src/*.rs`) — панель повторяет его argv, вопросы и переходы. Таблица разделов и команд — `docs/remote-control.md`, разделы «Главное меню» и «Веб-панель».

## Устройство

Пути ниже — от `remote-control/web/assets/`.

- `index.html`: в `<head>` первым — классический `js/theme-boot.js` (тема до отрисовки), затем `vendor/xterm.css`, `vendor/daisyui.css`, `css/app.css`; в `<body>` — классические скрипты вендора (`vendor/xterm.js`, `vendor/xterm-addon-fit.js`, `vendor/qrcode.js`, `vendor/ace/ace.js`, `mode-yaml.js`, `ext-searchbox.js`, `theme-github_light_default.js`, `theme-github_dark.js`; глобальные `Terminal`, `FitAddon.FitAddon`, `qrcode`, `ace`) и модуль `js/app.js`. `vendor/preact-htm.js` — ES-модуль (`html`, `render`, хуки `useState`, `useEffect`, `useRef`, `useMemo`, …).
- `js/protocol.js` — клиент протокола v3 поверх WebSocket (`/ws`): запросы, события `log`/`activity`/`output`, терминал, переподключение через 1, 2, 5 с; токен возобновления — в `sessionStorage['essence-rc-resume']` (`RESUME_KEY`).
- `js/session.js` — вход: `session open` (`--remember-key`, код доступа, пароль запуска), разбор ответа, первый запуск и восстановление.
- `js/router.js` — маршрут `#/раздел/параметр/вкладка`: `parse(hash)` → `{name, param, tab}` (сегменты декодируются по отдельности, лишние отбрасываются), `format(name, param, tab)`, `navigate`; `consumeTicket` извлекает и сразу стирает `#ticket=` из адреса.
- `js/app.js` — каркас: меню `MENU` (`{name, label, icon}` и разделитель `{divider:true}`), шапка (источник, «нет связи», команда другого клиента и полоса прогресса), снэкбары, журнал, защита ухода, тема, `makeContext` (объект `ctx` экранов), экраны входа.
- `js/theme.js` — тема: выбор `system|light|dark` в `localStorage['essence-rc-theme']` (`readChoice`, `storeChoice`, `resolve` → `essence-light|essence-dark`, `nextChoice`, `apply`, `watch`); `js/theme-boot.js` — та же логика классическим скриптом. Переменные тем daisyUI — блоки `[data-theme="essence-light|essence-dark"]` в `css/app.css`.
- `js/flows.js` — перенос `tui/src/confirm.rs` и кодов нод: `runConfirmed`, `reviewReply`, `decisionFlag`/`setFlag`/`clearFlag`, `isFailure`, `handleNodeCodes`, `nodeRequest`.
- `js/format.js` — форматирование значений и тексты ошибок (`errorMessage`), индикатор чужой команды, признак открытой панели, фильтр журнала `filterJournal`.
- `js/dialogs.js` — модальные окна daisyUI (`modal modal-open` > `modal-box`): `confirm`, `askSecret`, `ask`, `choose`, `toggle`, `form`, `show`, окно операции с журналом; попадают в `ctx`. Esc закрывает верхнее окно значением отмены (`confirm` → `false`, `secret|text|choose|toggle|form` → `null`, `show` → `undefined`; окно операции — только после завершения); щелчок по фону не закрывает.
- `js/form-model.js` — чистая логика форм (`initialValues`, `visibleFields`, `validate`, `result`); `js/table-model.js` — поиск по таблице (`filterRows`, `cellText`).
- `js/ui.js` — компоненты: `Layout`, `Page`, `DataTable`, `MoreMenu`, `Card`, `Facts`, `Badge`, `Chips`, `Empty`, `Stats`/`Stat`, `Snackbars`, `Button`, `IconButton`, `Segmented`, `Tone`, `SecretField`, `Checkbox`, `CopyButton`, `Download`/`downloadText`, `FileText`, `Pre`, `useModalFocus`.
- `js/icons.js` — `Icon({name, size})`: внутренние элементы SVG Lucide (список имён — `ICONS`); новая иконка копируется из `lucide-static` той же версии.
- `js/template-editor.js` — `AceEditor({value, version, onChange, annotations, dropped, dark, api, label})` поверх глобального `ace` (`useWorker: false`, `enableKeyboardAccessibility: true` — Esc выводит фокус из текста, тема по `ctx.theme.dark`, `api.current.goto(line, column)`). Редактор не управляется текстом: `value` ставится при создании и при смене `version` (замена снаружи — сброс, импорт, новый текст с сервера без черновика) с сохранением курсора; сравнивать `value` с текстом редактора на каждой отрисовке нельзя — поздняя отрисовка откатывает набранное. Ctrl/Cmd+S — обработчик `window` на экране редактора; действия редактора (сохранение, импорт, удаление, группы, очередь проверок) — `screens/templates-flow.js`.
- `js/terminal.js` — оверлей терминала нод (xterm.js и FitAddon).
- `js/screens/index.js` — `SCREENS`: маршрут → компонент (`summary`, `nodes`, `clients`, `groups`, `templates`, `subscriptions`, `telegram`, `source`, `settings`, `journal`; неизвестный — сводка). Экран — `function XScreen({ ctx, param, tab })`; ключ экрана — `раздел/параметр`, смена вкладки экран не пересоздаёт. Чистые функции экранов (argv, разбор ответов, переходы) — `screens/*-model.js`; общие хуки и кнопки — `screens/kit.js` (`useCommand`, `useCommands`, `useBusy`, `useMounted`, `Action`, `Actions`, `Context`, `ReadFailed`, `Loaded`); общие действия клиентов, групп и подписок — `screens/shared.js`; формы-действия, вызываемые из нескольких разделов, — экспорт модуля раздела (`addNodeFlow`, `setNodePassword`, `setupSsh` из `nodes.js`, `addClientFlow` из `clients.js`, `generateFlow` из `generate.js`).

## Правила экрана

- **Данные — только командами.** `ctx.request(argv, { secrets, input, expect, operation, quiet })`, `ctx.call(...words)`, хуки `useCommand(ctx, argv, deps, { expect, quiet })`/`useCommands`. Своих расчётов состояния в экране нет; после действия данные перечитываются командой.
- **Страница.** Экран рисует `Page({ title, subtitle, back: {href, label}, badge, actions, tabs })`; вкладки — `[{id, label, href: ctx.href(раздел, имя, id), active}]`, вкладка по умолчанию — первая. Списки — `DataTable({ columns: [{key, label, render?, search?}], rows, rowKey, href, menu, selection })`: первая колонка — ссылка, `menu(row)` — пункты `MoreMenu`, поиск появляется при числе строк больше 8 («/» ставит в него фокус), на узком экране строки — карточки. Состояния — `Facts`, `Badge` (`ok|warn|error|info|neutral`), `Chips`; пустой список — `Empty`. Опасная зона — `Card` с `className="danger-zone"`.
- **Кнопки.** `Button({ kind })`: `primary` — одно главное действие страницы или окна, `neutral` — прочие, `danger` — опасные, `ghost` — второстепенные. В экранах — `Action({ primary, tone: 'danger', icon })`. Редкие действия — в `MoreMenu` (с явной `label` — текстовая кнопка «Действия ▾»). `useBusy` блокирует кнопки экрана на время запроса.
- **Сбор значений — одной формой.** `ctx.form({ title, context, fields, submit, tone, wide })` → значения видимых полей или `null`. Поле: `{ name, label, type: text|secret|select|radio|multi|checkbox|textarea, value, options: [{value,label,hint,disabled}], placeholder, hint, required: true|'текст', validate(value, values), when(values), autofocus }`. Ошибки показываются под полями при отправке, скрытые (`when` → `false`) поля не проверяются и не возвращаются. Значения секретных полей уходят только в `secrets` запроса. Вопросы о планах и кодах `_required` остаются отдельными окнами (`flows.js`).
- **Опасное действие** — только `ctx.runConfirmed(title, question, argv, { secrets, input })`: команда без `--yes` отвечает `confirmation_required` с планом, диалог показывает план и один вопрос, повтор — с `--yes --plan-token`; `plan_changed` показывается заново не более двух раз. Своих «вы уверены?» поверх плана нет. Коды `_required` превращаются в один вопрос на код и повтор команды с флагом (`decisionFlag`/`setFlag` — единственное соответствие код → флаг) или секретом.
- **Коды нод** (`missing_secret`, `host_key_changed`, `host_key_unknown`, `needs_setup`) — `ctx.nodeRequest(name, argv, review)`; оставшийся сбой `nodeRequest` сообщает сам, `ctx.failed()` после него не вызывается.
- **Сбои.** Текст ошибки ядра показывает один раз `ctx.request` (кроме планов, ожидаемых кодов `expect` и `quiet: true` для фоновых чтений, где экран сам показывает недоступность); отказ от плана — не сбой (`ctx.isFailure`); сбой действия вне `nodeRequest` — `ctx.failed()` один раз. Сообщения — снэкбары (`ctx.notify`): успех и предупреждение исчезают через 5 с, ошибка — по кнопке; все записи — в журнале (`ctx.journal`, раздел `#/journal`).
- **Терминал** — `ctx.terminal(argv, title)` (`node shell`, `telegram menu`).
- **Файлы** — чтение `FileText` (`readInputFile` из `format.js`: не больше 1 МиБ, строго UTF-8, иначе `onText(null, причина)` — экран показывает причину или «Файл недоступен или не в UTF-8.»; содержимое уходит полем `input`), сохранение `downloadText` / `Download`; путей на машине пользователя панель не знает.
- **Навигация** — `ctx.navigate(name, param, tab)`, ссылки — `ctx.href(name, param, tab)`; исчезнувший объект (`not_found` или нет строки в списке) возвращает к списку раздела. Переход по ответу асинхронного запроса — только пока экран смонтирован (`useMounted` из `screens/kit.js`), иначе поздний ответ уведёт из раздела, выбранного пользователем. Несохранённые правки — `ctx.setLeaveGuard(async () => boolean)` (вопрос перед сменой маршрута и `beforeunload`); снимается после сохранения, сброса и при размонтировании.
- **Фоновые команды** (`template check` редактора) не меняют индикатор активности в шапке (`SILENT_ACTIVITY` в `app.js`); чтения не перечитывают `status` (`READ_VERBS`).
- **Фокус** — модальные слои (диалоги, терминал) используют `useModalFocus` из `ui.js`: фокус внутрь при открытии, Tab не выходит из слоя, при закрытии фокус возвращается.
- **Оформление.** Только классы daisyUI 5 (компоненты; утилит Tailwind в вендоренном CSS нет) и собственные классы `css/app.css` (`.shell*`, `.topbar`, `.page*`, `.stack`, `.row`, `.toolbar`, `.facts`, `.chips`, `.field*`, `.danger-zone`, `.op-*`, `.editor-*`, `.t-ok|warn|error|info|dim`). Спокойная тема: серые поверхности, фиолетовый — только главная кнопка, активный пункт меню и ссылки. Раскладка: от 1024 px — меню с подписями, 640–1023 px — иконки, уже 640 px — меню по кнопке, таблицы карточками, окна на весь экран. Класс `.stack` совпадает с компонентом daisyUI — его правила для детей сняты в `app.css`.
- Тексты — на русском; обработчики навешиваются компонентами, не inline-атрибутами разметки.

## Секреты и вход

- Секреты передаются только полем `secrets` запроса (`SecretField`, секретные поля `ctx.form`, `ctx.askSecret`); не хранятся в `localStorage`/`sessionStorage`, URL и журнале, не попадают в argv.
- Панель хранит только токен возобновления в `sessionStorage` (`protocol.js`) и выбор темы в `localStorage` (`theme.js`).
- `#ticket=` стирается из адреса сразу при загрузке (`consumeTicket`); код уходит только секретом `access-token` в `session open`.

## Вендор и сборка

- Сборки и npm нет: `package.json` — только `{"private":true,"type":"module"}` для `node --test`. Зависимости не добавляются.
- Файлы `assets/vendor` не правятся: Preact+htm, xterm, qrcode, daisyUI 5 (`daisyui.css`, темы — через `data-theme`, без правила `prefers-color-scheme`), Ace (`vendor/ace/`). Иконки Lucide скопированы в `js/icons.js`. Обновление — новая загрузка с записью версии, источника и SHA-256 в `assets/vendor/VENDOR.md`. Текст лицензии каждой библиотеки лежит рядом (`assets/vendor/LICENSE-*`) и вшивается вместе с ассетами; новая библиотека добавляется с ним.
- Ace подключается классическими скриптами и ничего не догружает: `useWorker: false` задаётся раньше `mode` (иначе режим пытается создать воркер из `blob:`, CSP его запрещает); команды, которым нужны невендоренные расширения (`gotoline`, `modeSelect` и палитра команд — `ext/prompt`, `showSettingsMenu` — `ext/settings_menu`), удалены в `template-editor.js`. `ext/error_marker` встроен в `ace.js`: `goToNextError` (Alt+E, на macOS F4) остаётся. Новое расширение Ace — новый вендоренный файл и `<script>` в `index.html`.
- CSP слушателя (`CSP_HEAD`/`CSP_TAIL` и `content_security_policy` в `web/src/lib.rs`) — `default-src 'self'`, `connect-src` — `'self'` и точный `ws(s)://` адрес из проверенного `Host`, без внешних источников и inline-скриптов: никаких CDN, inline-`<script>`, `eval`, `new Function` и воркеров. Стили inline допустимы (`style-src 'self' 'unsafe-inline'`), картинки — `self` и `data:`.
- Ассеты вшиваются в бинарник (`include_dir!`, `build.rs` следит за каталогом `assets`); отдаются только расширения из `content_type` в `web/src/lib.rs` (html, css, js, mjs, svg, json, woff2) — новое расширение добавляется туда.

## Тесты

- Логика выносится из компонентов в `screens/*-model.js`, `flows.js`, `format.js`, `router.js`, `theme.js`, `form-model.js`, `table-model.js` и тестируется в `remote-control/web/tests-js/*.test.mjs` (`node:test`, `node:assert/strict`, без зависимостей; фикстуры и сценарии — по образцу тестов экранов `tui`). Потоки с диалогами проверяются поддельным `ctx` (`form`, `confirm`, `request` по сценарию).
- Протокол — `tests-js/protocol.test.mjs`, вход — `tests-js/session.test.mjs`; слушатель (заголовки, Host, Origin, WebSocket) — `remote-control/web/tests/listener.rs`; сеть демона (коды, пароль, токены, `--connect`) — `remote-control/bin/tests/daemon_network.rs`.
- Проверяется поведение (argv, флаги, переходы, коды), не тексты и не DOM.

## Проверка

- `node --test remote-control/web/tests-js/*.test.mjs` (Node 22) и `node --check` изменённых `.js`;
- при изменении слушателя или ассетов — `cd remote-control && cargo test -p essence-rc-web --locked` (свои прогоны — с отдельным `CARGO_TARGET_DIR`);
- ручной смоук — `essence-rc web run` (с отдельным `ESSENCE_RC_DATA_DIR`), открыть изменённый экран на ширине 1280, 800 и 400 px, пройти его действия, проверить консоль браузера на нарушения CSP.
