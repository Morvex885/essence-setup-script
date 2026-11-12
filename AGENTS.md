# AGENTS.md

Проект настройки прокси-сервера на ядре mihomo. Серверная часть — Bash в [setup-essence/](setup-essence/), общий слой — [common/](common/), серверные тесты — BATS в [tests/](tests/). Локальный клиент Remote Control (`essence-rc`) — Rust, Cargo workspace [remote-control/](remote-control/) (подробно — [remote-control/README.md](remote-control/README.md)). Общий обзор и протоколы: [README.md](README.md), [docs/essence.md](docs/essence.md), [docs/remote-control.md](docs/remote-control.md).

## Layout и границы

- [common/](common/) — независимый серверный слой. Никогда не импортирует `setup-essence/` или код из `remote-control/`.
- [setup-essence/](setup-essence/) — серверные скрипты; импортирует только `common/`.
- YAML-билдеры протоколов живут **только** в [common/protocols/](common/protocols/) (`vless-tcp.sh`, `vless-xhttp.sh`, `vless-grpc.sh`, `hy2.sh`, `iptables-dnat.sh`, `uri.sh`); их Rust-порты — в `remote-control/core/src/protocols/` с golden-паритетом (`remote-control/core/tests/protocols_golden.rs`). Не дублировать билдер в модуле.
- `remote-control/` — Cargo workspace из трёх крейтов:
  - `remote-control/core` (`rc-core`) — всё доменное: модель состояния, блокировки, команды, SSH-эффекты (russh), GitHub-источник, билдеры протоколов. Не зависит от терминала и фронтенда.
  - `remote-control/bin` (`essence-rc`) — единственный бинарник: clap-подобный парсер из каталога, разовый CLI, `serve` v2, запуск меню. Зависит и от `rc-core`, и от `essence-rc-tui`.
  - `remote-control/tui` (`essence-rc-tui`) — библиотека терминального меню (ratatui). **Не зависит от `rc-core` и не импортирует его** (проверяет `remote-control/tui/tests/boundary.rs`); с ядром говорит только через дочерний `serve --inner` по JSONL v2. Это гарантия того, что любой будущий фронтенд (веб-панель) использует тот же протокол.
- Встроенные шаблоны конфигов — `remote-control/core/templates/*.yaml` (`include_dir!`); серверный комплект (setup-essence + common + VERSION) встраивается в `rc-core::bundle`.

## Rust-конвенции (remote-control/)

- Сборка и тесты: `cd remote-control && cargo build --workspace --locked`, `cargo test --workspace --locked` (Cargo.lock не правится руками). Внешний cargo — `~/.cargo/bin/cargo`; локальные проверки — со своим `CARGO_TARGET_DIR`, чтобы не спорить с чужими сборками.
- Ошибки — `RcError{code,message,extra,exit}` (`remote-control/core/src/error.rs`): код-литерал из каталога, `usage`/`host_key_unknown`/`plan_changed`/`*_required` → выход 2, прочее → 1 (Telegram 3/4). Сообщения на русском, имена в «кавычках-ёлочках».
- Каталог команд один и служит парсеру, справке и справочной таблице: `remote-control/core/src/cli.rs` (`CATALOG`, `HELP`). Новая команда или флаг — только там плюс обработчик; алиасы не добавляются (`--name` — единый селектор, `subscription` вместо `sub`).
- Диспетчер `rc_core::dispatch::dispatch(argv, secrets, &mut Session)` — единая точка разового CLI и `serve`; ровно один конверт `{"id","ok","data"|"error","sync"?}` на вызов.
- Мутации состояния — только `Session::mutate(label, |state| …)` (блокировка → изменение → checkpoint/GitHub-flush). Никаких прямых записей конфигурации из обработчиков.
- Подтверждение — `confirmation::Plan::new(lines, extra)` + `plan.confirm(invocation)`: без `--yes` → `confirmation_required{plan,plan_token}`, изменившийся план → `plan_changed`. План строится до любых мутаций и удалённых эффектов (read-only preflight допустим).
- Секреты — только `rc_core::request_secrets::Secrets` (whitelist `password`, `current-password`, `vault-password`, `new-vault-password`, `script-password`, `access-token` — только `session open`): передаются полем `secrets` запроса serve или `--secrets-stdin`, хранятся в `Zeroizing`, не попадают в argv/env детей, журнал, `data` и extra.
- SSH — только через `RemoteTransport` (`remote-control/core/src/transport.rs`); производство — `SshTransport` на russh, тесты — `FakeTransport` со скриптованными шагами и журналом.
- Обработчик не спрашивает пользователя: нехватка решения — код `*_required` с extra (`choices`, `nodes`, отпечатки), вопрос задаёт фронтенд и повторяет команду с флагом или секретом.
- Журнал — `session.log(Level, text)`; serve превращает записи в события `{"event":"log"}`, разовый CLI печатает их с префиксами v1. C0/C1 вырезаются.
- UI-тексты и экраны меню — на русском, правила кадров/горячих клавиш — скилл [essence-menus](.agents/skills/essence-menus/SKILL.md); правила команд ядра — скилл [essence-commands](.agents/skills/essence-commands/SKILL.md).
- Тесты: unit внутри модулей; процессные — `remote-control/bin/tests/` (`cli_contract`, `serve_protocol`, `github_source`, `state_process`, `tui_e2e` — PTY-сценарии настоящего бинарника); golden-протоколы — `remote-control/core/tests/protocols_golden.rs`; loopback SSH — `ssh_wire.rs`. Сетевые тесты только loopback, реальный SSH — под `E2E_SSH`.

## Helpers Bash (серверная часть) — переиспользуй, не дублируй

Перед написанием новой обёртки проверь, нет ли её в `common/` или в модуле `setup-essence/modules/`.

**Вывод и интерактив** ([common/common.sh](common/common.sh)):
- `info` / `success` / `warn` / `error` — статусные сообщения с префиксами `[*] [✓] [!] [✗]`. Никаких голых `echo` для статусов. `error` сам делает `exit 1`.
- `confirm_yn "prompt" [Y|N]` — Y/N с дефолтом и валидацией, exit-код 0/1.
- `hyperlink url [text]` — OSC 8 кликабельная ссылка.
- `box_top` / `box_mid` / `box_bot` / `box_line` / `box_center`, `success_box`, `menu_select`, `toggle_select`, `review_frame` — рамки, меню, мультиселект, план.

**JSON** ([common/common.sh](common/common.sh)):
- `jq_r 'filter' file` — read с `-r` + trim `\r` (Windows CRLF).
- `jq_w 'filter' file` — write через временный файл с проверкой ошибок (атомарно).
- **Не** использовать прямой `jq -r ... > file`.

**Порты** ([common/common.sh](common/common.sh)): `is_port_free port`, `gen_free_port min max`.

**Обновления** ([common/common.sh](common/common.sh)): `check_update_start`, `latest_version`, `has_update`. Запросы к GitHub API с токеном — только через `_github_release_curl url`.

**Проверка SSH-параметров ноды** ([common/common.sh](common/common.sh)): `node_ssh_user_valid`, `node_ssh_host_valid` (`NODE_SSH_USER_RE`, `NODE_SSH_HOST_RE`) — использовать везде, не писать свои регулярные выражения.

**Зависимости** ([common/ensure-deps.sh](common/ensure-deps.sh)):
- `ensure_dep bin...` — проверить и при необходимости поставить через текущий PM (apt/dnf/yum/pacman/zypper/apk/brew/termux).
- `detect_pm`, `pkg_name_for bin`, `pm_install pkg` — низкоуровневые.

**TLS** ([common/cert.sh](common/cert.sh)):
- `ensure_acme_installed email` — установить acme.sh с Let's Encrypt.
- `ensure_cert identity webroot is_ip [cert_dir …]` — единственный владелец выдачи, установки и продления.
- `release_cert identity webroot [cert_dir …]` — снять сертификат и продление.
- `acme_select_email` / `acme_email_valid` — выбор и проверка ACME email.

**Пользователи listener'а mihomo** ([common/listener-users.sh](common/listener-users.sh)):
- `_sync_listener_users marker users_yaml` — заменить блок между маркерами в YAML конфига mihomo.
- `_build_vless_users_yaml marker` / `_build_hy2_users_yaml` — YAML-блоки пользователей.
- Маркер-блоки — единственный поддерживаемый способ менять пользователей листенера.

## Конвенции кода (серверная часть)

- UI и пользовательские сообщения — на русском; ANSI-цвета и префиксы — только из `common.sh`.
- `set -euo pipefail`: есть в установщиках (`install-essence.sh`); нет в основных entrypoints (`setup-essence.sh`). Не добавлять `set -e` в существующие entrypoints.
- Серверные модули `setup-essence/modules/` не задают вопросов, пока не дошли до своего меню; wildcard `*)` в `case` выводит ошибку, а не молча принимает ввод.
- Чувствительные tmp-файлы — под `umask 077`.
- Хост-разработка на Windows, цель — Debian/Ubuntu. CRLF может попасть в строки от `jq`/`read` — поэтому `jq_r`, а не `jq -r`.

## Тесты

- Rust: `cd remote-control && cargo test --workspace --locked` (см. правила выше).
- Всё сразу: `bash tests/run_tests.sh --all` — серверные BATS + `cargo test --workspace --locked`. Отдельно серверная часть: `--unit` / `--fuzz` / `--ci`. При первом клоне: `git submodule update --init --recursive` (BATS подмодули в `tests/lib/`).

Минимальная структура BATS-теста:
```bash
setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    source_module "<имя>.sh"
}
teardown() { teardown_test_env; }
```

Помощники:
- [tests/helpers/test_helper.bash](tests/helpers/test_helper.bash) — `setup_test_env`/`teardown_test_env`, `source_common`/`source_module`, fixtures.
- [tests/helpers/fuzz_helper.bash](tests/helpers/fuzz_helper.bash) — словари и генераторы.

Fixtures: [tests/fixtures/sample_config.json](tests/fixtures/sample_config.json) — конфиг для серверных BATS и Rust-теста `remote-control/core/src/model.rs`.

Правила:
- Новая функция валидации / парсер / энкодер — unit-тест; парсеры и энкодеры — ещё и fuzz.
- Тест упал → чинить код, а не подгонять ожидания теста.

## Перед сдачей задачи

- `bash -n <file>` для каждого изменённого `.sh` (для Claude Code — автоматически через `PostToolUse`-хук в [.claude/settings.json](.claude/settings.json)).
- Релевантные тесты проходят локально (Rust — cargo, серверные — BATS).
- Если правил `common/` — прогнать `bash tests/run_tests.sh --all`.
- В Claude Code: `/preflight` ([.claude/commands/preflight.md](.claude/commands/preflight.md)) прогоняет чек-лист разом.

## Релиз и CI

- Версия — [VERSION](VERSION) (бамп перед тегом); её читают `rc-core`, serve-hello и `self version`.
- CI: [.github/workflows/tests.yml](.github/workflows/tests.yml) — серверные BATS + `cargo test --workspace --locked` на трёх ОС.
- Релиз: [.github/workflows/release.yml](.github/workflows/release.yml) — тест → сборка 9 целей (включая `aarch64-linux-android` для Termux) → `essence-rc-<target>.tar.gz|.zip` + `SHA256SUMS`; серверный комплект собирает `tests/ci/build_release_tarball.sh` (в архив не входят `remote-control/`).

## Что не коммитить

В [.gitignore](.gitignore):
- `remote-control/target/`, артефакты сборки.
- `remote-control/.remote-data/` — данные прежней Bash-версии на машинах разработчиков; v2 хранит данные вне репозитория (каталог `essence-remote-control`, см. `ESSENCE_RC_DATA_DIR`).
- `.claude/settings.local.json` — личные permission-оверрайды. Общий `.claude/settings.json` (с хуком `bash -n`) и `.claude/commands/` коммитятся.
- `.claude/cache/` — кэш сабагента [mihomo-wiki](.claude/agents/mihomo-wiki.md), пересоздаётся автоматически.

## Чувствительные данные

- Пароли нод и секреты запросов — только в `Zeroizing`-структурах `rc-core` и поле `secrets`; не выводить в `info`/`warn`/журнал/`data`/extra и не передавать в argv дочерних процессов.
- Токены подписок — печатать только по явному запросу (просмотр клиента, ротация). Не логировать массово.
