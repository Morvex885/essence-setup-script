---
name: essence-commands
description: "Правила команд ядра remote-control на Rust: каталог в remote-control/core/src/cli.rs, обработчики, коды ошибок RcError и решения, подтверждение планом, секреты и входные данные, журнал, node apply, протокол v3 демона, тесты. Использовать при добавлении или изменении команд rc-core и функций, которые они вызывают; не для экранов remote-control/tui (essence-menus) и веб-панели (essence-web); рендер и исполнитель ноды — essence-server."
---

# Essence commands

## Когда применять

Любое изменение поведения remote-control — это команда ядра: `сущность действие --флаги` → JSON `{ok,data|error}`. Экраны TUI (`remote-control/tui`) и веб-панель (`remote-control/web/assets/js/screens`) только вызывают команды. Используйте этот skill для новых и изменяемых команд в `remote-control/core`, а также протокола v3 демона (`remote-control/client/src/protocol.rs`, `remote-control/bin/src/daemon/`). Правила экранов — skills `essence-menus` и `essence-web`.

Порядок работы: прочитайте `AGENTS.md`, `remote-control/README.md`, соседние команды того же существительного и их тесты. Новое действие = команда + экран в TUI + экран в веб-панели (скиллы `essence-menus`, `essence-web`): сначала команда ядра с тестами (`remote-control/core`, `remote-control/bin/tests`), затем экраны в `remote-control/tui` и `remote-control/web/assets/js/screens`.

## Где лежит команда

Всё в `remote-control/` (Cargo workspace):

| Место | Содержимое |
|---|---|
| `remote-control/core/src/cli.rs` | Каталог `CATALOG`: существительное → глагол → токены флагов, разрешённые секреты, флаги (`NOSESSION`, `TTY`, `LOCAL`, `CLIENT`) и входные данные `@имя`. Один каталог служит парсеру, справке `--help` и проверке грамматики |
| `remote-control/core/src/dispatch.rs` | `dispatch(argv, secrets, input, agent_socket, &mut Session)` — единый диспетчер команд демона; `prepare_terminal` — подготовка терминальной команды `node shell` (`TerminalJob`); маршрутизация по (noun, verb); `Session::mutate` |
| `remote-control/core/src/nodes/`, `server/`, `clients/`, `subscription/`, `telegram/` | Обработчики по доменам: `node`, `conn`; `node apply`, `node warp-reregister`, `profile`, `cascade` (рендер и исполнитель — скилл `essence-server`); `group`, `template`, `client`, `generate`; `subscription`; `telegram` |
| `remote-control/core/src/github/commands.rs` | `source *` (локальный источник и GitHub) |
| `remote-control/core/src/self_manage.rs` | `self *` |
| `remote-control/core/src/request_input.rs` | `Input` — входные данные запроса (содержимое файлов, `Zeroizing`) |
| `remote-control/core/src/terminal.rs` | `TerminalJob` — подготовленная терминальная команда (только `node shell`) |
| `remote-control/bin/src/main.rs`, `oneshot.rs` | Разовый CLI: подключение к демону, неявный `session open`, скрытый ввод секретов, чтение `--file`, `CLIENT`-команды, человекочитаемый рендерер |
| `remote-control/bin/src/remote.rs` | `--connect` и закрепление сертификата удалённого демона |
| `remote-control/bin/src/daemon/` | Демон: соединения, очередь, авторизация, `daemon *`/`web *` |
| `remote-control/bin/src/webcmd.rs`, `service.rs` | `web run`/`web open`, автозапуск веб-панели |
| `remote-control/client/` | Протокол v3, `DaemonClient`, `ScriptedClient` |

Новая команда = строка `spec(...)` в `CATALOG` (+ строка `HELP`, если новый флаг или команда меняют справку) + `match`-ветвь в `route` + обработчик. Алиасы не заводятся: `--name` — единый селектор объекта (`conn`/`telegram`/`subscription host` — нода, `profile`/`cascade` — профиль и каскад, `subscription show|publish|rotate|revoke` — клиент), связи — `--node` (у `client connections|nodes|awg-config`), `--profile` (у `node add|profile|apply`), `--group`, `--client`. `generate` — bare-noun. Глобальные `--json --yes --plan-token --help` разрешены каждой команде неявно.

Токены каталога: `name=` — флаг со значением (повтор → `usage`); `name` — булев; `name+` — повторяемый; `provision-keys=` и т.п. — значение-выбор; `@имя` — входные данные (клиент читает файл `--имя PATH`, флаг обязателен; демон получает содержимое `input.имя`); `@имя?` — необязательные входные данные (без флага клиент не передаёт поле, `Invocation::input_optional`; так `template check`, где вместо файла можно указать `--name`, и `cascade add`, где файл с URI — один из двух видов выхода). Секреты команды перечислены отдельным полем spec. Флаги: `NOSESSION` — выполняется без открытой сессии; `TTY` — нужна консоль (только `node shell`; без неё — `tty_required`); `LOCAL` — принимается только с локального сокета (сетевым соединениям → `local_only`); `CLIENT` — выполняет клиент (запрос демону → `usage` «Команда выполняется на стороне клиента.»). Правило выбора: эффект на файлах машины пользователя → `@`-вход или `CLIENT`; управление машиной демона (слушатель, остановка) → `LOCAL`.

## Контракт обработчика

- **Никаких вопросов.** В `remote-control/core` нет чтения stdin/stdout и меню: нехватка решения — код `*_required` с extra. Терминальная команда одна — `node shell`: подготовка в `prepare_terminal` (поиск, подключение) возвращает `TerminalJob`; демон выполняет его на терминальном потоке запросившего соединения. Обработчик консоль не трогает; без поля `terminal` в запросе — `tty_required`.
- **Результат** — `Ok(serde_json::Value)` (объект или массив). Человекочитаемый вывод строит общий рендерер `remote-control/bin`, обработчик его не форматирует; поля выводятся в порядке объявления.
- **Ошибка** — `Err(RcError::new(code, message))`, при необходимости `.with_extra(key, value)` (extra попадает в `error` конверта) и `.with_exit(n)` (только Telegram 3/4). Код — литерал из списка в `docs/remote-control.md` («Коды ошибок») плюс `error.rs::exit_code_for`: `usage`, `host_key_unknown`, `daemon_cert_unknown`, `plan_changed` и `*_required` → выход 2, прочее → 1.
- **Секреты** — только `secrets.get(name)` из `rc_core::request_secrets::Secrets` (whitelist `password`, `current-password`, `vault-password`, `new-vault-password`, `script-password`, `access-token`). Whitelist не расширяется: секретное значение новой команды приходит под именем `password` (`profile warp-license`, `telegram tag`). Значения не покидают `Zeroizing`, не попадают в argv дочерних процессов, журнал, `data`/extra и Debug-вывод. Команда принимает только свои секреты (`dispatch` проверяет).
- **Входные данные** — только `input.get(name)` (`rc_core::request_input::Input`, `Zeroizing`); имя объявлено `@name` в каталоге; содержимое не попадает в журнал и ответ.
- **Мутации** — только `session.mutate(label, |state| …)`: одна блокировка, изменение, checkpoint (локальный манифест) или GitHub-flush (снимок → commit → push). Прямые записи `config.json`/`secrets.json` из обработчиков запрещены. Частично завершённая мутация возвращает `partial{…}`.
- **SSH и удалённые эффекты** — только через `RemoteTransport` (`transport.rs`): `connect` (пины хост-ключей, `host_key_unknown/mismatch/changed` с отпечатками), `exec`, `upload`/`upload_private` (каталог одной SFTP-операцией; `upload_private` — 0700/0600 для данных с ключами), `interactive` (PTY). Производство — `SshTransport` (russh), тесты — `FakeTransport`.
- **Желаемое состояние ноды.** Команда, меняющая профиль, ноду, клиентов, подключения, каскады или роли (хост подписок, Telegram), на сервере ничего не делает: нода становится `pending` (`server::render::status`), применяет её только `node apply`. Новые ключи и параметры — `server::keys::ensure_generated` внутри той же `session.mutate`. Исключения, которые сами подключаются к нодам: регистрация WARP, `telegram status|restart|diagnostics`, публикация подписок.
- **Журнал** — `session.log(Level::Info|Success|Warn, text)`: демон превращает записи в события `log` запросившему соединению и `activity log` наблюдателям до ответа, разовый CLI печатает их с префиксами `[*] [✓] [!] [✗]`. `error()`-аналогов и `exit` в обработчиках нет — команда возвращает `RcError`. Ход долгой команды — не журнал, а живая строка `session.progress(percent, text)` (событие `progress` только запросившему; образец — опрос `node apply`, `server/apply.rs`): журнал получает строку на смену этапа и сбои, живая строка — процент, этап, действие и время раз в секунду.
- **Сессия.** Сессия ядра одна на демон; авторизацию соединений ведёт демон (`session open`), обработчик получает уже открытую сессию.

## Решения через коды `_required`

Если операции нужен ответ, который раньше спрашивался посреди работы, команда получает флаг или секрет, а при их отсутствии отвечает `RcError` с кодом `…_required` и extra с данными для вопроса, ничего не меняя: `key_provisioning_required{"nodes":[…]}`, `storage_mode_required{"choices":[…]}`, `existing_config_action_required{"choices","remote_counts","local_counts"}`, `repo_create_required`, `repo_private_required`, `cache_skip_required`, `target_replace_required{"repo","tracked_files"}`, `new_vault_password_required`, `vault_password_required`, `github_auth_required` и т.д. Фронтенд показывает один вопрос на код и повторяет команду с флагом; секрет передаётся полем `secrets`, не флагом.

## Подтверждение

Опасное действие (удаление, отзыв, смена группы, перенос, перезапись, действия на серверах) строит план и вызывает `Plan::new(lines, extra).confirm(invocation)?` после проверок и до любых мутаций/удалённых изменений:

1. `lines` — строки плана на русском: операция, последствия, все цели; без секретов;
2. `extra` — строка, входящая в токен (дайджесты рендера нод и расхождения файлов у `node apply`, SHA-256 содержимого `input`), когда действие зависит от того, чего нет в argv: удалённого состояния или входных данных (`template import` — SHA-256 файла);
3. без `--yes` — `confirmation_required{plan,plan_token}`; `--yes --plan-token T` при изменившемся плане — `plan_changed` с новым планом. До согласия допустим только read-only preflight (включая SSH-чтение).
4. План строится одной функцией из состояния (`fn x_plan(state, …) -> Plan`) и строится заново первым шагом внутри `session.mutate`: между согласием и блокировкой состояние могло измениться. Отличие от согласованного плана — `Err(plan.changed(invocation))` (`plan_changed` с текущим планом и `plan_token`), ничего не меняя. Проверку под блокировкой выносят в функцию (`delete_planned`, `groups_planned`, `import_planned`, `rename_recheck`, `trust_recheck`), чтобы тест вызвал её после изменения состояния.

`node apply` (`server/apply.rs`) — образец команды с удалёнными эффектами на многих нодах: проба каждой ноды (read-only SSH: ОС, целостность исполнителя, порты, хэши применённых файлов, незавершённая операция) → один план на все ноды (`extra` — дайджесты и расхождения) → регистрация WARP → блокировка: повторный рендер (иное — `plan_changed`) и запись `node.operation` → загрузка исполнителя (если нужно) и каталога операции → отвязанный запуск (`systemd-run`) → опрос статуса с переподключением → запись `applied` (или снятие `operation`). Ноды независимы: недоступная или сбойная нода — запись `failed[]` `{name, stage, code, message, port?}`, остальные продолжают; итог со сбоями — `partial{applied,failed,unchanged}`. Явно названная нода с ошибкой конфигурации (`domain_required`) отвечает этим кодом до плана. Рендер, форматы и исполнитель — скилл `essence-server`.

Telegram Web Proxy — роль ноды (`core/src/telegram/`): `set|remove|rotate-secret|tag` меняют только конфигурацию и хранилище секретов, ставит роль `node apply`. Секрет и тег попадают на ноду только файлом (`mtproxy.env` в рендере), не через argv или окружение удалённых команд; тег приходит секретом запроса `password`. Планы `remove` и `rotate-secret` строятся заново под блокировкой мутации (`planned`, как `node warp-reregister`): изменённая после подтверждения роль даёт `plan_changed`. `status` — read-only проба нод (не больше четырёх одновременно), `restart` — одна нода по плану (нода и домен роли), который подтверждается до подключения; `diagnostics` — одна нода, вывод маскируется (`redact`).

## Протокол v3

Клиенты (меню, разовый CLI, браузер, `--connect`) говорят с демоном по протоколу v3: локально — JSON-строки через сокет или канал, по сети — WebSocket, один объект на кадр. Демон шлёт hello `{"event":"hello","protocol":3,"version":V,"origin":…}`; запрос — `{id,argv,secrets?,input?,env?,terminal?}`; до ответа идут события (`log`, `progress`, `terminal`, `output`, `access`, `activity`); ответ ровно один: `{"id","ok":true,"data","sync"?}` или `{"id","ok":false,"error":{…},"exit":N}`. Каждый запрос — и `help`, `daemon *`, `web *` — демон до маршрутизации проверяет `dispatch::checked` (транспортные флаги, секреты, `input`); новый прямой маршрут демона эту проверку не обходит. Чтение соединения никогда не ждёт: ввод терминала — `terminal::InputSender::send` без ожидания (до 64 событий и 4 МиБ; переполнение закрывает терминал), исходящие события и ответы — до 16 МиБ на соединение, дальше соединение закрывается. Код — `remote-control/client/src/protocol.rs` + `remote-control/bin/src/daemon/conn.rs` + `remote-control/web/assets/js/protocol.js`. Протокол меняется только вместе с `remote-control/bin/tests/daemon_protocol.rs`, `remote-control/bin/tests/daemon_network.rs`, `remote-control/client/src/tests.rs`, `remote-control/web/tests-js/protocol.test.mjs` и разделом «Протокол v3» в `docs/remote-control.md`.

## Тесты

- Unit-тесты обработчиков — в `#[cfg(test)]` модулях `remote-control/core` на `FakeTransport` и `crate::nodes::testing::{session, invocation, fingerprint, Journal}`; `node apply` — `server/apply/tests.rs` (`tokio::time::pause`).
- Процессные — `remote-control/bin/tests/`: `cli_contract` (грамматика, коды выхода, жизненный цикл подтверждения, секреты), `daemon_protocol` (протокол на локальном сокете), `daemon_network` (сеть, коды, токены, `--connect`), `service_process` (автозапуск), `github_source` (git/gh на локальных репозиториях), `state_process` (блокировки), `removed_commands` (тексты каталога, справки, TUI и веб-ассетов не ссылаются на удалённые команды), `tui_e2e` (настоящий бинарник в PTY).
- Снимки билдеров — unit-тесты в `core/src/protocols/*` (`protocols/snapshots.rs`, случаи `protocols/snapshots/*_cases.rs`); рендер ноды — тесты `core/src/server/render.rs` (`server/render/tests.rs`).

Каждая новая или изменённая команда получает: нет решения → код `_required` с extra и состояние без изменений (проверка отпечатком каталога данных); без `--yes` → `confirmation_required` и состояние без изменений; успех → данные и состояние; сбой посередине → откат или `partial`; секреты не появляются в argv, журнале и выводе. Тесты не открывают реальный SSH (только loopback `ssh_wire` и env-гейт `E2E_SSH`).

## Документация

Каталог команд, коды и протокол — `docs/remote-control.md` и справка самого бинарника (`essence-rc help`, `essence-rc <noun> --help` — генерируется из `HELP` в `cli.rs`). Новая команда, флаг, код ошибки или поле данных обновляют `cli.rs`, `docs/remote-control.md` (каталог, коды и, если есть экран, разделы «Главное меню» и «Веб-панель»). Архитектура и проверки — `remote-control/README.md`.

## Проверка

- `cd remote-control && cargo test --workspace --locked` (свои прогоны — с отдельным `CARGO_TARGET_DIR`);
- `cargo clippy --workspace --all-targets --locked` без ошибок;
- для экранов нового действия — тест в `remote-control/tui` на `ScriptedClient`/`ScriptedUi` (argv по клавишам, подтверждение, коды → флаги), сценарий реального бинарника при изменении запуска.
- для изменённых экранов веб-панели — `node --test remote-control/web/tests-js/*.test.mjs`.
