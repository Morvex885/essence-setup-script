---
name: essence-commands
description: "Правила команд ядра remote-control на Rust: каталог в remote-control/core/src/cli.rs, обработчики, коды ошибок RcError и решения, подтверждение планом, секреты, журнал, тесты. Использовать при добавлении или изменении команд rc-core и функций, которые они вызывают; не для экранов remote-control/tui и меню setup-essence (см. essence-menus)."
---

# Essence commands

## Когда применять

Любое изменение поведения remote-control — это команда ядра: `сущность действие --флаги` → JSON `{ok,data|error}`. Экраны TUI (`remote-control/tui`), веб-панель и приложения только вызывают команды. Используйте этот skill для новых и изменяемых команд в `remote-control/core`, а также протокола `serve` (`remote-control/bin/src/serve.rs`). Правила экранов — skill `essence-menus`.

Порядок работы: прочитайте `AGENTS.md`, `remote-control/README.md`, соседние команды того же существительного и их тесты. Новое действие = команда + экран: сначала команда ядра с тестами (`remote-control/core`, `remote-control/bin/tests`), затем экран в `remote-control/tui`.

## Где лежит команда

Всё в `remote-control/` (Cargo workspace):

| Место | Содержимое |
|---|---|
| `remote-control/core/src/cli.rs` | Каталог `CATALOG`: существительное → глагол → токены флагов, разрешённые секреты, режимы (`nosession`, `tty`). Один каталог служит парсеру, справке `--help` и проверке грамматики |
| `remote-control/core/src/dispatch.rs` | `dispatch(argv, secrets, &mut Session)` — единый диспетчер разового CLI и serve; маршрутизация по (noun, verb); `Session::mutate` |
| `remote-control/core/src/nodes/`, `clients/`, `subscription/`, `telegram/`, `awg.rs` | Обработчики по доменам: `node`, `conn`; `group`, `template`, `client`, `generate`; `subscription`; `telegram`; `awg` |
| `remote-control/core/src/github/commands.rs` | `source *` (локальный источник и GitHub) |
| `remote-control/core/src/self_manage.rs` | `self *` |
| `remote-control/bin/src/{main,serve}.rs` | Разовый CLI (конверт, человекочитаемый рендерер, скрытый ввод секретов) и протокол `serve` v2 |

Новая команда = строка `spec(...)` в `CATALOG` (+ строка `HELP`, если новый флаг или команда меняют справку) + `match`-ветвь в `route` + обработчик. Алиасы не заводятся: `--name` — единый селектор объекта (`conn`/`awg`/`telegram` — нода, `subscription show|publish|rotate|revoke` — клиент, `subscription host|migrate` — нода), связи остались `--node` (у `client connections|nodes`), `--group`, `--client`. `generate` — bare-noun. Глобальные `--json --yes --plan-token --help` разрешены каждой команде неявно.

Токены каталога: `name=` — флаг со значением (повтор → `usage`); `name` — булев; `name+` — повторяемый; `provision-keys=` и т.п. — значение-выбор. Секреты команды перечислены отдельным полем spec. `nosession` — выполняется без открытой сессии; `tty` — нужна консоль (`node shell`, `telegram menu`; без неё — `tty_required`).

## Контракт обработчика

- **Никаких вопросов.** В `remote-control/core` нет чтения stdin/stdout и меню: нехватка решения — код `*_required` с extra. Консоль (`node shell`, `telegram menu`) — только через `session.console()` (`Console::available` → `raw()`), на разовом CLI и в `serve --inner`.
- **Результат** — `Ok(serde_json::Value)` (объект или массив). Человекочитаемый вывод строит общий рендерер `remote-control/bin`, обработчик его не форматирует; поля выводятся в порядке объявления.
- **Ошибка** — `Err(RcError::new(code, message))`, при необходимости `.with_extra(key, value)` (extra попадает в `error` конверта) и `.with_exit(n)` (только Telegram 3/4). Код — литерал из списка в `docs/remote-control.md` («Коды ошибок») плюс `error.rs::exit_code_for`: `usage`, `host_key_unknown`, `plan_changed` и `*_required` → выход 2, прочее → 1.
- **Секреты** — только `secrets.get(name)` из `rc_core::request_secrets::Secrets` (whitelist `password`, `current-password`, `vault-password`, `new-vault-password`, `script-password`). Значения не покидают `Zeroizing`, не попадают в argv дочерних процессов, журнал, `data`/extra и Debug-вывод. Команда принимает только свои секреты (`dispatch` проверяет).
- **Мутации** — только `session.mutate(label, |state| …)`: одна блокировка, изменение, checkpoint (локальный манифест) или GitHub-flush (снимок → commit → push). Прямые записи `config.json`/`secrets.json` из обработчиков запрещены. Частично завершённая мутация возвращает `partial{…}`.
- **SSH и удалённые эффекты** — только через `RemoteTransport` (`transport.rs`): `connect` (пины хост-ключей, `host_key_unknown/mismatch/changed` с отпечатками), `exec`, `upload` (встроенный комплект `rc_core::bundle` одной SFTP-операцией), `interactive` (PTY). Производство — `SshTransport` (russh), тесты — `FakeTransport`.
- **Журнал** — `session.log(Level::Info|Success|Warn, text)`: serve превращает записи в события `{"event":"log"}` до ответа, разовый CLI печатает их с префиксами `[*] [✓] [!] [✗]`. `error()`-аналогов и `exit` в обработчиках нет — команда возвращает `RcError`.
- **Сессия.** Команда с сессией получает открытый авторизованный `Session`; источник открывает транспорт (`session open` / разовый auto-open), обработчик этого не делает.

## Решения через коды `_required`

Если операции нужен ответ, который раньше спрашивался посреди работы, команда получает флаг или секрет, а при их отсутствии отвечает `RcError` с кодом `…_required` и extra с данными для вопроса, ничего не меняя: `key_provisioning_required{"nodes":[…]}`, `storage_mode_required{"choices":[…]}`, `existing_config_action_required{"choices","remote_counts","local_counts"}`, `repo_create_required`, `repo_private_required`, `cache_skip_required`, `target_replace_required{"repo","tracked_files"}`, `new_vault_password_required`, `vault_password_required`, `github_auth_required` и т.д. Фронтенд показывает один вопрос на код и повторяет команду с флагом; секрет передаётся полем `secrets`, не флагом.

## Подтверждение

Опасное действие (удаление, отзыв, смена группы, перенос, принудительная загрузка, действия на серверах) строит план и вызывает `Plan::new(lines, extra).confirm(invocation)?` после проверок и до любых мутаций/удалённых изменений:

1. `lines` — строки плана на русском: операция, последствия, все цели; без секретов;
2. `extra` — строка, входящая в токен (отпечаток комплекта скриптов, VERSION), когда план должен зависеть от удалённого состояния;
3. без `--yes` — `confirmation_required{plan,plan_token}`; `--yes --plan-token T` при изменившемся плане — `plan_changed` с новым планом. До согласия допустим только read-only preflight (включая SSH-чтение).

Удалённые Telegram-операции: read-only preflight всех выбранных нод (SSH-параметры, VERSION и SHA-256 встроенного комплекта), затем один план на всё; недоступная нода — строка «ошибка» в итоговой таблице, доступные продолжают; воркеры работают на замороженном снимке, вопросов не задают. `telegram menu` — preflight одной ноды и PTY; скрипты он не загружает: устаревшие/отсутствующие — код `invalid` с `state` и командой `node upload-scripts` (экран предлагает отдельную подтверждённую загрузку).

## Протокол serve v2

`essence-rc serve [--inner]` (`remote-control/bin/src/serve.rs`): stdout — hello `{"event":"hello","protocol":2,"version":V}`, затем на каждый запрос `{"id","argv","secrets"?}` события журнала и ровно один ответ. id — строка/число/null; неразборчивая строка — `usage` с `id:null`. Запросы строго последовательные; SIGINT не прерывает команду; EOF закрывает сессию (exit 0). `--inner` — приватный режим терминального меню: подключает консоль для `!tty`-команд на общем терминале. Протокол меняется только вместе с тестами `remote-control/bin/tests/serve_protocol.rs` и разделом справки serve.

## Тесты

- Unit-тесты обработчиков — в `#[cfg(test)]` модулях `remote-control/core` на `FakeTransport` и `crate::nodes::testing::{session, invocation, fingerprint, Journal}`.
- Процессные — `remote-control/bin/tests/`: `cli_contract` (грамматика, коды выхода, жизненный цикл подтверждения, секреты), `serve_protocol` (протокол), `github_source` (git/gh на локальных репозиториях), `state_process` (блокировки), `tui_e2e` (настоящий бинарник в PTY).
- Golden билдеров — `remote-control/core/tests/protocols_golden.rs` (побайтовый паритет с `tests/golden/protocols/`).

Каждая новая или изменённая команда получает: нет решения → код `_required` с extra и состояние без изменений (проверка отпечатком каталога данных); без `--yes` → `confirmation_required` и состояние без изменений; успех → данные и состояние; сбой посередине → откат или `partial`; секреты не появляются в argv, журнале и выводе. Тесты не открывают реальный SSH (только loopback `ssh_wire` и env-гейт `E2E_SSH`).

## Документация

Каталог команд, коды и протокол — `docs/remote-control.md` и справка самого бинарника (`essence-rc help`, `essence-rc <noun> --help` — генерируется из `HELP` в `cli.rs`). Новая команда, флаг, код ошибки или поле данных обновляют `cli.rs`, `docs/remote-control.md` (каталог, коды и, если есть экран, раздел «Главное меню»). Архитектура и проверки — `remote-control/README.md`.

## Проверка

- `cd remote-control && cargo test --workspace --locked` (свои прогоны — с отдельным `CARGO_TARGET_DIR`);
- `cargo clippy --workspace --all-targets --locked` без ошибок;
- для экранов нового действия — тест в `remote-control/tui` на `ScriptedClient`/`ScriptedUi` (argv по клавишам, подтверждение, коды → флаги), сценарий реального бинарника при изменении запуска.
