# AGENTS.md

Bash-проект для настройки прокси-сервера на ядре mihomo. Серверная часть в [setup-essence/](setup-essence/), локальная — в [remote-control/](remote-control/), общий слой — в [common/](common/), тесты — BATS в [tests/](tests/). Общий обзор и протоколы: [README.md](README.md), [docs/essence.md](docs/essence.md), [docs/remote-control.md](docs/remote-control.md).

## Layout и границы импорта

- [common/](common/) — независимый слой. Никогда не делает `source` из `setup-essence/` или `remote-control/`.
- [setup-essence/](setup-essence/) и [remote-control/](remote-control/) импортируют из `common/`, но **не друг из друга**.
- YAML-билдеры протоколов живут **только** в [common/protocols/](common/protocols/) (`vless-tcp.sh`, `vless-xhttp.sh`, `vless-grpc.sh`, `hy2.sh`, `iptables-dnat.sh`, `uri.sh`). Не дублировать билдер в модуле.
- [remote-control/modules/](remote-control/modules/) — **ядро команд без вопросов пользователю**: `cli.sh` (разбор, `rc_dispatch`, конверт, коды выхода, секреты, справка, рендерер), `session.sh`, `source.sh`, `serve.sh` (протокол JSON-строк) и команды в `cmd_core.sh` (`help`, `status`, `session`, `source`, `self`), `cmd_nodes.sh` (`node`, `conn`, `awg`, `telegram`), `cmd_clients.sh` (`client`, `group`, `template`, `generate`, `sub`). Новый `cmd_*.sh` не заводится. Правила — скилл [essence-commands](.agents/skills/essence-commands/SKILL.md).
- [remote-control/tui/](remote-control/tui/) (`main.sh`, `client.sh`, `system.sh`, `nodes.sh`, `clients.sh`) — слой экранов отдельного процесса. Импортирует **только** `common/` и `tui/`, к ядру обращается **только** через `tui_call` (запросы к `serve`), модули ядра, `config.json` и функции `core_*` не использует (проверяет `tests/unit/tui.bats`). Правила — скилл [essence-menus](.agents/skills/essence-menus/SKILL.md).
- **Новое действие = команда + экран.** Логика — в команде ядра с тестом `run_cmd`; экран только вызывает её и показывает результат. Каталог команд — [docs/remote-control.md](docs/remote-control.md#командная-строка-cli).
- Парные `subscription.sh` в [setup-essence/modules/subscription.sh](setup-essence/modules/subscription.sh) и [remote-control/modules/subscription.sh](remote-control/modules/subscription.sh) — разные роли (серверный nginx vs локальное управление токенами). Прямой зависимости нет — менять одно не значит автоматически менять другое.

## Helpers — переиспользуй, не дублируй

Перед написанием новой обёртки проверь, нет ли её в `common/` или соответствующем модуле.

**Вывод и интерактив** ([common/common.sh](common/common.sh)):
- `info` / `success` / `warn` / `error` — статусные сообщения с префиксами `[*] [✓] [!] [✗]`. Никаких голых `echo` для статусов. `error` сам делает `exit 1`.
- `confirm_yn "prompt" [Y|N]` — Y/N с дефолтом и валидацией, exit-код 0/1.
- `hyperlink url [text]` — OSC 8 кликабельная ссылка (на неподдерживающих терминалах деградирует молча).
- `box_top` / `box_mid` / `box_bot` / `box_line` / `box_center`, `success_box`, `toggle_select` — рамки и интерактивный мультиселект.

**JSON** ([common/common.sh](common/common.sh)):
- `jq_r 'filter' file` — read с `-r` + trim `\r` (Windows CRLF).
- `jq_w 'filter' file` — write через временный файл с проверкой ошибок (атомарно).
- **Не** использовать прямой `jq -r ... > file` в коде, читающем/пишущем `config.json` — потеряется CRLF-trim и атомарность.

**Порты** ([common/common.sh](common/common.sh)): `is_port_free port`, `gen_free_port min max`.

**Обновления** ([common/common.sh](common/common.sh)): `check_update_start`, `latest_version`, `has_update`. Запросы к GitHub API с токеном — только через `_github_release_curl url` (токен уходит конфигом через stdin, не в argv).

**Проверка SSH-параметров ноды** ([common/common.sh](common/common.sh)): `node_ssh_user_valid`, `node_ssh_host_valid` (шаблоны `NODE_SSH_USER_RE`, `NODE_SSH_HOST_RE`). Логин и адрес ноды проверяются ими везде — и при `node add`, и при загрузке сохранённой ноды; не писать свои регулярные выражения.

**Зависимости** ([common/ensure-deps.sh](common/ensure-deps.sh)):
- `ensure_dep bin...` — проверить и при необходимости поставить через текущий PM (apt/dnf/yum/pacman/zypper/apk/brew/termux).
- `detect_pm`, `pkg_name_for bin`, `pm_install pkg` — низкоуровневые.

**TLS** ([common/cert.sh](common/cert.sh)):
- `ensure_acme_installed email` — установить acme.sh с Let's Encrypt.
- `ensure_cert identity webroot is_ip [cert_dir …]` — единственный владелец выдачи, установки и продления: HTTP-01 через webroot (для IP — shortlived профиль), при ошибке откатывает файлы и регистрации.
- `release_cert identity webroot [cert_dir …]` — снять сертификат и связанную настройку продления.
- `acme_select_email` / `acme_email_valid email` — выбор и проверка ACME email.

**Пользователи listener'а mihomo** ([common/listener-users.sh](common/listener-users.sh)):
- `_sync_listener_users marker users_yaml` — заменить блок между маркерами в YAML конфига mihomo.
- `_build_vless_users_yaml marker` — из stdin `username uuid` → YAML-блок (+ `flow: xtls-rprx-vision` для TCP).
- `_build_hy2_users_yaml` — из stdin `username password` → блок Hysteria2.
- Маркер-блоки — **единственный** поддерживаемый способ менять пользователей листенера.

**SSH/SCP** (только в [remote-control/](remote-control/)) — [remote-control/modules/ssh.sh](remote-control/modules/ssh.sh):
- `ssh_run [opts] -- cmd...` — SSH с поддержкой пароля через `SSH_ASKPASS`, timeout 30s, корректный `StrictHostKeyChecking`.
- `scp_run args...` — SCP с теми же параметрами безопасности.
- `ssh_probe` — одна проверка SSH загруженной ноды без вопросов и повторов: `missing_secret`, `needs_setup`, `host_key_changed` (с отпечатками) или `remote_failed`.
- `upload_scripts` — загрузка `setup-essence.sh`, `modules/`, `common/` на сервер с `chmod +x`.

**Ядро команд** (только в [remote-control/](remote-control/), [state.sh](remote-control/modules/state.sh), [cli.sh](remote-control/modules/cli.sh)):
- `rc_fail CODE MSG [EXTRA]` — ошибка команды: код из списка (`docs/remote-control.md`), сообщение, JSON-поля EXTRA. Решение, которое раньше спрашивалось посреди операции, — код `…_required` с EXTRA, а не вопрос.
- `rc_confirm_gate` — подтверждение опасного действия: по `CORE_PLAN_LINES` (и `CORE_PLAN_EXTRA`, `CORE_PLAN_DATA`) без `--yes` отвечает `confirmation_required` с `plan` и `plan_token`, при изменившемся плане — `plan_changed`.
- `rc_secret NAME` — значение секрета запроса; секреты не попадают в argv внешних программ, журнал и `CLI_DATA`.
- `state_action LABEL fn args…` / `rc_locked` — единственный способ изменять состояние под блокировкой и с checkpoint.
- `rc_dispatch ARGV…` — единый диспетчер обоих транспортов (разовый CLI и `serve`).

**TUI** ([remote-control/tui/client.sh](remote-control/tui/client.sh)):
- `tui_call ARGV…` — запрос к `serve`; результат в `TUI_OK`, `TUI_CODE`, `TUI_DATA`, `TUI_ERROR` (читать `tui_q`/`tui_eq`).
- `tui_run_confirmed TITLE QUESTION ARGV…` — план из ответа команды, один `confirm_yn … N`, повтор с `--yes --plan-token`.
- `tui_secret NAME VALUE` / `tui_secrets_clear` — секреты только полем `secrets` запроса.
- `tui_pick_node|client|group`, `tui_toggle_nodes`, `tui_handle_node_codes` — общие виджеты (вместо `node_pick`).

**Ноды** — [remote-control/modules/nodes.sh](remote-control/modules/nodes.sh):
- `node_load idx` — загружает ноду в переменные `NODE_NAME`, `SERVER_IP`, `SERVER_PORT`, `SERVER_USER`, `SERVER_AUTH`, `SERVER_PASS`, `NODE_TAG`.
- `node_load_by_name name` — то же по имени.
- `_node_name_valid` / `_node_tag_valid` — единственная проверка имени (латиница, цифры, `.`, `_`, `-`) и тега (до 32 символов, без управляющих и служебных символов) для `node add`, `node rename`, `node tag`.
- `node_pass_encode` / `node_pass_decode` — AES-256-CBC + PBKDF2, ключ из `/etc/machine-id`. Пароли в `config.json` всегда шифрованные.

## Конвенции кода

- UI и пользовательские сообщения — **на русском**.
- ANSI-цвета и префиксы — только из `common.sh` (`[*] [✓] [!] [✗]`). Новые префиксы не вводить.
- `set -euo pipefail`: **есть** в установщиках (`install-essence.sh`, `install-remote-control.sh`); **нет** в основных entrypoints (`setup-essence.sh`, `remote-control-essence.sh`) — они полагаются на `error()` → `exit 1`. Сохранять этот паттерн, не добавлять `set -e` в существующие entrypoints.
- Модули `remote-control/modules/` не задают вопросов (`read`, `confirm_yn`, `menu_select`, `toggle_select`, `box_*`, `review_frame`): решения — коды `_required`, подтверждения — `rc_confirm_gate`. Вопросы и меню — только в `remote-control/tui/` и `setup-essence/`.
- Меню: каждая опция — отдельная `case`-ветка. Wildcard `*)` должен **выводить ошибку**, не молча принимать ввод.
- Чувствительные tmp-файлы — под `umask 077`.
- Хост-разработка на Windows, цель — Debian/Ubuntu. CRLF может попасть в строки от `jq`/`read` — поэтому `jq_r`, а не `jq -r`.

## Тесты

Запуск: `bash tests/run_tests.sh --all` (либо `--unit` / `--fuzz` / `--ci`). При первом клоне: `git submodule update --init --recursive` (BATS подмодули в `tests/lib/`).

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
- [tests/helpers/test_helper.bash](tests/helpers/test_helper.bash) — `setup_test_env`/`teardown_test_env`, `source_common`/`source_module`, `load_fixture_config`/`load_fixture_template`/`load_fixture_client_config`, `override_pass_key` (детерминизм шифрования).
- [tests/helpers/cmd_helper.bash](tests/helpers/cmd_helper.bash) — тесты команд: `load_core` (модули в порядке entrypoint), `open_local_session`, `run_cmd ARGV…` (выполняет `rc_dispatch` в текущем shell; результат — `status`, `output`, `CMD_ENVELOPE`), `cmd_jq FILTER`. Секреты — переменная `RC_REQUEST_SECRETS` перед `run_cmd`.
- [tests/helpers/mock_ssh.bash](tests/helpers/mock_ssh.bash) — моки `ssh_run`/`scp_run`/`upload_scripts`. Управление через `SSH_RUN_CALLS`, `SSH_RUN_MOCK_OUTPUT`, `SSH_RUN_MOCK_EXIT`, `reset_ssh_mocks`. **Реальные SSH в тестах запрещены.**
- [tests/helpers/fuzz_helper.bash](tests/helpers/fuzz_helper.bash) — словари (`DICT_SHELL_INJECTION`, `DICT_PATH_TRAVERSAL`, `DICT_FORMAT_STRINGS`, `DICT_UTF8_EDGE`, `DICT_BOUNDARY`) и генераторы (`random_int`, `random_string`, `random_utf8`, `mutate_inject`, `fuzz_mutated_input`).

Fixtures: [tests/fixtures/sample_config.json](tests/fixtures/sample_config.json), `sample_template.yaml`, `sample_client_config.txt`.

Fuzz проверяет **инварианты**: round-trip (`decode(encode(x)) == x`), валидное всегда проходит, невалидное всегда отвергается, мусор не крэшит. `FUZZ_ITERATIONS` управляет числом итераций (default 100, CI 50, timeout 10 мин).

Правила:
- Новая функция валидации / парсер / энкодер — должна получить unit-тест. Парсеры и энкодеры — ещё и fuzz.
- Новая или изменённая команда ядра — тесты через `run_cmd` в `tests/unit/cmd_*.bats` (`cmd_system`, `cmd_nodes`, `cmd_node_harden`, `cmd_conn`, `cmd_clients`, `cmd_generate`, `cmd_subscriptions`): нет решения → код `_required` и состояние не изменено, без `--yes` → `confirmation_required`, успех → данные и состояние, сбой посередине → откат или `partial`. Протокол `serve`, разбор argv, конверт и рендерер — `cli_contract.bats`; экраны `tui/` — `tui.bats` с заглушкой `tui_call`.
- Тест упал → чинить код, а не подгонять ожидания теста.

## Перед сдачей задачи

- `bash -n <file>` для каждого изменённого `.sh` (синтаксический check). Для Claude Code это делается автоматически через `PostToolUse`-хук в [.claude/settings.json](.claude/settings.json) после каждого Edit/Write.
- Релевантные BATS-тесты проходят локально.
- Если правил `common/` или `remote-control/modules/` — прогнать `bash tests/run_tests.sh --all`.
- В Claude Code: `/preflight` ([.claude/commands/preflight.md](.claude/commands/preflight.md)) прогоняет весь чек-лист разом.

## Релиз и CI

- Версия — [VERSION](VERSION) (бамп перед тегом).
- CI: [.github/workflows/tests.yml](.github/workflows/tests.yml) — unit (TAP) + fuzz (`FUZZ_ITERATIONS=50`, 10 мин timeout) на каждом push/PR.
- Релиз: [.github/workflows/release.yml](.github/workflows/release.yml).

## Что не коммитить

В [.gitignore](.gitignore):
- `remote-control/.remote-data/` — пользовательский `config.json` с зашифрованными credentials и токенами.
- `remote-control/templates/custom.yaml` — пользовательский шаблон.
- `.claude/settings.local.json` — личные permission-оверрайды Claude Code. Общий `.claude/settings.json` (с хуком `bash -n` и базовыми permission'ами для тестов/jq) и `.claude/commands/` коммитятся для всех контрибьюторов.
- `.claude/cache/` — кэш сабагента [mihomo-wiki](.claude/agents/mihomo-wiki.md) (shallow-клон Meta-Docs), пересоздаётся автоматически.

## Чувствительные данные

- Расшифрованные пароли нод (`SERVER_PASS` после `node_load`) — не выводить в `info`/`warn`/`echo`/логи. Для SSH передавать через `SSH_ASKPASS` (уже сделано в `ssh_run`).
- Токены подписок (`subscription.token`) — печатать только когда пользователь явно их запросил (просмотр клиента, ротация). Не логировать массово.
