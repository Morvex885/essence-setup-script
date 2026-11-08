---
name: essence-commands
description: "Правила команд ядра remote-control: спецификация, обработчики, коды ошибок и решения, подтверждение планом, секреты, журнал, тесты. Использовать при добавлении или изменении команд в remote-control/modules/cmd_*.sh и функций ядра, которые они вызывают; не для экранов remote-control/tui и меню setup-essence (см. essence-menus)."
---

# Essence commands

## Когда применять

Любое изменение поведения remote-control — это команда ядра: `сущность действие --флаги` → JSON `{ok,data|error}`. Экраны TUI, веб-панель и приложение только вызывают команды. Используйте этот skill для новых и изменяемых команд, функций ядра в `remote-control/modules/` и протокола `serve`. Правила экранов — skill `essence-menus`.

Порядок работы: прочитайте `AGENTS.md`, соседние команды того же существительного, `docs/remote-control.md` (раздел «Архитектура: ядро команд») и тесты соответствующего `cmd_*.bats`. Новое действие = команда + экран: сначала команда с тестами, затем экран в `remote-control/tui/`.

## Где лежит команда

| Файл | Существительные |
|---|---|
| `remote-control/modules/cmd_core.sh` | `help`, `status`, `session`, `source`, `self` |
| `remote-control/modules/cmd_nodes.sh` | `node`, `conn`, `awg`, `telegram` |
| `remote-control/modules/cmd_clients.sh` | `client`, `group`, `template`, `generate`, `sub` |

Новое существительное идёт в подходящий из трёх файлов; **новый `cmd_*.sh` не заводится**. Файлы плоские в `modules/`, поэтому установщик и релиз их подхватывают без правок. Общие помощники разбора (`cli_has`, `cli_opt`, `cli_list`, `cli_require*`, `_cli_require_node|group|client`, `_cli_json_array`, `_cli_json_lines`) остаются в `cli.sh`.

Для существительного NOUN файл объявляет:

- `cli_spec_NOUN VERB` — печатает токены флагов, rc 1 для неизвестного глагола (для `status`, `generate`, `help` глагол пустой). Список существительных — все объявленные `cli_spec_*`; отдельного whitelist нет;
- `_cli_help_NOUN` — heredoc строк `usage|описание`: попадает в `--help` и в каталог `docs/remote-control.md`;
- `cli_cmd_NOUN_VERB` — обработчик (`-` в глаголе → `_`).

Токены спецификации: `name=` — флаг со значением; `name` — булев флаг; `name+` — повторяемый флаг со значением; `@secret-name` — разрешённый секрет (`password`, `current-password`, `vault-password`, `new-vault-password`, `script-password`); `!nosession` — команда выполняется без открытой авторизованной сессии; `!tty` — нужен `/dev/tty` (`node shell`, `telegram menu`; без терминала — `tty_required` через `_rc_tty_available`). `--yes`, `--plan-token`, `--json` разрешены каждой команде неявно.

## Контракт обработчика

- **Никаких вопросов.** В модулях ядра нет `read`, `confirm_yn`, `menu_select`, `toggle_select`, `box_*`, `review_frame`. Нужно решение — см. «Решения».
- **Результат** — JSON в `CLI_DATA` (формат `{...}` или массив), собранный `jq -n`; человекочитаемый вывод строит общий рендерер, обработчик его не форматирует.
- **Ошибка** — `rc_fail CODE MESSAGE [EXTRA_JSON]` и `return 1`. Код — литерал из списка в `docs/remote-control.md` («Коды ошибок»); новый код добавляется туда же. Код на `_required`, `usage`, `host_key_unknown`, `plan_changed` даёт выход 2.
- **Секреты** — только `rc_secret NAME` (значение из `RC_REQUEST_SECRETS`); никогда в argv внешних программ, `info`/`warn`, `CLI_DATA` и аргументы `jq --arg` (линтер в `tests/unit/tui.bats` ловит имена вроде `pw`, `password`). Значение в jq — через stdin.
- **Мутации** — только через `state_action LABEL fn args…` (одна мутация, checkpoint, синхронизация GitHub) или `rc_locked LABEL fn args…` для операций без записи конфигурации под общей блокировкой. Чтение конфигурации — `jq_r`; запись — `jq_w`; не прямой `jq > file`.
- **Журнал** — только `info`, `success`, `warn` (в `serve` они уходят событиями `log`); `error()` и `exit` запрещены — команда возвращает управление. Сообщение об ошибке печатает `rc_fail`; повторно в данные его не клади.
- **Сессия.** Команда без `!nosession` получает открытую авторизованную сессию от транспорта; не открывайте источник и не проверяйте пароль запуска сами.
- **Длинные и фоновые процессы** не должны держать дескриптор журнала (`</dev/null >/dev/null 2>&1` для фоновых `ssh -f`).

## Решения через коды `_required`

Если операции нужен ответ, который раньше спрашивался посреди работы, команда получает флаг или секрет, а при его отсутствии отвечает `rc_fail <код>_required "сообщение" '{"данные для вопроса"}'` и **ничего не меняет**: `key_provisioning_required` (`{"nodes":[…]}`), `storage_mode_required`, `existing_config_action_required` (`choices`), `repo_create_required`, `vault_password_required` и т.п. Интерфейс сам спрашивает пользователя и повторяет команду с нужным флагом. Решения передаются глобалами (`GITHUB_DECISION_*`, `GITHUB_SECRET_*`) или параметрами функций ядра; `rc_dispatch` сбрасывает их перед каждой командой.

## Подтверждение

Опасное действие (удаление, отзыв, смена группы, перенос, принудительная загрузка, действия на серверах) вызывает `rc_confirm_gate` после проверок и перед мутацией:

1. заполните `CORE_PLAN_LINES` (массив строк плана; без секретов; все цели и последствия);
2. при необходимости — `CORE_PLAN_EXTRA` (строка, входящая в токен: отпечаток комплекта скриптов, VERSION) и `CORE_PLAN_DATA` (JSON с полями для ответа, например `{"port":P}`);
3. `rc_confirm_gate || return 1`.

Без `--yes` gate отвечает `confirmation_required` с `plan` и `plan_token`; `--yes --plan-token T` при изменившемся плане — `plan_changed` с новым планом. До согласия запрещены серверные записи и любые мутации (допустим read-only SSH-preflight).

Удалённые Telegram-операции: read-only preflight всех нод (SSH-параметры, VERSION и SHA-256 комплекта), затем один gate на объединённый план; недоступная нода исключается с результатом «ошибка», доступные продолжают; workers используют замороженный снимок и точно согласованный VERSION, вопросов не задают; изменившийся после согласия комплект блокирует запуск без автоматической перезаписи. Одиночный `telegram menu` использует тот же preflight и план на одну ноду; не вызывайте `ensure_remote_scripts_current` для этого входа — его автозагрузка обходит согласие.

## Тесты

Тест команды — `run_cmd ARGV…` из `tests/helpers/cmd_helper.bash` (`load_core`, `open_local_session`, результат — `status`, `output`, `CMD_ENVELOPE`, `cmd_jq`). Секреты — `RC_REQUEST_SECRETS='{"password":"…"}'` перед вызовом. Файл тестов по сущности:

| Команды | Файл в `tests/unit/` |
|---|---|
| `help`, `status`, `session`, `source`, `self` | `cmd_system.bats` |
| `node` (кроме `harden`) | `cmd_nodes.bats` |
| `node harden` | `cmd_node_harden.bats` |
| `conn`, `awg`, `telegram` | `cmd_conn.bats` |
| `client`, `group`, `template` | `cmd_clients.bats` |
| `generate` | `cmd_generate.bats` |
| `sub` | `cmd_subscriptions.bats` |
| протокол `serve`, разбор argv, конверт, коды выхода, рендерер | `cli_contract.bats` |

Каждая новая или изменённая команда получает: нет входа для решения → код `_required` с EXTRA и неизменное состояние; без `--yes` → `confirmation_required` и неизменное состояние; успех → данные и состояние; сбой посередине → откат или `partial`. Проверки состояния (config.json, вызовы SSH, откаты, отсутствие секретов в выводе) пишите явно, не только код выхода. Тесты не открывают реальный SSH (`mock_ssh.bash`).

## Документация

Каталог команд — раздел «Командная строка (CLI)» в `docs/remote-control.md`, сформированный по `_cli_help_*` (`remote-control-essence --help`). Новая команда, флаг, код ошибки или поле данных обновляют каталог, коды и (если есть экран) раздел «Главное меню». Протокол `serve` меняется только вместе с `serve.sh`, разделом «Протокол `serve`» и сценарием в `cli_contract.bats`.

## Проверка

- `bash -n` для каждого изменённого `.sh`;
- `grep -nE 'read -r[sp]|confirm_yn|menu_select|toggle_select|node_pick|box_top|review_frame' remote-control/modules/*.sh` не находит вопросов (исключения: `review_frame` в рендерере и чтение `/dev/tty` при открытии сессии в CLI);
- релевантные `tests/unit/cmd_*.bats`, затем весь набор перед сдачей.
