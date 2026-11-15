# AGENTS.md

Проект настройки прокси-сервера на ядре mihomo. Сервер настраивается только из Remote Control (`essence-rc`) по SSH: клиент хранит желаемое состояние ноды, сам рендерит серверные файлы и применяет их через Bash-исполнитель [node-agent/](node-agent/); общий Bash-слой исполнителя — [common/](common/), его тесты — BATS в [tests/](tests/). Remote Control — Rust, Cargo workspace [remote-control/](remote-control/) (подробно — [remote-control/README.md](remote-control/README.md)). Общий обзор и протоколы: [README.md](README.md), [docs/essence.md](docs/essence.md), [docs/remote-control.md](docs/remote-control.md).

## Layout и границы

- [common/](common/) — независимый серверный слой (`common.sh`, `cert.sh`). Никогда не импортирует `node-agent/` или код из `remote-control/`.
- [node-agent/](node-agent/) — серверный исполнитель: неинтерактивный, применяет присланное (`apply.sh` + `steps/*.sh`); импортирует только `common/`.
- YAML-билдеры протоколов — только в `remote-control/core/src/protocols/` (снимки — unit-тесты `protocols/snapshots/*_cases.rs`). Не дублировать билдер в рендере.
- `remote-control/` — Cargo workspace из пяти крейтов:
  - `remote-control/core` (`rc-core`) — ядро: модель состояния, блокировки, каталог команд, `dispatch`, SSH-эффекты (russh), GitHub-источник, билдеры протоколов, серверный слой `core/src/server/` (рендер желаемого состояния ноды, `node apply`, встраивание исполнителя). Не зависит от терминала и фронтенда.
  - `remote-control/client` (`essence-rc-client`) — типы протокола v3, `Client`, `DaemonClient` (локальный сокет и WebSocket), `ScriptedClient`, точка подключения и запуск демона.
  - `remote-control/web` (`essence-rc-web`) — HTTP/TLS/WebSocket-слушатель и вшитые ассеты веб-панели (`remote-control/web/assets`).
  - `remote-control/tui` (`essence-rc-tui`) — библиотека экранов терминального меню (ratatui); зависит от `client`.
  - `remote-control/bin` (`essence-rc`) — единственный бинарник: демон, разовый CLI, меню, `web *`, автозапуск. Зависит от всех крейтов.
  - `tui`, `client` и `web` **не зависят от `rc-core`** (проверяет `remote-control/tui/tests/boundary.rs`); с ядром общаются только по протоколу v3 через демон.
- Встроенные шаблоны конфигов — `remote-control/core/templates/*.yaml` (`include_dir!`). Исполнитель (`node-agent/` + `common/common.sh`, `common/cert.sh`) встраивается в `server::bundle`; его хэш `agent_sha()` (SHA-256 от `MANIFEST`) — имя каталога на ноде `/root/essence-node/agent/<sha>/`, другая версия RC загружает свой каталог.

## Rust-конвенции (remote-control/)

- Сборка и тесты: `cd remote-control && cargo build --workspace --locked`, `cargo test --workspace --locked` (Cargo.lock не правится руками). Внешний cargo — `~/.cargo/bin/cargo`; локальные проверки — со своим `CARGO_TARGET_DIR`, чтобы не спорить с чужими сборками.
- Ошибки — `RcError{code,message,extra,exit}` (`remote-control/core/src/error.rs`): код-литерал из каталога, `usage`/`host_key_unknown`/`daemon_cert_unknown`/`plan_changed`/`*_required` → выход 2, прочее → 1 (Telegram 3/4). Сообщения на русском, имена в «кавычках-ёлочках».
- Каталог команд один и служит парсеру, справке и справочной таблице: `remote-control/core/src/cli.rs` (`CATALOG`, `HELP`). Новая команда или флаг — только там плюс обработчик; алиасы не добавляются (`--name` — единый селектор, `subscription` вместо `sub`).
- Диспетчер `rc_core::dispatch::dispatch(argv, secrets, input, agent_socket, &mut Session)` — единая точка всех команд демона; терминальная команда одна — `node shell` (`prepare_terminal` → `TerminalJob`). Ровно один конверт `{"id","ok","data"|"error","sync"?}` на вызов.
- Мутации состояния — только `Session::mutate(label, |state| …)` (блокировка → изменение → checkpoint/GitHub-flush). Никаких прямых записей конфигурации из обработчиков.
- Подтверждение — `confirmation::Plan::new(lines, extra)` + `plan.confirm(invocation)`: без `--yes` → `confirmation_required{plan,plan_token}`, изменившийся план → `plan_changed`. План строится до любых мутаций и удалённых эффектов (read-only preflight допустим) и строится заново внутри `Session::mutate` из того же состояния: отличие от согласованного — `Err(plan.changed(invocation))` (`plan_changed` с текущим планом и токеном). Всё, от чего зависит действие, но чего нет в argv (содержимое `input`, удалённое состояние), входит в `extra` — например, SHA-256 содержимого у `template import`.
- Секреты — только `rc_core::request_secrets::Secrets` (whitelist `password`, `current-password`, `vault-password`, `new-vault-password`, `script-password`, `access-token` — только `session open`): передаются полем `secrets` запроса протокола v3 или `--secrets-stdin` разового CLI, хранятся в `Zeroizing`, не попадают в argv/env детей, журнал, `data` и extra. Whitelist не расширяется: секретное значение новой команды передаётся под именем `password` (так `profile warp-license`, `telegram tag`).
- Файлы команд — токен `@file` в каталоге (флаг `--file PATH` обязателен) или `@file?` (необязателен: без флага поле `input` не передаётся, например `template check`): содержимое читает клиент и передаёт полем `input` (`rc_core::request_input::Input`); пути демону не передаются. CLI и меню читают и пишут файлы только через `essence_rc_client::files` (обычный файл без перехода по ссылке, до 1 МиБ, UTF-8; запись — атомарно, без подтверждения существующий файл не заменяется); веб-панель — через `readInputFile` (`web/assets/js/format.js`). Демон проверяет каждый запрос `dispatch::checked` до маршрутизации. Команды с флагом `CLIENT` выполняет сам клиент, с `LOCAL` — только локальные соединения.
- SSH — только через `RemoteTransport` (`remote-control/core/src/transport.rs`); производство — `SshTransport` на russh, тесты — `FakeTransport` со скриптованными шагами и журналом.
- Обработчик не спрашивает пользователя: нехватка решения — код `*_required` с extra (`choices`, `nodes`, отпечатки), вопрос задаёт фронтенд и повторяет команду с флагом или секретом.
- Журнал — `session.log(Level, text)`; демон превращает записи в события `{"event":"log"}` запросившему соединению, разовый CLI печатает их с префиксами `[*] [✓] [!] [✗]`. C0/C1 вырезаются. Ход долгой команды — не журнал, а живая строка `session.progress(percent, text)` (событие `{"event":"progress"}` только запросившему; образец — опрос `node apply`).
- UI-тексты и экраны — на русском, правила кадров/горячих клавиш — скилл [essence-menus](.agents/skills/essence-menus/SKILL.md); правила экранов веб-панели — скилл [essence-web](.agents/skills/essence-web/SKILL.md); правила команд ядра — скилл [essence-commands](.agents/skills/essence-commands/SKILL.md).
- Новое действие = команда ядра + экран в `remote-control/tui` + экран в `remote-control/web/assets/js/screens`.
- Серверные файлы ноды рендерит только `core/src/server/render.rs` (чистые функции, без сети и каталога данных). Изменение формата рендера при неизменной конфигурации увеличивает `RENDER_REVISION` — иначе применённые ноды не станут `pending`.
- Изменения на ноде идут только через `node apply` (план → подтверждение → исполнитель). Команда, меняющая профиль, ноду, клиентов, подключения, каскады или роли, к ноде не подключается: нода становится `pending`. Исключения, которые сами ходят на ноду: регистрация WARP (внутри `node apply` и `node warp-reregister`), `telegram restart|diagnostics|status`, публикация подписок (`subscription publish|publish-all|rotate|revoke` на хосте подписок).
- Новая возможность сервера = поле профиля (`model::Profile` + валидация) или роль ноды + рендер в `render.rs` + при необходимости шаг исполнителя `node-agent/steps/<фича>.sh` + экраны TUI и веб. Правила этого слоя — скилл [essence-server](.agents/skills/essence-server/SKILL.md).
- Тесты: unit внутри модулей (снимки билдеров — `core/src/protocols/snapshots.rs`, рендер ноды — `core/src/server/render/tests.rs`, `node apply` — `core/src/server/apply/tests.rs` на `FakeTransport`); процессные — `remote-control/bin/tests/` (`cli_contract`, `daemon_protocol`, `daemon_network`, `service_process`, `github_source`, `state_process`, `removed_commands`, `tui_e2e` — PTY-сценарии настоящего бинарника); клиент — `remote-control/client/src/tests.rs`, `remote-control/client/tests/listener_e2e.rs`; слушатель — `remote-control/web/tests/listener.rs`; loopback SSH — `ssh_wire.rs`; JS — `node --test remote-control/web/tests-js/*.test.mjs`. Сетевые тесты только loopback, реальный SSH — под `E2E_SSH`.

## Helpers Bash (серверная часть) — переиспользуй, не дублируй

Перед написанием новой обёртки в исполнителе проверь, нет ли её в `common/`, в `node-agent/steps/base.sh` (`agent_apt_wait`, `wait_active`, `install_file`, `tx_backup`) или в `node-agent/steps/progress.sh` (`agent_apt` — apt-get с процентом из `APT::Status-Fd`; `progress_span`, `progress_in`, `progress_detail` — процент и текущее действие в `status`).

**Вывод** ([common/common.sh](common/common.sh)):
- `info` / `success` / `warn` / `error` — статусные сообщения с префиксами `[*] [✓] [!] [✗]`. Никаких голых `echo` для статусов. `error` сам делает `exit 1` — в исполнителе не вызывается.

Больше в `common.sh` ничего нет: прежние помощники Bash-меню и RC (`jq_r`/`jq_w`, `register_exit_cleanup`, `_vis_len`) удалены, `$CONFIG_JSON` на ноде не существует.

**TLS** ([common/cert.sh](common/cert.sh)):
- `ensure_acme_installed email` — установить acme.sh с Let's Encrypt.
- `ensure_cert identity webroot is_ip [cert_dir …]` — единственный владелец выдачи, установки и продления.
- `release_cert identity webroot [cert_dir …]` — снять сертификат и продление.
- `cert_is_usable` — проверка цепочки и срока; `acme_email_valid` — проверка ACME email.

## Конвенции кода (серверная часть)

- Исполнитель (`node-agent/apply.sh`, `steps/*.sh`) не задаёт вопросов и не читает stdin (`exec </dev/null`); всё решено в RC и пришло в `spec.sh`, `files.list`, `remove.list`.
- `error` из `common.sh` не вызывать: он делает `exit 1` мимо записи статуса; этап возвращает ненулевой код, итог и откат пишет `finish`.
- Пакеты ставятся только `agent_apt <от> <до> install|update …` (`steps/progress.sh`), не голым `apt-get`: его процент ведёт долю текущего шага. Долгий шаг сообщает действие `progress_detail "…"` (имена пакетов, доменов и постоянные тексты, без секретов) и движется по своей доле `progress_span`/`progress_in`; новая фича получает вес в `progress_feature_weight`.
- Шаги идемпотентны: повторный запуск той же операции приводит к тому же состоянию (проверка перед установкой, `mkdir -p`, отметки вроде `.essence-site`).
- Управляемые файлы и бинарник mihomo меняются только в транзакции: её открывает этап `config` (резервная копия → установка → проверки → перезапуск), она остаётся открытой через `firewall` и проверку `cleanup` и закрывается записью `committed`; сбой до неё — откат файлов, бинарника, правил UFW этой операции и служб (`rolled_back`, неполный — `rollback_failed` с сохранённым `backup/`). Всё, что не откатывается (пакеты, сертификаты, сборка компонентов), делается до транзакции и только добавляет; необратимая очистка (`<фича>_remove`, освобождение сертификатов, удаление старых операций) — только в `cleanup_committed` после `committed`.
- `apply.sh` экспортирует `NEEDRESTART_MODE=l NEEDRESTART_SUSPEND=1`: needrestart не перезапускает службы посреди применения; новые apt-вызовы этого не переопределяют.
- Фича исполнителя (`steps/<фича>.sh`) — хуки `<фича>_prepare|activate|rollback|deactivate|remove`: `deactivate` останавливает снимаемую фичу в `config`, пока её файлы на месте; `rollback` трогает фичу, только если транзакция её трогала; `remove` — только в `cleanup_committed` после фиксации и удаляет лишь то, что создал Essence (учётные записи — по своему списку, например `/root/essence-node/telegram-users`). Метка `/root/essence-node/features/<фича>` из `prepare` позволяет `adopt_feature_leftovers` снять остатки незафиксированной фичи.
- `nginx.conf` не редактировать: свои настройки — отдельные файлы (`conf.d/`, `sites-available/`, `modules-enabled/`).
- Все абсолютные пути ноды — через префикс `$R` (`${ESSENCE_NODE_ROOT:-}`), чтобы BATS работал в каталоге теста.
- Чувствительные tmp-файлы — под `umask 077` (исполнитель задаёт его сам).
- Хост-разработка на Windows, цель — Debian/Ubuntu. [.gitattributes](.gitattributes) держит LF для `*.sh` и `remote-control/core/src/server/assets/**` (они уходят на ноду как есть); новый каталог встроенных серверных файлов добавляется туда же. CRLF может попасть в строки от `read` — срезать `\r` при разборе вывода команд.
- Исполнитель и `common/` — Bash 4+ (Debian/Ubuntu), кроме `node-agent/steps/progress.sh`: он совместим с Bash 3.2 (секунда записи — по `$SECONDS`, без `printf '%(…)T'`); клиентские скрипты (`install-essence-rc.sh`, `tests/run_tests.sh`, `tests/helpers/`) — Bash 3.2.

## Тесты

- Rust: `cd remote-control && cargo test --workspace --locked` (см. правила выше).
- Веб-панель: `node --test remote-control/web/tests-js/*.test.mjs` (Node 22, без зависимостей).
- Всё сразу: `bash tests/run_tests.sh --all` — BATS (`tests/unit`, `tests/fuzz`) + `cargo test --workspace --locked`. Отдельно BATS: `--unit` / `--fuzz` / `--ci`. При первом клоне: `git submodule update --init --recursive` (BATS подмодули в `tests/lib/`).

Минимальная структура BATS-теста:
```bash
setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
}
teardown() { teardown_test_env; }
```

Исполнитель тестируется запуском `apply.sh` целиком (`tests/unit/node_agent.bats`, фича Telegram — `tests/unit/telegram.bats`): копия `node-agent/` и `common/` в каталог теста, заглушки команд (`apt-get`, `systemctl`, `ufw`, `nginx`, `ss`, `mihomo` …) через `PATH`, корень ноды — `ESSENCE_NODE_ROOT`. Эти тесты только для Linux с Bash 4+ в `PATH`: `require_executor_env` в `setup` пропускает их с сообщением на других системах.

Помощники:
- [tests/helpers/test_helper.bash](tests/helpers/test_helper.bash) — `setup_test_env`/`teardown_test_env`, `require_executor_env`, `source_common`.
- [tests/helpers/fuzz_helper.bash](tests/helpers/fuzz_helper.bash) — словари и генераторы.

Fixtures: [tests/fixtures/sample_config.json](tests/fixtures/sample_config.json) — конфиг для Rust-теста `remote-control/core/src/model.rs`; [tests/fixtures/tproxy-server/](tests/fixtures/tproxy-server/) — юниты upstream для `telegram.bats`.

Отрендеренные конфиги нод проверяются настоящими `mihomo -t` и `nginx -t` (job `render-check`): `dump_representative_renders` в `core/src/server/render/tests.rs` пишет топологии при `ESSENCE_RENDER_DUMP`, `tests/ci/validate_render.sh` их проверяет.

Правила:
- Новая функция валидации / парсер / энкодер — unit-тест; парсеры и энкодеры — ещё и fuzz.
- Правила живой проверки ввода (имя и подсказка `suggest_name`, домен, порт, email, версия mihomo) существуют в трёх копиях — ядро (`core/src/validation.rs`), меню (`tui/src/nodes.rs`) и веб-панель (`web/assets/js/screens/profiles-model.js`); их сверяют общие векторы [remote-control/core/tests/validation_vectors.json](remote-control/core/tests/validation_vectors.json) (тесты `shared_validation_vectors` в `core/src/validation.rs` и `tui/src/nodes.rs`, `web/tests-js/validation.test.mjs`). Правило меняется во всех трёх копиях и в векторах.
- Тест упал → чинить код, а не подгонять ожидания теста.

## Перед сдачей задачи

- `bash -n <file>` для каждого изменённого `.sh`.
- Релевантные тесты проходят локально (Rust — cargo, исполнитель и `common/` — BATS).
- Если правил `node-agent/` или `common/` — прогнать `bash tests/run_tests.sh --all` (правка меняет `agent_sha()`: при следующем `node apply` ноды получат новый каталог исполнителя).

## Релиз и CI

- Версия — [VERSION](VERSION) (бамп перед тегом); её читают `rc-core`, hello демона и `self version`.
- CI: [.github/workflows/tests.yml](.github/workflows/tests.yml) — BATS (`tests/unit`, `tests/fuzz`; job `test` — обязательная проверка) + `cargo test --workspace --locked` на трёх ОС + OpenSSH-сценарий (`tests/ci/ssh_e2e.sh`) + рендер нод против mihomo v1.19.18 и nginx (job `render-check`, не обязательная) + сборка целей релиза + JS-тесты веб-панели (job `web-js-test`).
- Релиз: [.github/workflows/release.yml](.github/workflows/release.yml) — тест → сборка 9 целей (включая `aarch64-linux-android` для Termux) → `essence-rc-<target>.tar.gz|.zip` + `SHA256SUMS`. Отдельного серверного архива нет: исполнитель встроен в бинарник.

## Что не коммитить

В [.gitignore](.gitignore):
- `remote-control/target/`, артефакты сборки.
- `remote-control/.remote-data/` — данные прежней Bash-версии на машинах разработчиков; v2 хранит данные вне репозитория (каталог `essence-remote-control`, см. `ESSENCE_RC_DATA_DIR`).
- `.claude/settings.local.json` — личные permission-оверрайды.
- `.claude/cache/` — кэш сабагента [mihomo-wiki](.agents/agents/mihomo-wiki.md), пересоздаётся автоматически.

## Чувствительные данные

- Пароли нод, ключи нод (`reality-key`, `awg-key`, `warp-key`, `telegram-secret`, `telegram-tag`) и секреты запросов — только в `Zeroizing`-структурах `rc-core` и поле `secrets`; не выводить в `info`/`warn`/журнал/`data`/extra и не передавать в argv дочерних процессов. На ноду ключи попадают только файлами каталога операции (`upload_private`, 0700/0600), исполнитель удаляет `files/` и `backup/` после итога; при `rollback_failed` `backup/` (в нём ключи и пароли) остаётся на ноде для ручного восстановления, и cleanup его не удаляет.
- Токены подписок — печатать только по явному запросу (просмотр клиента, ротация). Не логировать массово.
- Коды доступа и токены возобновления веб-панели существуют только в памяти демона (проверка по SHA-256; действующий код панели держится до её остановки, чтобы `web link` его повторял); не выводить их в журнал. Ссылку с `#ticket=` печатают только `web link`, `web open` и `web run`.
