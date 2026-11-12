---
name: essence-web
description: "Правила веб-панели essence-rc (remote-control/web): экраны на Preact+htm без сборки, контекст ctx, подтверждения и коды решений, вход и токены, вендоренные библиотеки, модели и JS-тесты node --test, слушатель essence-rc-web. Использовать при создании и изменении экранов и модулей remote-control/web; не для команд ядра (essence-commands) и терминального меню (essence-menus)."
---

# Essence web

## Когда применять

Используйте этот skill для экранов, модулей, CSS и вендоренных файлов веб-панели (`remote-control/web/assets`) и для слушателя `remote-control/web/src/lib.rs` (крейт `essence-rc-web`). Панель — только слой экранов: вся логика — в командах ядра. Новое действие — сначала команда ядра (скилл `essence-commands`), экран TUI (скилл `essence-menus`), затем экран панели; паритет меню и панели обязателен.

Порядок работы: прочитайте `AGENTS.md`, соседний экран панели, его модель и тест, а также экран TUI того же раздела (`remote-control/tui/src/*.rs`) — панель повторяет его argv, вопросы и переходы. Таблица разделов и команд — `docs/remote-control.md`, разделы «Главное меню» и «Веб-панель».

## Устройство

Пути ниже — от `remote-control/web/assets/`.

- `index.html` подключает классические скрипты вендора (`vendor/xterm.js`, `vendor/xterm-addon-fit.js`, `vendor/qrcode.js`; глобальные `Terminal`, `FitAddon.FitAddon`, `qrcode`) и модуль `js/app.js`. `vendor/preact-htm.js` — ES-модуль (`html`, `render`, хуки `useState`, `useEffect`, `useRef`, …).
- `js/protocol.js` — клиент протокола v3 поверх WebSocket (`/ws`): запросы, события `log`/`activity`/`output`, терминал, переподключение через 1, 2, 5 с; токен возобновления — в `sessionStorage['essence-rc-resume']` (`RESUME_KEY`).
- `js/session.js` — вход: `session open` (`--remember-key`, код доступа, пароль запуска), разбор ответа, первый запуск и восстановление.
- `js/router.js` — маршрут `#/раздел/параметр` (`parse`, `format`, `navigate`); `consumeTicket` извлекает и сразу стирает `#ticket=` из адреса.
- `js/app.js` — каркас: меню `MENU`, шапка с индикаторами, журнал, `makeContext` (объект `ctx` экранов).
- `js/flows.js` — перенос `tui/src/confirm.rs` и кодов нод: `runConfirmed`, `reviewReply`, `decisionFlag`/`setFlag`/`clearFlag`, `isFailure`, `handleNodeCodes`, `nodeRequest`.
- `js/format.js` — форматирование значений и тексты ошибок (`errorMessage`), индикатор чужой команды, признак открытой панели.
- `js/dialogs.js` — модальные диалоги (`confirm`, `askSecret`, `ask`, `choose`, мультивыбор, окно операции с журналом); попадают в `ctx`.
- `js/ui.js` — компоненты (`Layout`, `Table`, `Card`, `Modal`, `Form`, `Field`, `SecretField`, `Checkbox`, `Picker`, `Toggle`, `CopyButton`, `Download`, `FileText`, `Pre`, `downloadText`).
- `js/terminal.js` — оверлей терминала нод (xterm.js и FitAddon).
- `js/screens/index.js` — `SCREENS`: маршрут → компонент. Экран — `function XScreen({ ctx, param })`, `param` — второй сегмент маршрута или `null`. Чистые функции экранов (argv, разбор ответов, переходы) — `screens/*-model.js`; общие хуки и кнопки — `screens/kit.js` (`useCommand`, `useCommands`, `useBusy`, `Action`, `Actions`, `Context`, `Back`, `Loaded`); общие действия клиентов, групп, шаблонов и подписок — `screens/shared.js`.

## Правила экрана

- **Данные — только командами.** `ctx.request(argv, { secrets, input, expect, operation })`, `ctx.call(...words)`, хуки `useCommand`/`useCommands`. Своих расчётов состояния в экране нет; после действия данные перечитываются командой.
- **Опасное действие** — только `ctx.runConfirmed(title, question, argv, { secrets, input })`: команда без `--yes` отвечает `confirmation_required` с планом, диалог показывает план и один вопрос, повтор — с `--yes --plan-token`; `plan_changed` показывается заново не более двух раз. Своих «вы уверены?» поверх плана нет. Коды `_required` превращаются в один вопрос на код и повтор команды с флагом (`decisionFlag`/`setFlag` — единственное соответствие код → флаг) или секретом.
- **Коды нод** (`missing_secret`, `host_key_changed`, `host_key_unknown`, `needs_setup`) — `ctx.nodeRequest(name, argv, review)`; оставшийся сбой `nodeRequest` сообщает сам, `ctx.failed()` после него не вызывается.
- **Сбои.** Текст ошибки ядра показывает один раз `ctx.request` (кроме планов и ожидаемых кодов `expect`); отказ от плана — не сбой (`ctx.isFailure`); сбой действия вне `nodeRequest` — `ctx.failed()` один раз.
- **Кнопки** — `Action` с тоном `view|create|change|danger` (те же значения, что цвета клавиш в меню: CYAN/GREEN/YELLOW/RED). `useBusy` блокирует кнопки экрана на время запроса.
- **Терминал** — `ctx.terminal(argv, title)` (`node shell`, `telegram menu`).
- **Файлы** — чтение `FileText` (содержимое уходит полем `input`), сохранение `downloadText` / `Download`; путей на машине пользователя панель не знает.
- **Навигация** — `ctx.navigate(name, param)`; исчезнувший объект (`not_found` или нет строки в списке) возвращает к списку раздела.
- Тексты — на русском; обработчики навешиваются компонентами, не inline-атрибутами разметки.

## Секреты и вход

- Секреты передаются только полем `secrets` запроса (`SecretField`, `ctx.askSecret`); не хранятся в `localStorage`/`sessionStorage`, URL и журнале, не попадают в argv.
- Единственное, что панель хранит, — токен возобновления в `sessionStorage` (`protocol.js`).
- `#ticket=` стирается из адреса сразу при загрузке (`consumeTicket`); код уходит только секретом `access-token` в `session open`.

## Вендор и сборка

- Сборки и npm нет: `package.json` — только `{"private":true,"type":"module"}` для `node --test`. Зависимости не добавляются.
- Файлы `assets/vendor` не правятся. Обновление — новая загрузка с записью версии, источника и SHA-256 в `assets/vendor/VENDOR.md`.
- CSP слушателя (`SECURITY_HEADERS` в `web/src/lib.rs`) — `default-src 'self'`, без внешних источников и inline-скриптов: никаких CDN, inline-`<script>`, `eval` и `new Function`. Стили inline допустимы (`style-src 'self' 'unsafe-inline'`), картинки — `self` и `data:`.
- Ассеты вшиваются в бинарник (`include_dir!`); отдаются только расширения из `content_type` в `web/src/lib.rs` (html, css, js, mjs, svg, json, woff2) — новое расширение добавляется туда.

## Тесты

- Логика выносится из компонентов в `screens/*-model.js`, `flows.js`, `format.js` и тестируется в `remote-control/web/tests-js/*.test.mjs` (`node:test`, `node:assert/strict`, без зависимостей; фикстуры и сценарии — по образцу тестов экранов `tui`).
- Протокол — `tests-js/protocol.test.mjs`, вход — `tests-js/session.test.mjs`; слушатель (заголовки, Host, Origin, WebSocket) — `remote-control/web/tests/listener.rs`; сеть демона (коды, пароль, токены, `--connect`) — `remote-control/bin/tests/daemon_network.rs`.
- Проверяется поведение (argv, флаги, переходы, коды), не тексты и не DOM.

## Проверка

- `node --test remote-control/web/tests-js/*.test.mjs` (Node 22);
- при изменении слушателя или ассетов — `cd remote-control && cargo test -p essence-rc-web --locked` (свои прогоны — с отдельным `CARGO_TARGET_DIR`);
- ручной смоук — `essence-rc web run`, открыть изменённый экран и пройти его действия.
