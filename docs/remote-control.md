# Remote Control — управление серверами и генерация клиентских конфигов

Скрипт запускается на **вашем локальном компьютере**. Подключается к серверам по SSH, настраивает протоколы, генерирует клиентские конфиги для устройств, публикует подписки и управляет AmneziaWG-peers.

## Запуск

### Windows

Двойной клик по `remote-control.cmd` в корне проекта или из cmd:
```cmd
remote-control.cmd
```

Скрипт автоматически запускается через WSL.

### Linux / macOS

```bash
bash remote-control/remote-control-essence.sh
```

### Установленная версия (Linux / macOS)

```bash
curl -fsSL https://raw.githubusercontent.com/Morvex885/essence-setup-script/main/remote-control/install-remote-control.sh | sudo bash
remote-control-essence
```

### Зависимости

| Утилита | Где взять |
|---|---|
| Bash 3.2+ | Linux/WSL: пакет bash; macOS: встроен |
| `ssh`, `scp` | Встроены в Linux и macOS. На Windows — WSL |
| `openssl`, `base64` | Встроены |
| `jq` | `apt install jq` / `brew install jq` |
| `git`, `gh` | Нужны для синхронизации через GitHub; `apt install git gh` / `brew install git gh` |
| `age`, `age-keygen`, `age-plugin-batchpass` | Только для зашифрованного GitHub-хранилища: официальный комплект одной версии не ниже 1.3.2 |

Отсутствующие зависимости скрипт пробует установить сам через `common/ensure-deps.sh`.
Если совместимый комплект уже установлен, он используется без изменения. Иначе
на Linux (amd64, arm64, armv7) и macOS (amd64, arm64) скачивается официальный
архив age v1.3.2 с проверкой SHA-256 и устанавливается только в пользовательский
`${XDG_CACHE_HOME:-$HOME/.cache}/remote-control-essence/tools/age-v1.3.2`.
Системный age не перезаписывается; кэш не входит в конфигурацию и переживает
отказ от первой настройки. В Termux нужен совместимый нативный пакет; на других
неподдерживаемых платформах установите комплект вручную. Явно заданные `AGE_BIN`
и `AGE_KEYGEN_BIN` проверяются, но автоматически не заменяются. Для локального
или незашифрованного GitHub-источника age не нужен.
Загрузка комплекта age ограничена 15 секундами на подключение и 300 секундами
на весь запрос. Если после аварийного завершения остаётся установочная блокировка,
предупреждение показывает полный путь к каталогу `.age-v1.3.2.lock`.
Удаляйте его вручную только убедившись, что другая установка age не выполняется.
Remote Control совместим с системным Bash 3.2 в macOS; Homebrew Bash не требуется.

### Учётная запись источника GitHub

Владелец из локального `source.json` закреплён за источником: смена активного
аккаунта системного `gh` не переключает репозиторий и не переносит конфигурацию.
Первое подключение (`source github-connect --login L`) требует явного логина;
смена владельца выполняется явно командой `source github-change-account --login L`.

Для каждого владельца Remote Control хранит отдельный профиль GitHub CLI в
`$CONFIG_DIR/credentials/gh/<логин>` (обычно
`~/.config/remote-control-essence/credentials/gh/<логин>`). Доступ к каталогам
ограничен правами 700, к `hosts.yml` — 600. Токен не записывается в `source.json`
или Git URL; системные `gh auth switch` и `gh auth setup-git` не вызываются.
При первом подключении скрипт может скопировать токен **указанного** пользователя
из системного `gh`; иначе команда отвечает `github_auth_required`, и вход через
браузер выполняет `source github-login --login L` (код устройства печатается в
журнал). При запуске уже подключённого источника браузер не открывается: если
профиль отсутствует, скрипт один раз пробует импортировать токен сохранённого
владельца. Если токена нет, источник и локальный кэш остаются без изменений;
авторизуйте профиль командой `source github-login --login <логин>` или вручную
`GH_CONFIG_DIR="$HOME/.config/remote-control-essence/credentials/gh/<логин>" gh auth login --hostname github.com --web`
и повторите открытие. На другом устройстве авторизация выполняется заново.

## Архитектура: ядро команд

Вся логика Remote Control живёт в одном ядре команд: `сущность действие --флаги` →
ответ `{ok, data | error}`. Терминальное меню, будущая веб-панель и возможное
нативное приложение — только слои экранов без собственной логики, поэтому тесты
команд проверяют всё, что делают интерфейсы.

### Слои

| Путь | Назначение |
|---|---|
| `remote-control/remote-control-essence.sh` | Bootstrap: проверка Bash, `SCRIPT_DIR`, ветвление. Без аргументов — зависимости и запуск TUI (`tui/main.sh`); с аргументами — загрузка ядра и `cli_main` |
| `remote-control/modules/` | Ядро без вопросов пользователю. `cli.sh` — разбор, `rc_dispatch`, конверт, коды выхода, секреты, справка, рендерер; `session.sh` — сессия; `source.sh` — источник конфигурации; `serve.sh` — протокол `serve`; `cmd_core.sh`, `cmd_nodes.sh`, `cmd_clients.sh` — спецификации и обработчики команд |
| `remote-control/tui/` | Слой экранов (`main.sh`, `client.sh`, `system.sh`, `nodes.sh`, `clients.sh`). Подключает только `common/common.sh` и `tui/*.sh`, запускает `serve` дочерним процессом и общается с ним тем же протоколом, что веб и приложение; модули ядра в процесс TUI не попадают |
| `common/` | Независимый общий слой: цвета, рамки и меню (`menu_select`, `confirm_yn`, `review_frame`, `toggle_select`), зависимости, TLS, протоколы |

Команды сгруппированы по файлам: `cmd_core.sh` — `help`, `status`, `session`,
`source`, `self`; `cmd_nodes.sh` — `node`, `conn`, `awg`, `telegram`;
`cmd_clients.sh` — `client`, `group`, `template`, `generate`, `sub`.

### Транспорты

Диспетчер один — `rc_dispatch ARGV…`. У него два транспорта:

- **Разовый CLI** — `remote-control-essence сущность действие … [--json]`. Сессию
  открывает сам (`RC_SCRIPT_PASSWORD`/`RC_VAULT_PASSWORD` или скрытый ввод с
  терминала), результат печатает общий рендерер. Подробности — в разделе
  [Командная строка](#командная-строка-cli).
- **`remote-control-essence serve`** — долгоживущий процесс: строки JSON в stdin и
  stdout. TUI — клиент `serve`; свой «режима вызова» у диспетчера нет.

### Протокол `serve`

Первая строка stdout — приветствие:

```json
{"event":"hello","protocol":1,"version":"1.2.3"}
```

Запрос — одна строка stdin:

```json
{"id":3,"argv":["group","add","--name","LAB"],"secrets":{"password":"…"}}
```

- `id` — строка или число (эхом возвращается в ответе);
- `argv` — массив строк (то же, что аргументы разового CLI, без `--json`);
- `secrets` — необязательный объект строк; допустимы только секреты, перечисленные
  в спецификации команды. Недопустимое имя → `usage`. `--password-stdin` и
  `--secrets-stdin` в `argv` запрещены: `usage` «В serve секреты передаются полем
  secrets».
- Невалидный JSON, нет `argv` или неверные типы → ошибка `usage` «Неверный
  запрос.». Если запрос содержит `id` типа строка или число, он сохраняется в
  ответе; иначе `id` равен `null`. Например, для `{"id":3,"argv":"bad"}`:
  `{"id":3,"ok":false,"error":{"code":"usage","message":"Неверный запрос."}}`.

Пока команда выполняется, ядро отправляет события журнала — раньше ответа:

```json
{"id":3,"event":"log","level":"success","text":"Группа LAB добавлена"}
```

`level` — `info`, `success`, `warn`, `error` (по префиксам `[*]`, `[✓]`, `[!]`,
`[✗]` строки журнала) или `output` (строка без префикса). Ответ — ровно один на
запрос, с тем же `id`:

```json
{"id":3,"ok":true,"data":{"name":"LAB"}}
{"id":3,"ok":false,"error":{"code":"not_found","message":"…"}}
```

В режиме GitHub к успешному ответу добавляется поле `sync`
(`clean`, `pending` или `offline`). Ошибка может нести данные (`partial`,
`confirmation_required` — с `plan` и `plan_token`) и дополнительные поля
`error` (EXTRA).

**Порядок и сигналы.** Запросы выполняются строго по одному, отмены нет. Ctrl+C
не прерывает уже запущенную команду (serve игнорирует `INT`); закрытие stdin
завершает процесс с кодом 0 и закрывает сессию. Если процесс ядра падает на
запросе, клиент получает ответ `failed` «Ядро завершилось аварийно.».
Фоновые процессы команды не должны держать дескриптор журнала.

Для noninteractive-команд `serve` также сохраняет игнорирование `INT` после
запуска внешнего timeout и перед `exec` его дочерней программы. Дедлайн остаётся
действующим: зависшая программа завершается с ненулевым результатом. Интерактивные
`node shell` и `telegram menu` сохраняют обычную передачу Ctrl+C на удалённый tty.

### Сессия

В `serve` сессию открывает запрос `session open [--remember-key]` с секретами
`vault-password` и `script-password` в поле `secrets`; до него любая команда
(кроме `session status`, `source init-local` и других `!nosession`) отвечает
`session_closed`. Шаги `session open`:

1. нет ни `source.json`, ни `config.json` → `not_configured`;
2. открыть источник (GitHub: пароль доступа — `vault_password_required` /
   `vault_password_invalid`; формат снимка — `github_format_outdated|newer|invalid`
   с версиями в EXTRA; занята блокировка — `locked`; прочее — `source_failed`);
3. проверить пароль запуска: нет секрета — `auth_required`, неверный —
   `auth_failed`.

`session status` не открывает источник и возвращает
`{"configured","source":"local|github|null","open","authorized"}`.

### Секреты

Секрет попадает в команду только как значение `rc_secret NAME`; он не бывает в
argv внешних программ, в журнале и в данных ответа. Допустимые имена:
`password`, `current-password`, `vault-password`, `new-vault-password`,
`script-password`. В разовом CLI: `--password-stdin` (весь stdin — пароль строкой,
только для команд с `@password`) или `--secrets-stdin` (JSON-объект строк); вместе
эти флаги — `usage`.
Пароли доступа `vault-password` и `new-vault-password` не могут заканчиваться CR
или LF (`invalid`): batchpass удаляет завершающие переводы строк. В GitHub age
пароль передаётся plugin через файловый дескриптор 9, без терминального prompt и
без значения пароля в окружении или argv.

### Подтверждение и токен плана

Опасная команда без `--yes` ничего не меняет и отвечает `confirmation_required`
с полями `plan` (строки плана без секретов) и `plan_token` (16 hex — хеш команды и
плана). Выполнение — тот же `argv` с `--yes --plan-token T`. Если план успел
измениться, ответ — `plan_changed` с новым планом и токеном. Скрипты могут передать
`--yes` без токена.

### Решения вместо вопросов

Команды ничего не спрашивают. Решение, которое раньше задавалось посреди
операции, превращается в код `…_required` с данными (EXTRA), а интерфейс сам
спрашивает пользователя и повторяет команду с нужным флагом или секретом.
Например: `key_provisioning_required` (`{"nodes":[…]}`), `repo_create_required`,
`storage_mode_required`, `existing_config_action_required`,
`vault_password_required`, `cache_skip_required`, `target_replace_required`.
Команды, которым нужен живой терминал (`node shell`, `telegram menu`), без
терминала отвечают `tty_required`.

Решения не заменяют подтверждение. `source github-connect` и
`source github-change-account` после всех решений отвечают `confirmation_required`
(с `plan` и `plan_token`), если в плане есть необратимый шаг: сделать репозиторий
приватным (`--make-private`), удалить файлы целевого репозитория
(`--replace-target`, с их числом), заменить конфигурацию GitHub (`--existing local`,
со счётчиками нод, клиентов и групп с обеих сторон), хранить без шифрования
(`--storage none`) или выполнить SSH-действия на нодах (новые переносимые ключи и
отпечатки закрепляемых ключей серверов). До согласия ничего не пишется ни локально,
ни в GitHub: репозиторий создаётся или делается приватным только после него. Создание
репозитория, подключение пустого репозитория с `age` без нод и `--existing remote`
подтверждения не требуют. План `source github-replace-with-local` тоже перечисляет
SSH-действия на нодах; `key_provisioning_required` приходит раньше
`confirmation_required`.
При `source github-connect --existing migrate --make-private` преобразование
формата и приватизация входят в один план: отказ или устаревший токен отменяют
оба действия до изменения репозитория. Самостоятельный
`source github-migrate-format` сохраняет отдельное подтверждение миграции.

Расшифрованный снимок конфигурации GitHub (`runtime-vault.json`) в `$CONFIG_DIR`
не хранится: открытие сессии, `github-migrate-format` и `github-replace-with-local`
удаляют его, закрытие сессии убирает копии прежних версий.

При `source github-change-account --existing remote` смена считается принятой
непосредственно перед установкой нового локального хранилища. Сбой после этого не
откатывает её: синхронизация приостанавливается, а `source github-fetch` или следующий
`session open` завершают переход на новый аккаунт. Если отправка в новый репозиторий
не подтверждена и ветки в нём нет, следующий запуск отменяет смену и возвращает
прежний репозиторий. Ответы `*_required` и отказ `github-change-account` не оставляют
профиль входа нового аккаунта (`credentials/gh/<login>`), если его не было до
команды, и не меняют состояние синхронизации (`sync`). Неудачный `source github-fetch`
не меняет цель сеанса: следующая отправка идёт в тот же репозиторий. В режиме `age`
`source github-fetch` использует ключ текущего сеанса и пароль доступа не запрашивает.
Если ключ хранилища сменили на другом устройстве, команда отвечает
`vault_password_required`, сессия продолжает работать с прежним ключом, а новый пароль
вводится при `session open`. После закрытия сессии расшифрованных ключей на диске не
остаётся (кроме сохранённого `--remember-key`).

### Коды ошибок

- Общие: `usage`, `confirmation_required`, `plan_changed`, `session_closed`,
  `not_configured`, `not_found`, `conflict`, `invalid`, `not_ready`,
  `missing_secret`, `needs_setup`, `failed`, `partial`, `locked`,
  `tty_required`, `deps_missing` (точка входа при недоступности обязательных
  зависимостей или ядро при недоступности совместимого age с batchpass).
- SSH и ноды: `host_key_unknown`, `host_key_mismatch`, `host_key_changed`,
  `remote_failed`, `onboarding_failed`, `port_in_use`, `hardening_failed`,
  `nothing_pending`, `not_installed`.
- Вход и пароли: `auth_required`, `auth_failed`, `vault_password_required`,
  `vault_password_invalid`, `new_vault_password_required`.
- Источник GitHub: `github_auth_required`,
  `repo_create_required`, `repo_private_required`, `storage_mode_required`,
  `existing_config_action_required`, `cache_skip_required`, `target_replace_required`,
  `key_provisioning_required`, `github_format_outdated`, `github_format_newer`,
  `github_format_invalid`, `source_failed`.
- Система: `root_required`, `unsafe_path`, `update_failed`.

Коды выхода: `0` — успех; `2` — `usage`, `host_key_unknown`, `plan_changed` и
любой код на `_required` (в том числе `confirmation_required`); для `telegram`
ещё `3` и `4`; остальное — `1`.

## Командная строка (CLI)

С аргументами скрипт работает без меню и без вопросов:

```bash
remote-control-essence <сущность> <действие> [--флаги] [--json]
remote-control-essence --help            # все команды
remote-control-essence client --help     # команды одной сущности
remote-control-essence serve --help      # описание протокола serve
```

Флаги — `--flag value` или `--flag=value`; списки задаются повторением флага
(`--node a --node b`). `--yes`, `--plan-token T` и `--json` разрешены каждой команде.
Команды выполняет ядро (`rc_dispatch`); человекочитаемый вывод — один общий
рендерер данных ответа (объект — строки `ключ: значение`, список объектов — таблица,
подтверждение — рамка плана).

- **Без конфигурации** команды завершаются ошибкой `not_configured`; конфигурация
  создаётся командой `source init-local` или `source github-connect --login L`.
  Решения подключения задают флаги (`--create-repo`, `--make-private`,
  `--storage age|none`, `--existing remote|local|migrate`, `--provision-keys yes|no`);
  без нужного флага команда отвечает кодом `*_required` и ничего не меняет
  (`repo_private_required` → повтор с `--make-private`; строка плана «Публичный
  репозиторий станет приватным.» требует согласия, репозиторий делается приватным
  только после него). Любой сбой первой настройки (`source init-local` или
  `source github-connect` без конфигурации) удаляет созданные этой командой файлы
  (`config.json`, `source.json`, копию репозитория, профиль входа GitHub), снимает её
  блокировку и оставляет сессию закрытой: `session status` снова отвечает
  `configured:false`. Если сбой случился до отправки в GitHub, повтор и следующий
  запуск начинаются с первой настройки; если после — репозиторий уже содержит
  конфигурацию, и повтор отвечает `existing_config_action_required` (нужен
  `--existing remote|local`). Файлы, существовавшие до команды (например, профиль из
  `source github-login`), сохраняются.
- **`source github-connect` при существующей локальной конфигурации**: при любом
  сбое (в том числе после подключения) восстанавливаются `config.json`,
  `manifest.json`, `ssh/known_hosts`, `ssh/identities` и `.auth`, отзываются
  переносимые ключи, установленные этой командой, удаляются созданные ею кэши
  (`github-store.git`, `github-sessions`, профиль, archive-ссылки). Ответ `*_required`
  или отказ от плана ничего из этого не оставляет. `--remember-key` сохраняет ключ и
  для только что созданного хранилища `age`.
- **Ключи и пароль**: `source github-rotate-key` заменяет сохранённый ключ новым (при
  ошибке сохранения удаляет его с предупреждением; `key_saved` в `source status`
  остаётся верным); `source github-import-recovery-key` отклоняет ключ другого
  хранилища (`invalid`) и сохраняет текущий; в режиме GitHub при сбое
  `self password-set` / `password-remove` остаётся прежний пароль запуска (в
  local-режиме, как и у других изменений, поздний сбой контрольной точки применённое
  изменение не откатывает); план `self uninstall --remove-data` предупреждает о
  неотправленных в GitHub изменениях.
- **`github-replace-with-local` / `github-migrate-format` с `refreshed:false`**: сессия
  закрывается, команды отвечают `session_closed`, пока `session open` не пересоберёт
  рабочее состояние; рабочая копия с неотправленными изменениями сохраняется.
- **`--json`**: в stdout ровно один объект `{"ok":true,"data":…}` или
  `{"ok":false,"error":{"code":…,"message":…},"data"?}`; все сообщения — в stderr.
  В режиме GitHub добавляется поле `sync`.
- **stdin читается только для секретов**: `--password-stdin` (пароль строкой для
  команд с секретом `password`: `node add`, `node password`, `self password-set`)
  или `--secrets-stdin` (JSON-объект `{"имя":"значение"}`); других секретов команда
  не принимает. После чтения stdin закрывается.
- **`--yes`** обязателен для опасных действий. Без него команда показывает план,
  ничего не меняет и завершается с кодом 2 (`confirmation_required`, в ответе
  `plan` и `plan_token`). `--yes --plan-token T` выполняет действие, только если
  план не изменился, иначе — `plan_changed` с новым планом и токеном.
- **Ключ сервера при `node add`**: `--host-key SHA256:…` (сверить отпечаток),
  `--accept-new-host-key` (довериться первому ключу) или `--replace-host-key
  SHA256:… [--yes]` (заменить сменившийся: план с прежними и новым отпечатками,
  без `--yes` — `confirmation_required`). Закрепляется только ключ с указанным
  отпечатком, другие типы ключей из сканирования — нет. Без флагов команда печатает
  отпечатки и завершается с кодом 2 (`host_key_unknown`); `--host-key` для хоста,
  уже известного с другим ключом, — `host_key_changed` `{host,port,fingerprints}`
  без записи; доверие новому ключу — `node trust-host-key` (закрепляет только ключ
  с этим отпечатком).
- **Логин и адрес ноды**: `--user` — `^[A-Za-z_][A-Za-z0-9._-]{0,31}$`, `--ip` —
  `^[A-Za-z0-9:][A-Za-z0-9.:_-]{0,252}$`, иначе `invalid`. Сохранённая нода с
  небезопасным логином, адресом или ссылкой на ключ (`identity` — только null, `""`,
  `system` или собственный id ноды) не проходит проверку конфигурации и не
  загружается (`invalid`). SSH и SCP получают адрес после `--`.
- **Имя и тег ноды** (новые значения в `node add`, `node rename`, `node tag`): имя —
  латиница, цифры, `.`, `_`, `-`, не из одних точек; тег — пустой или до 32 символов,
  Unicode и эмодзи допустимы, без управляющих символов и ``; " ' ` $ \ | & < > { } [ ] # , : /``.
  Иначе `invalid`, ничего не записывается.
- **Частичные результаты нод**: `node add` — `partial` с `{name,id,needs_setup}`
  (в local-режиме сбой контрольной точки откатывает добавление: запись ноды, пароль
  и `known_hosts`); `node delete` — любой сбой после удаления компонентов на сервере
  даёт `partial` с `{name,scope,deleted,remote_removed}`, резервная копия
  `.node-delete.*` удаляется сразу после фиксации; `conn set` — `partial` с
  `{node,groups,proxies,applied}`, если хотя бы одна группа уже сохранена.
- **`node harden`**: план сообщает о замене и отзыве прежнего управляемого ключа ноды;
  сбой при замене ключа возвращает прежнюю пару; откат включает вход по паролю только
  для нод с `auth=password`. Подтверждение `--yes --plan-token` — только с явным
  `--port` (меню спрашивает порт и заново запрашивает план с ним).
- **Обнаружение подключений** (`conn sync`, `conn list --discover`, `node aliases`):
  нода без `/etc/mihomo/client-config.txt` доступна и не имеет подключений.
- **Отложенная SSH-настройка**: `node upload-scripts [--force]`, `node delete --scope
  server` и `node harden` для ноды GitHub с отложенной настройкой отвечают
  `needs_setup` до плана и до любого SSH. Отпечатки ключей серверов в планах и в
  данных `host_key_unknown` / `host_key_changed` / `host_key_mismatch` сортируются.
- **Сообщения ошибок** однострочные: переводы строк заменяются пробелами и в
  журнале, и в конверте.
- **Сессия** открывается автоматически: пароль запуска — из `RC_SCRIPT_PASSWORD`
  (или скрытый ввод с терминала, если stdin — TTY), иначе `auth_required`; пароль
  доступа к GitHub — сохранённый ключ устройства или `RC_VAULT_PASSWORD`, иначе
  `vault_password_required` (неверный — `vault_password_invalid`).
  `session status` показывает состояние без открытия источника.
- **Блокировка**: изменения конфигурации сериализуются через `.rc-lock` в каталоге
  данных; в local-режиме команда ждёт до `RC_LOCK_WAIT` секунд (целое число, 30 по
  умолчанию; иное значение заменяется на 30).
  В режиме GitHub процесс держит блокировку весь сеанс, поэтому второй запуск
  (меню или CLI) сразу получает `locked`. После `source github-switch-local` и
  `source github-delete-repo` (в том числе при ошибке удаления после перехода на
  локальную конфигурацию) процесс снимает блокировку сеанса: дальше команды других
  процессов ждут, как в local-режиме.
  Устаревший лок удаляет только один выбранный процесс после повторной проверки
  владельца; новый живой лок не переименовывается и не удаляется.
  Если `SIGKILL` прервёт саму очистку, может остаться `.rc-lock/.reclaim`.
  Захват безопасно завершается с `locked` и полным путём к этому каталогу:
  удаляйте его вручную только убедившись, что других операций нет.
- **Коды выхода**: `0` — успех; `1` — ошибка; `2` — неверное использование,
  нужно решение (`*_required`, `plan_changed`) или неизвестный ключ сервера; для
  `telegram` ещё `3` — компонент не установлен, `4` — выполнено частично
  (результаты по нодам в `data.results`).
- **Окружение**: `RC_SCRIPT_PASSWORD`, `RC_VAULT_PASSWORD`, `RC_LOCK_WAIT`.
- **Справка**: `--help`/`-h` в позиции флага возвращают справку по сущности;
  значение флага (`--name -h`) справкой не считается.

Только редактирование шаблона редактором остаётся за терминальным меню: оно
сохраняет изменения командой `template import`. Меню сервера (`node shell`) и
Telegram одной ноды (`telegram menu`) требуют терминала (`tty_required` без него).

В Windows `remote-control.cmd` передаёт аргументы в WSL:
`remote-control.cmd node list --json`.

### Каталог команд

Таблицы сформированы по справке (`--help`). `…` — ключ `--yes [--plan-token T]`
у команды с подтверждением; `help [СУЩНОСТЬ]` и `serve` описаны выше.

### Источник (`source`)

| Команда | Описание |
|---|---|
| `source init-local` | Создать локальную конфигурацию |
| `source status` | Источник: тип, репозиторий, ветка, хранение, синхронизация |
| `source github-accounts` | Сохранённые аккаунты GitHub и глобальный вход gh |
| `source github-login --login L` | Войти в GitHub через браузер (код устройства — в журнале) |
| `source github-connect --login L [--create-repo] [--make-private] [--storage age\|none] [--existing remote\|local\|migrate] [--provision-keys yes\|no] [--remember-key] [--yes]` | Подключить GitHub (секреты vault-password, new-vault-password) |
| `source github-fetch` | Загрузить конфигурацию из GitHub |
| `source github-push` | Отправить конфигурацию в GitHub |
| `source github-change-account --login L [--create-repo] [--make-private] [--storage age\|none] [--existing remote\|local] [--without-cache] [--replace-target] [--yes]` | Сменить аккаунт GitHub (секреты vault-password, new-vault-password) |
| `source github-rewrap-password` | Сменить пароль доступа (секреты vault-password, new-vault-password) |
| `source github-rotate-key [--yes]` | Новый ключ шифрования (секрет new-vault-password) |
| `source github-import-recovery-key --file PATH` | Импортировать ключ восстановления для текущего сеанса |
| `source github-switch-local` | Работать локально без синхронизации с GitHub |
| `source github-replace-with-local [--provision-keys yes\|no] [--yes]` | Заменить конфигурацию GitHub конфигурацией этого компьютера (секреты script-password, vault-password) |
| `source github-migrate-format [--yes]` | Преобразовать конфигурацию GitHub в текущий формат (секреты script-password, vault-password) |
| `source github-delete-repo [--yes]` | Удалить репозиторий GitHub (конфигурация останется локально) |

### Сессия (`session`)

| Команда | Описание |
|---|---|
| `session status` | Состояние: создана ли конфигурация, открыта ли сессия |
| `session open [--remember-key]` | Открыть источник и проверить пароль запуска (секреты script-password, vault-password) |

### Сводка (`status`)

| Команда | Описание |
|---|---|
| `status` | Сводка: версия, источник, счётчики, проблемы |

### Ноды (`node`)

| Команда | Описание |
|---|---|
| `node list` | Список нод |
| `node show --name N` | Подробности ноды и варианты удаления |
| `node aliases --name N [--set ORIG=ALIAS…] [--unset ORIG…]` | Псевдонимы подключений (без --set/--unset — обнаружить по SSH) |
| `node rename --name N --new-name M` | Переименовать ноду (имя: латиница, цифры, «.», «_», «-») |
| `node tag --name N --tag T` | Задать тег ноды (пустой допустим; до 32 символов, без управляющих и служебных символов) |
| `node password --name N` | Сохранить пароль SSH (секрет password: --password-stdin) |
| `node add --name N --ip IP [--port 22] [--user root] --auth key\|password --tag T [--host-key SHA256:… \| --accept-new-host-key] [--replace-host-key SHA256:… [--yes]] [--defer-ssh-setup]` | Добавить ноду (для --auth password — секрет password) |
| `node trust-host-key --name N --host-key SHA256:… [--yes]` | Доверять новому ключу сервера ноды |
| `node delete --name N [--scope local\|server] [--revoke-key] [--yes]` | Удалить ноду |
| `node check --name N` | Проверить SSH-подключение |
| `node upload-scripts --name N [--force [--yes]]` | Загрузить скрипты на ноду |
| `node harden --name N [--port P] [--yes]` | Усилить защиту SSH: ключ, отключение пароля, новый порт (подтверждение планом — только с --port) |
| `node setup-ssh [--provision-keys yes\|no] [--on-failure rollback\|defer] [--yes]` | Завершить отложенную SSH-настройку нод (GitHub) |
| `node shell --name N` | Открыть меню сервера по SSH (нужен терминал) |

### Подключения (`conn`)

| Команда | Описание |
|---|---|
| `conn list [--node N [--discover]]` | Подключения нод по группам |
| `conn set --node N --group G… [--proxy P…]` | Назначить подключения группам (без --proxy — снять) |
| `conn sync [--node N]` | Обнаружить подключения нод по SSH и убрать устаревшие назначения |

### AmneziaWG (`awg`)

| Команда | Описание |
|---|---|
| `awg status --node N` | Клиенты AmneziaWG на ноде |
| `awg sync --node N` | Создать недостающих клиентов AmneziaWG |
| `awg remove --node N (--peer P… \| --orphans) [--yes]` | Удалить клиентов AmneziaWG |

### Telegram Proxy (`telegram`)

| Команда | Описание |
|---|---|
| `telegram status [--node N… \| --all]` | Состояние Telegram Proxy |
| `telegram install\|refresh-ip\|web-update\|web-restart\|backend-restart (--node N… \| --all) [--yes]` | Действия Telegram Proxy |
| `telegram remove --component web\|mtproto (--node N… \| --all) [--yes]` | Удалить компонент Telegram Proxy |
| `telegram remove-all (--node N… \| --all) [--yes]` | Удалить Telegram Proxy целиком |
| `telegram menu --node N [--yes]` | Серверное меню Telegram Proxy одной ноды (нужен терминал) |

### Клиенты (`client`)

| Команда | Описание |
|---|---|
| `client list [--group G]` | Список клиентов |
| `client show --name C` | Подробности клиента (с секретами) |
| `client connections --name C [--node N (--proxy P… \| --reset [--yes])]` | Подключения клиента |
| `client add --name C --group G` | Добавить клиента |
| `client rename --name C --new-name D [--yes]` | Переименовать клиента |
| `client nodes --name C (--inherit [--yes] \| --node N…)` | Ноды клиента |
| `client set-group --name C --group G [--yes]` | Сменить группу клиента |
| `client delete --name C… [--yes]` | Удалить клиентов |

### Группы (`group`)

| Команда | Описание |
|---|---|
| `group list` | Список групп |
| `group add --name G` | Добавить группу |
| `group delete --name G [--yes]` | Удалить группу |
| `group set-template --name G --template T` | Назначить шаблон группе |

### Шаблоны (`template`)

| Команда | Описание |
|---|---|
| `template list` | Список шаблонов |
| `template show --name T` | Показать шаблон |
| `template create --name N [--from T] [--group G]` | Создать шаблон на основе другого |
| `template export --name T --output PATH [--yes]` | Сохранить шаблон в файл |
| `template import --name T --file PATH [--yes]` | Загрузить шаблон из файла |

### Генерация (`generate`)

| Команда | Описание |
|---|---|
| `generate (--all \| --group G \| --client C)` | Сгенерировать конфиги |

### Подписки (`sub`)

| Команда | Описание |
|---|---|
| `sub host [--node N]` | Хост-нода подписок (с --node — задать) |
| `sub list` | Список подписок |
| `sub show --client C` | Ссылка и заголовки подписки |
| `sub headers (--client C \| --group G \| --default) [--set NAME=VALUE…] [--unset NAME…]` | Заголовки подписки |
| `sub publish --client C [--ttl 30d]` | Опубликовать подписку (TTL: 12h, 30d, 2w) |
| `sub publish-all [--yes]` | Опубликовать все готовые подписки и удалить с хоста подписки без клиента |
| `sub rotate --client C [--yes]` | Перевыпустить ссылку |
| `sub revoke --client C [--yes]` | Отозвать подписку |
| `sub migrate --node N [--yes]` | Перенести подписки на другую ноду |

Проверки имён и секретов клиентов:

- `group add` — `invalid`, если имя после перевода в верхний регистр не
  `[A-Za-z0-9._-]+` или состоит из одних точек. Сохранённые имена клиентов и групп
  перепроверяются: с непригодным именем `client rename|delete|set-group|show` и
  `sub publish|rotate|publish-all|migrate` отвечают `invalid`, а `generate` относит
  такого клиента к `failed` (`partial`). Каталоги конфигов изменяются и удаляются
  только внутри `generated/`.
- Учётные данные клиента: uuid VLESS — канонический (8-4-4-4-12 hex), пароль HY2 —
  `[A-Za-z0-9_-]{1,128}`, токен подписки — 64 строчных hex. Непригодное значение
  останавливает генерацию для клиента и синхронизацию пользователей ноды (ничего не
  отправляется); непригодный токен — `invalid` (`client delete` — `remote_failed`).
  Учётные данные и токены не попадают в argv процессов: jq и ssh получают их через
  stdin или временный файл 0600.
- `client nodes --inherit` при собственных нодах или подключениях клиента отвечает
  `confirmation_required` с их списком; без них подтверждение не нужно.
- `sub publish-all`: при наличии публикуемых подписок — read-only просмотр каталога
  хоста, затем план (цели, число и 8-символьные префиксы осиротевших токенов) и
  `confirmation_required`; `--yes` удаляет только осиротевшие файлы из плана, файлы с
  именами не-токенами не трогаются. Нет ни одного локального токена, а на хосте
  подписки есть — `failed` без изменений. Нечего публиковать — ни SSH, ни
  подтверждения.
- `sub headers --set`: имя заголовка — только `[A-Za-z0-9-]`. Сохранённые заголовки
  перепроверяются перед каждой публикацией, непригодные — `invalid`, ничего не
  загружается.
- `template export`: висячая символьная ссылка в `--output` тоже требует
  подтверждения.
- `sub publish` без `--ttl` сохраняет срок существующей подписки и её запись в
  `expiry.list`; с `--ttl` запись заменяется. Сбой записи срока после загрузки —
  новая подписка удаляется с хоста (`remote_failed`), у существующей остаётся прежний
  срок. Сбой проверки HTTP 200 после сохранения в `sub publish`/`sub rotate` —
  `partial` с `client`, `url` (и `expires_at` для publish); изменение сохранено.
- `sub publish-all`: сбой сохранения токена после хотя бы одного сохранённого —
  `partial` (`published` — клиенты с сохранённым токеном, `failed` — остальные); ни
  одного — `failed`. Сбой очистки осиротевших файлов — `partial`.
- `sub headers`: все пары `--set`/`--unset` проверяются заранее и записываются одной
  операцией; при любой ошибке ничего не меняется.
- `client delete`: клиенты AmneziaWG удаляются по имени на всех нодах, в подключениях
  которых есть AmneziaWG; сбой после любого отзыва или удаления AWG — `partial` с
  `{deleted, revoked, awg_nodes}`.
- `client rename`: `conflict`, если каталог конфигов с новым именем уже есть. Если у
  клиента есть ноды с AmneziaWG — `confirmation_required` с планом (клиент AmneziaWG
  со старым именем и эти ноды); после `--yes` он удаляется там и создаётся заново
  при следующем `generate`; сбой удаления — `partial` с `{name}`. Без AmneziaWG
  подтверждение не нужно.
- `client set-group`: план называет ноды, где будет удалён клиент AmneziaWG;
  `partial` содержит `{name, group}`.
- `client connections --reset`: `invalid` до плана, если у клиента нет своих нод или
  нода ему не назначена.

### Сам remote-control (`self`)

| Команда | Описание |
|---|---|
| `self version` | Текущая и последняя версия |
| `self update [--yes]` | Обновить remote-control до последней версии |
| `self uninstall [--remove-data] [--yes]` | Удалить remote-control (данные сохраняются без --remove-data) |
| `self password-set` | Установить или сменить пароль запуска (секреты password, current-password) |
| `self password-remove [--yes]` | Убрать пароль запуска (секрет current-password) |

---

## Главное меню

Без аргументов скрипт запускает терминальное меню — отдельный процесс
`remote-control/tui/main.sh`. Он запускает `serve` дочерним процессом и получает
данные только командами ядра; логики управления в нём нет. Правила экранов:

- каждый экран перерисовывает полный кадр (заголовок → разделитель → контекст →
  разделитель → действия); данные читаются командой в начале каждой итерации;
- `0` и EOF возвращают на предыдущий экран; Enter и неизвестный ввод печатают
  «Неверный выбор.» и оставляют экран; буквы принимаются в обоих регистрах;
- раздел ведёт от списка к карточке, а карточка собирает все действия над объектом;
  исчезновение объекта возвращает к списку;
- опасное действие сначала показывает план из ответа команды
  (`confirmation_required`) и один вопрос с ответом «нет» по умолчанию; согласие
  повторяет команду с `--yes --plan-token`, изменившийся план показывается заново;
- сообщение об ошибке печатает журнал ядра, меню его не повторяет; сбой оставляет
  экран доступным, автоматического повтора нет;
- пароли вводятся скрытно и уходят в ядро только полем `secrets`;
- Ctrl+C в меню закрывает сессию и выходит; во время команды он её не прерывает.

Пункты меню целиком (клавиша и название) окрашены по назначению:
**CYAN** — переход и просмотр, **GREEN** — создание, **YELLOW** — изменение,
**RED** — удаление и отзыв; навигационный `0` — без окраски.

### Запуск и вход

Первый запуск без конфигурации — экран «Первый запуск»: `1` «Локальная
конфигурация» (`source init-local`), `2` «Конфигурация в GitHub» (мастер GitHub),
`0` «Выход». Затем меню открывает сессию (`session open`):

- пароль доступа к GitHub и вопрос «Сохранить ключ расшифровки на этом
  устройстве?»; после трёх неверных паролей — меню восстановления;
- пароль запуска (три попытки, затем меню восстановления доступа);
- `github_format_*` — экран «Конфигурация GitHub требует восстановления»:
  «Преобразовать конфигурацию» (`source github-migrate-format`, только для
  устаревшего формата), «Заменить конфигурацией с этого устройства»
  (`source github-replace-with-local`), «Выход»;
- `locked` и прочие сбои открытия — меню восстановления.

### Сводка

Заголовок `Remote Control vX`; при доступном обновлении — строка «Доступно
обновление vY — раздел o». Контекст: источник (локальная или `GitHub owner/repo` и
статус «синхронизировано», «ожидает отправки», «нет связи»); счётчики нод, клиентов
и групп; хост подписок; предупреждения «Нет пароля SSH: …» и «Отложена SSH-настройка
нод — раздел n → h». Данные — команда `status`.

| Клавиша | Раздел |
|---|---|
| `n` | Ноды |
| `c` | Клиенты |
| `g` | Группы |
| `m` | Шаблоны |
| `p` | Подключения |
| `f` | Генерация конфигов |
| `s` | Подписки |
| `a` | AmneziaWG |
| `t` | Telegram Proxy |
| `i` | Источник конфигурации |
| `o` | Настройки |
| `0` | Выход |

### Ноды (`n`)

Список `имя  IP:порт` (жёлтым — ноды без сохранённого пароля или с проблемами
переносимости; данные `node list`, `status`) → карточка. В списке: `a` — добавить
ноду, `h` — завершить отложенную SSH-настройку (только если она ожидает).

**Карточка ноды** (`node show`): адрес, пользователь, вход по ключу или паролю, тег,
наличие пароля SSH, проблемы настройки, группы, число клиентов.

| Клавиша | Действие | Команда |
|---|---|---|
| `o` | Меню сервера | `node shell` |
| `t` | Telegram Proxy на ноде | `telegram menu --node N` (после подтверждения загрузки скриптов) |
| `p` | Подключения ноды | экран «Подключения ноды» |
| `a` | Клиенты AmneziaWG | экран «AWG ноды» |
| `k` | Проверить подключение | `node check` |
| `u` | Загрузить скрипты принудительно | `node upload-scripts --force` (с планом и подтверждением) |
| `h` | Усилить защиту SSH | `node harden` |
| `r` | Переименовать | `node rename` |
| `e` | Тег | `node tag` |
| `w` | Пароль SSH (для входа по паролю) | `node password` (секрет `password`) |
| `l` | Псевдонимы подключений | `node aliases` |
| `d` | Удалить ноду | `node delete --scope … [--revoke-key]` — объём выбирается из `delete_options` ответа `node show` |

Ошибки ноды решает меню: `missing_secret` — предложение сохранить пароль,
`host_key_changed` — показ отпечатков и `node trust-host-key` после
подтверждения, `needs_setup` — подсказка перейти к `n → h`.

**Добавление ноды.** Вопросы по порядку: название, IP, SSH-порт, логин, способ
входа («SSH-ключ» или «Пароль»), пароль, тег. Затем `node add … --accept-new-host-key`.
`host_key_changed` — рамка с хостом и отпечатками, затем план `node add …
--replace-host-key` и подтверждение (повтор с `--yes --plan-token`); `remote_failed` — «Повторить попытку?» (для
парольной ноды можно ввести новый пароль); `onboarding_failed` — «Повторить» или
«Сохранить ноду и настроить позже» (`--defer-ssh-setup`).

**Усиление SSH.** `node harden` без `--yes` возвращает план и порт; меню спрашивает
порт (Enter — предложенный), при другом порте строит новый план (`invalid` и
`port_in_use` — вопрос заново), затем один вопрос «Усилить защиту SSH?».
`hardening_failed` с `console_required` — предупреждение проверить доступ через
консоль провайдера.

**SSH-настройка.** `node setup-ssh`: `key_provisioning_required` — список нод и
вопрос «Создать переносимый SSH-ключ для этих нод?»; затем план и подтверждение.
План перечисляет по каждой ноде отпечаток закрепляемого ключа сервера («Ключ
сервера NAME (IP:PORT) будет закреплён: SHA256:…» или «…прочитать не удалось:
закрепление не выполнится.»); закрепляются только ключи из плана, иной ключ —
`onboarding_failed` (этап `pin`). `onboarding_failed` — «Повторить» или «Отложить
проблемные ноды» (`--on-failure defer`).
Проверка и закрепление согласованного ключа сервера выполняются до установки
переносимой identity и любой аутентификации. При несовпадении ключа режим
`defer` оставляет ноду с отложенной SSH-настройкой, не подключаясь к ней.

**Псевдонимы.** Для каждого найденного подключения вводится псевдоним (Enter —
оставить, `-` — убрать), затем один вызов `node aliases --set … --unset …`.

### Клиенты (`c`)

Список `имя  (ГРУППА)` (`client list`) → карточка. `a` — добавить клиента (имя и
группа → `client add`), `d` — удалить клиентов (мультивыбор без предварительных
отметок → `client delete` с подтверждением).

**Карточка клиента**: группа, ноды (от группы или свои), подписка. Секреты не
показываются.

| Клавиша | Действие | Команда |
|---|---|---|
| `v` | Показать данные подключения (явный запрос; секреты показываются) | `client show` |
| `s` | Подписка | экран «Подписка клиента» |
| `f` | Сгенерировать конфиг | `generate --client` |
| `n` | Ноды клиента: назначить или изменить свои (отмечены текущие), вернуть от группы | `client nodes --node …` / `--inherit` |
| `p` | Подключения по нодам (только для клиента со своими нодами): настроить найденные прокси или сбросить на групповые | `conn list --discover`, `client connections` |
| `g` | Сменить группу | `client set-group` (с планом) |
| `r` | Переименовать | `client rename` (с планом, если удаляется клиент AmneziaWG) |
| `d` | Удалить клиента | `client delete` (с планом) |

При частичном удалении карточка закрывается, только если клиент указан в `data.deleted`.
В просмотре пустой список нод обозначается «нет», пустые подключения не образуют
отдельную секцию. Выбор ноды для подключений показывает её адрес и порт; исчезнувшие
ноды исключаются из выбора.

**Подписка клиента**: `p` опубликовать (срок `12h`, `30d`, `2w` или без срока →
`sub publish`, затем ссылка, QR и заголовки), `v` показать ссылку (`sub show`),
`i` итоговые заголовки с источниками (`sub headers --client`), `h` заголовки
клиента, `r` сменить токен (`sub rotate`), `x` отозвать (`sub revoke`).
**Заголовки** (`sub headers --client|--group`): `a` установить (`--set NAME=VALUE`),
`d` удалить собственный заголовок (`--unset NAME`).
Источники заголовков в меню показаны как «по умолчанию», «группа» и «клиент»;
машинные значения остаются `default`, `group`, `client`.

### Группы (`g`)

Список `ИМЯ  (шаблон)` (`group list`) → карточка; `a` — добавить группу
(`group add`). **Карточка группы**: шаблон, число клиентов, ноды. `t` — выбрать шаблон
(`group set-template`) или создать новый (`template create --group`, затем
редактор), `h` — заголовки подписки группы, `f` — сгенерировать конфиги группы
(`generate --group`), `d` — удалить группу (`group delete` с планом).

### Шаблоны (`m`)

Список `имя  (встроенный|пользовательский)` (`template list`) → карточка; `a` —
создать шаблон (`template create`, затем редактор). **Карточка шаблона**: источник и
группы. `v` показать (`template show`), `e` редактировать, `x` экспорт в файл
(`template export`), `i` импорт из файла (`template import`).
В путях интерактивного импорта и экспорта `~` и `~/` обозначают домашний каталог;
прочие shell-выражения не разворачиваются.

**Редактор.** Меню читает `template show`, пишет содержимое во временный файл
(права 600) и запускает `${VISUAL:-${EDITOR:-}}`, иначе `nano`, иначе `vi`, с
терминала. Без изменений — «Изменений нет.»; иначе `template import --name N
--file TMP --yes`: правка файла сама является явным согласием. Временные файлы
удаляются на любом исходе.

Каталог редактора (0700) находится внутри управляемого TUI tmp; обе копии шаблона
создаются с правами 0600 независимо от umask вызывающего shell. EXIT-cleanup убирает
их и при Ctrl+C. Состояние tty сохраняется и восстанавливается после редактора
и интерактивного SSH при успехе, ошибке и выходе по сигналу.

### Подключения (`p`)

Только при входе и по `s` выполняется `conn sync` (SSH-обнаружение и удаление
устаревших назначений, данные берутся и при `partial`). Перерисовка и возврат из
подэкрана ничего не меняют: назначения читаются `conn list`, найденные прокси и
доступность — из последней синхронизации. Для каждой ноды показано покрытие по
группам `ГРУППА: назначено/найдено` (зелёный — всё назначено, жёлтый — частично,
тусклый — неизвестно или нет), недоступные ноды — «недоступна». Список нод →
**подключения ноды** (`conn sync --node` при входе и по `s`, перерисовка —
`conn list --node`): найденные прокси с метками групп; `b` — назначить
подключения группам (мультивыбор прокси и групп → `conn set`; пустой выбор —
«Ничего не выбрано.»), `l` — псевдонимы подключений, `s` — синхронизировать с нодой.

### Генерация (`f`)

Строки `ГРУППА → шаблон` (`group list`). `a` — всем клиентам (`generate --all`),
`g` — по группе, `c` — одному клиенту. После команды (в том числе при `partial`)
показывается итог: готово, пропущено, ошибки, ноды с ошибкой, каталог.
Нода без VLESS/Hysteria2 listener'ов (например, только с AmneziaWG) не считается
ошибочной: пустой список пользователей пропускается, mihomo перезапускается.

### Подписки (`s`)

Хост-нода и базовый URL (`sub host`). `h` — выбрать хост-ноду (`sub host --node`),
`l` — список подписок (`sub list`: клиент, срок, состояние), `u` — обновить все
подписки (`sub publish-all`, затем итог), `m` — перенос на другую ноду
(`sub migrate` с планом), `c` — подписка клиента, `g` — заголовки группы.
Если опубликованных подписок нет, перенос сообщает об этом и не меняет хост.
При выборе хоста исправляемые ошибки ноды предлагается разрешить на месте.

### AmneziaWG (`a`)

Список нод → экран ноды (`awg status`): используемые клиенты, неиспользуемые
(«не используется») и ещё не созданные («не создан»); если AmneziaWG не
установлен — пояснение. `r` — обновить; при установленном AmneziaWG: `c` —
создать недостающих (`awg sync`), `d` — удалить клиента (`awg remove --peer`),
`x` — удалить неиспользуемых (`awg remove --orphans`) — оба с планом и подтверждением.

### Telegram Proxy (`t`)

| Клавиша | Действие | Команда |
|---|---|---|
| `o` | Управление одной нодой | `telegram menu --node N` |
| `s` | Общий статус нод | `telegram status --all` |
| `i` | Включить MTProto Proxy | `telegram install` |
| `p` | Обновить IP-адрес MTProto | `telegram refresh-ip` |
| `w` | Обновить Web Proxy | `telegram web-update` |
| `r` | Перезапустить Web Proxy | `telegram web-restart` |
| `b` | Перезапустить службу MTProxy | `telegram backend-restart` |
| `d` | Отключить способ доступа (Web Proxy или MTProto Proxy) | `telegram remove --component` |
| `x` | Отключить Telegram Proxy полностью | `telegram remove-all` |

Пакетные действия выбирают ноды мультивыбором без предварительных отметок и
выполняются через подтверждение плана; после ответа печатается таблица
«нода  статус  причина» по `data.results` (в том числе при `not_installed` и
`partial`).

### Источник конфигурации (`i`)

Локальная конфигурация: `g` — подключить GitHub (мастер). GitHub: репозиторий, ветка,
хранение (зашифровано или без шифрования), синхронизация; `f` — загрузить из
GitHub (`source github-fetch`), `p` — отправить (`source github-push`), `c` —
сменить аккаунт (мастер, `source github-change-account`), для режима `age`: `r` —
сменить пароль доступа (`source github-rewrap-password`) и `v` — новый ключ
шифрования (`source github-rotate-key`), `k` — импортировать ключ восстановления
(`source github-import-recovery-key`), `e` — работать локально без синхронизации
(`source github-switch-local`), `l` — заменить GitHub локальной конфигурацией
(`source github-replace-with-local`), `d` — удалить репозиторий
(`source github-delete-repo`; опасные — с планом и подтверждением).

**Мастер GitHub** выбирает аккаунт (сохранённые, глобальный `gh`, «Указать другой
логин») и повторяет `source github-connect` или `source github-change-account`,
накапливая решения по кодам: `github_auth_required` — вход через браузер
(`source github-login`), `repo_create_required`, `repo_private_required`,
`storage_mode_required` (age или без шифрования), `new_vault_password_required`,
`existing_config_action_required` (использовать GitHub, заменить локальной,
преобразовать), `vault_password_required` и вопрос о сохранении ключа,
`cache_skip_required`, `target_replace_required`, `key_provisioning_required`.
`repo_private_required`, `target_replace_required` и выбор «заменить локальной»
своих вопросов не задают: флаг ставится сразу, а согласие даётся одним
подтверждением плана команды (повтор с `--yes --plan-token`).

### Настройки (`o`)

Версия, последняя доступная версия (`self version`), статус пароля запуска.
Версия проверяется один раз при входе в раздел; при перерисовках обновляется
статус пароля, но сетевой запрос проверки версии не повторяется.
`u` — обновить remote-control (`self update`, только при доступном обновлении),
`l` — установить или сменить пароль запуска (`self password-set`), `r` — убрать
(`self password-remove`), `x` — удалить remote-control с сохранением или удалением
локальных данных (`self uninstall`). После обновления или удаления меню
завершается.

---

## Telegram Proxy на нодах

`telegram menu --node N` открывает серверное меню Telegram Proxy одной ноды по SSH
с терминалом (ссылки, смена секрета, Спонсорский тег, диагностика); без терминала
команда отвечает `tty_required`. Локальной копии single-node меню нет. Если
установленная версия не поддерживает `telegram-proxy menu`, команда отвечает
`not_ready` — загрузите скрипты принудительно (`node upload-scripts --force`);
VERSION не меняется в рамках обновления из меню.

Одиночный вход использует такой же read-only preflight и зафиксированный план,
как пакетные команды: SSH-параметры ноды, VERSION и SHA-256 локального комплекта.
Отсутствующие или более старые скрипты загружаются только после подтверждения
плана (`confirmation_required`, `--yes --plan-token`); без согласия загрузка и
открытие серверного меню не выполняются. Для равной или более новой версии вопрос
не задаётся. Изменение локального комплекта после согласия (`plan_changed`), сбой
загрузки или несовпадение опубликованной версии блокируют SSH-меню; повреждённая,
неизвестная или недоступная установка исключается без изменений.

Пакетные команды `telegram status|install|refresh-ip|web-update|web-restart|backend-restart|remove|remove-all`
принимают `--node N…` или `--all`. Read-only preflight проверяет все выбранные ноды,
замораживает их SSH-параметры, локальный VERSION и SHA-256 комплекта скриптов.
Отсутствующие или более старые скрипты отмечаются для загрузки; недоступная,
повреждённая или неизвестная установка исключается и получает ошибку в итогах;
доступные ноды продолжают работу.

Подтверждение плана запрашивается **после** preflight: для установки MTProto Proxy,
отключения способов доступа, полного удаления или любой загрузки скриптов. План
перечисляет все цели, загрузки и исключения, без секретов; без `--yes` workers не
запускаются и ноды не меняются. Обновление IP, обновления и перезапуски без загрузки
скриптов вопросов не задают. Установка напоминает про разрешённый TCP/2398 и
закрытый TCP/8888 у провайдера.

Workers используют только согласованный снимок, не перечитывают конфигурацию нод
и ничего не спрашивают. После загрузки сервер должен подтвердить точно согласованную
версию. Порядок выбора сохраняется, одновременно работают не больше четырёх
workers. `--force` получают только установка MTProto Proxy и удаления; пакетные
команды не печатают ссылки и секреты.

SSH-пароль, node ID и identity передаются через одноразовый base64-файл с
`umask 077`; plaintext в FIFO и result files не пишется. Вывод маскируется
до сохранения, снимки паролей очищаются на всех путях выхода. Результаты по
нодам — `data.results` (`ok`, `not_installed`, `partial`, `error`). Коды выхода
сохраняются: `0` — успех, `1` — ошибка подготовки/протокола, `3` — не установлен,
`4` — неисправность служб или внешняя недоступность; приоритет `1 > 4 > 3 > 0`.
Статус отдельно показывает состояние на ноде и внешнюю доступность;
неполные проверки помечаются «не проверено». Успешные сообщения загрузки скриптов
не попадают в данные ответа статуса; ошибки загрузки сохраняются в маскированной
диагностике и блокируют запрос статуса. Автоматического повтора нет.

## Концепции

### Ноды

Нода — это VPS-сервер с установленным essence-setup. Хранит SSH-креды (локальный пароль шифруется AES-256-CBC), имя, IP, порт, опциональный тег (`DE`, `RU` и т.п.). Выбор ноды открывает её карточку; SSH-сессия запускается только действием «Меню сервера» (`node shell`).

Переименование ноды (`node rename`) обновляет ссылки в подключениях, клиентах и хостинге подписок. Удаление (`node delete`) предлагает объём: только локальная запись, удаление компонентов на ноде и/или отзыв управляемого SSH-ключа (варианты возвращает `node show` в `delete_options`). План показывает все цели; без `--yes` ничего не меняется. Если серверное удаление или отзыв ключа не подтверждены, локальная нода сохраняется.

### Группы

Группа — тип устройства. По умолчанию: **ROUTER**, **PC**, **MOBILE**.

Каждой группе назначается шаблон (по умолчанию `default.yaml`). Блоки шаблона, помеченные именем группы, попадают в конфиги клиентов этой группы (см. раздел [Шаблоны](#шаблоны)).

Список нод группы **производный** — высчитывается из `.connections[]`: группа считается активной на ноде, если в ней есть хоть один прокси этой ноды. Явного поля `.groups[].nodes` нет.


### Клиенты

Клиент — конкретное устройство (роутер, телефон, ноутбук). Привязан к группе. При создании (`client add`) автоматически получает:

- `vless_uuid` (генерируется `uuidgen`)
- `hy2_password` (генерируется `openssl rand -hex 16`)

Эти креды подставляются в сгенерированный конфиг и синхронизируются на ноды при генерации (`_sync_listeners_on_nodes`), чтобы каждый клиент имел свой идентификатор на сервере.

По умолчанию клиент наследует ноды от группы (`inherit_nodes_from_group: true`). Команды клиента позволяют:

- **Назначить свои ноды** — отвязать от группы и указать явный `.clients[].nodes[]` (`client nodes --node …`; вернуть — `client nodes --inherit`)
- **Настроить кастомные подключения** — per-node выбор прокси (`client connections --node N --proxy …`; сброс — `--reset`)
- **Поменять группу** — `client set-group`, с автосинком listeners на старых и новых нодах
- **Переименовать клиента** — `client rename`, с миграцией директории сгенерированных конфигов и удалением клиента AmneziaWG со старым именем (по плану)

### Подключения нод для групп (Connections)

Каждая нода может иметь несколько подключений: VLESS TCP/xHTTP/gRPC, Hysteria2, AmneziaWG, каскадные ноды. Не все из них нужны всем группам.

Раздел **p** главного меню и команды `conn`:

1. `conn sync [--node N]` по SSH читает `/etc/mihomo/client-config.txt` нод, обнаруживает подключения и убирает устаревшие назначения. Недоступные ноды пропускаются, первая ошибка сохранения останавливает синхронизацию; при ошибках ответ — `partial`, данные (по нодам: `status`, найденные, удалённые, группы) сохраняются.
2. `conn list [--node N [--discover]]` показывает назначения без SSH; с `--discover` добавляет найденные на ноде подключения.
3. `conn set --node N --group G… [--proxy P…]` назначает подключения группам (без `--proxy` — снимает).

Покрытие по группам в меню показано цветом (зелёный/жёлтый/тусклый).

```
de-vps:
  VLESS TCP — ROUTER PC MOBILE
  VLESS xHTTP — PC MOBILE
  HY2 — ROUTER PC
  AWG (не назначено)
```

Stale-подключения (прокси, удалённые на сервере) автоматически вычищаются из `.connections[]` при каждой синхронизации.

Назначение подключения группам сохраняется отдельной операцией. Для GitHub после успешной записи сразу выполняются checkpoint и попытка синхронизации; при недоступном GitHub изменение остаётся локально в состоянии «ожидает отправки».

### Клиенты AmneziaWG

Команды `awg` (раздел **a** меню):

- `awg status --node N` — по ноде: установлен ли AmneziaWG и список клиентов (используемые, неиспользуемые `orphan`, отсутствующие `missing`) относительно ожидаемого набора;
- `awg sync --node N` — создать недостающих клиентов одной пакетной операцией;
- `awg remove --node N (--peer P… | --orphans)` — удалить клиентов (с планом и подтверждением).

Ожидаемый набор определяется клиентами группы, которой на ноде назначено подключение `AWG`. Перед SSH команды проверяют ноду (`ssh_probe`).

### Шаблоны

Шаблон — YAML-файл с полным конфигом mihomo, в котором блоки для разных групп обёрнуты маркерами.

#### Формат маркеров

```yaml
# --- ROUTER ---
redir-port: 1182
tproxy-port: 1181
# --- ROUTER ---

# --- PC/MOBILE ---
tun:
  enable: true
  stack: mixed
# --- PC/MOBILE ---
```

- `# --- ГРУППА ---` ... `# --- ГРУППА ---` — начало и конец блока
- `# --- ГРУППА1/ГРУППА2 ---` — блок активен для нескольких групп (разделитель `/`)
- При генерации: если группа клиента входит в список — содержимое остаётся, маркеры убираются. Если не входит — **весь блок удаляется**

#### Управление шаблонами

- Встроенные шаблоны: `remote-control/templates/*.yaml`; пользовательские копии: каталог `templates/` активного состояния
- Просмотр и список: `template show`, `template list`; создание на основе другого — `template create --name N [--from T] [--group G]`; обмен файлами — `template export` и `template import`
- Редактирование: терминальное меню (раздел **m** → карточка шаблона → `e`) открывает редактор и сохраняет результат командой `template import` — встроенный шаблон сначала копируется в пользовательское состояние
- Назначение группе: `group set-template --name G --template T`

---

## Усиление защиты SSH

Команда `node harden --name N [--port P]` (карточка ноды → `h`):

1. Создаёт переносимый SSH-ключ ed25519 и копирует открытый ключ на сервер
2. Проверяет вход по новому ключу
3. Отключает вход по паролю (`PasswordAuthentication no`)
4. Меняет SSH-порт на случайный свободный (49152–65535) или на указанный `--port`
5. Обновляет UFW/firewalld и проверяет подключение на новом порту

Без `--yes` команда возвращает план и порт (`confirmation_required`); занятый порт — `port_in_use`, неверный — `invalid`. Проверяемые изменения откатываются при ошибке (`hardening_failed` с этапом, признаками `rolled_back` и `console_required`). Команда `node setup-ssh` («Завершить отложенную SSH-настройку» в списке нод) доступна только в режиме GitHub и только после отложенной настройки — пока не готовы SSH-ключи или ключи серверов, необходимые для синхронизации через GitHub; нет отложенной настройки — `nothing_pending`.

---

## Генерация конфигов

Команда `generate (--all | --group G | --client C)` (раздел **f** меню):

- `--group G` — обновить конфиги всех клиентов группы
- `--all` — полный пересчёт по всем группам
- `--client C` — один клиент

### Что происходит при генерации

1. Берётся шаблон группы
2. Удаляются блоки, не относящиеся к группе клиента
3. Для каждой ноды клиента скрипт забирает proxy-конфиги с сервера (кешируются на время сессии)
4. Прокси фильтруются по подключениям группы + per-client кредам (UUID, hy2 password)
5. Проверка на дубликаты proxy-имён
6. Готовый `config.yaml` сохраняется в `remote-control/.remote-data/generated/<group>/<client>/`
7. **Listener sync** — один SSH на каждую затронутую ноду: серверные листенеры обновляются, чтобы принимать per-client UUID/пароль
8. **Итог генерации** — данные ответа `{ok, skipped, failed, nodes_ok, nodes_failed, dir}`: готовые, пропущенные и ошибочные клиенты, результат синхронизации каждой ноды и каталог конфигов. При ошибках ответ — `partial`, данные сохраняются. Предыдущий конфиг сохраняется при ошибке. Публикация подписок выполняется отдельно (`sub publish`, раздел **s**), без дополнительного вопроса после генерации.

---

## Подписки

Раздел **s** главного меню и команды `sub`. Подписки публикуются через nginx на одной из нод
(хост-ноде); клиент получает YAML по адресу
`https://sub.example.com:<port>/sub/<token>`.

### Команды

| Команда | Действие |
|---|---|
| `sub host [--node N]` | Показать или назначить хост-ноду с установленным серверным модулем подписок; скрипт читает технические `base_url`, `sub_dir`, `nginx_group` |
| `sub publish --client C [--ttl 30d]` | Создать токен, загрузить YAML и конфигурацию nginx, проверить HTTP 200 |
| `sub publish-all [--yes]` | Пакетно обновить подписки и удалить осиротевшие файлы (по плану с подтверждением) |
| `sub show --client C` | URL, срок действия и итоговые HTTP-заголовки (токен показывается только по явному запросу) |
| `sub list` | Клиенты, сроки и состояния (`active`, `expired`, `unlimited`, `unknown`); токены скрыты |
| `sub rotate --client C [--yes]` | Создать новый токен и удалить старые файлы |
| `sub revoke --client C [--yes]` | Удалить файлы и токен из `config.json`; заголовки клиента сохранить |
| `sub migrate --node N [--yes]` | Перенести все подписки со старой ноды на новую |
| `sub headers (--client C \| --group G \| --default) [--set NAME=VALUE…] [--unset NAME…]` | Просмотр и изменение HTTP-заголовков клиента или группы |

Смена токена, отзыв и перенос — с планом и подтверждением (`--yes --plan-token`).

Если хост уже задан и существуют опубликованные токены, `sub host --node N`
не разрешает выбрать другую ноду: ответ `conflict` направляет в `sub migrate`,
конфигурация и публикации не меняются. Начальное назначение хоста, повторное
назначение той же ноды и смена хоста без опубликованных токенов допустимы.

### Наследование заголовков

```
default  (из .subscription_default_headers; если ключа нет — встроенные значения)
   ↓ переопределяется
group    (из .groups[].subscription_headers)
   ↓ переопределяется
client   (из .clients[].subscription.headers)
```

По умолчанию устанавливаются:

- `Content-Disposition: attachment; filename="config.yaml"` — имя файла при скачивании
- `profile-update-interval: 24` — интервал обновления у клиентов (mihomo / Clash.Meta)

Заголовки рендерятся в per-token nginx snippet с автоматическим квотированием (одинарные кавычки по умолчанию, двойные с escape при наличии одинарной кавычки в значении).

---
## Пошаговый гайд

В скобках — клавиши меню и эквивалентные команды.

### 1. Добавить ноду

**n → a** (`node add`) → ввести название, IP, SSH-порт и логин → выбрать **SSH-ключ** или **Пароль** → ввести тег → пройти проверку SSH; после неё нода сохраняется. При сбое подключения меню предлагает повторить попытку.

### 2. Настроить сервер

**n** → выбрать ноду → **o** «Меню сервера» (`node shell`) → настроить протоколы (VLESS, Hysteria2, AmneziaWG, WARP).

### 3. (Опционально) Усилить защиту SSH

В карточке ноды: **h** (`node harden`) → скрипт настроит переносимый ключ, отключит пароль и сменит порт.

Если настройка была отложена, в списке нод выберите
**h) Завершить отложенную SSH-настройку** (`node setup-ssh`). После подготовки SSH-ключей и
ключей серверов пункт автоматически исчезнет.

### 4. Назначить подключения группам

**p** → выбрать ноду → **b** → отметить подключения и группы (`conn set`).

### 5. Добавить клиентов

**c → a** (`client add`) → ввести имя → выбрать группу. Данные доступа сгенерируются автоматически.

### 6. Сгенерировать конфиги

**f → a** (всем) или **g** (по группе) (`generate`). Готовые конфиги в `remote-control/.remote-data/generated/`.

### 7. (Опционально) Опубликовать подписки

На хост-ноде, в главном меню setup-essence: **s) Хостинг подписок → 1) Установить** (если хостинг ещё не установлен). При входе через remote-control: **n** → нода → **o** «Меню сервера» → **s) Хостинг подписок → 1) Установить**.

Локально, в главном меню remote-control: **s → h** (хост-нода, `sub host --node`) → **u** «Обновить все подписки» (`sub publish-all`).

---

## Структура config.json

```jsonc
{
  "schema_version": 2,
  "nodes": [{                          // Список серверов (VPS)
    "id": "32-hex-stable-id",         // Стабильный идентификатор, не меняется при переименовании
    "name": "de-vps",                  // Уникальное имя ноды
    "ip": "1.2.3.4",                   // IP или домен
    "port": 22,                        // SSH-порт
    "user": "root",                    // SSH-пользователь
    "auth": "key",                     // Техническое значение: "key" или "password"
    "identity": "system",              // "system" либо идентификатор переносимого ключа
    "secret_id": null,                 // Ссылка на пароль для auth: "password"
    "tag": "DE",                       // Опциональный тег
    "aliases": {}                      // Псевдонимы подключений: {"ИМЯ_НА_НОДЕ": "ПСЕВДОНИМ"} (node aliases)
  }],
  "groups": [{                         // Группы устройств
    "name": "ROUTER",                  // Имя группы
    "template": "default.yaml",        // Шаблон конфига
    "subscription_headers": []         // HTTP-заголовки, наследуемые клиентами группы
  }],
  "clients": [{                        // Устройства
    "name": "my-phone",            // Уникальное имя
    "group": "MOBILE",                 // Группа
    "inherit_nodes_from_group": true,  // true — ноды от группы, false — свои
    "nodes": [],                       // Свой список нод (при inherit=false)
    "connections": [],                 // Кастомные подключения (при inherit=false)
    "credentials": {                   // Per-client креды (генерируются автоматически)
      "vless_uuid": "...",
      "hy2_password": "..."
    },
    "subscription": {                  // Опубликованная подписка
      "token": "...",                  // 64-hex токен
      "created_at": "2026-04-20T12:00:00Z",
      "expires_at": null,              // null = без TTL
      "headers": []                    // Per-client HTTP-заголовки
    }
  }],
  "connections": [{                    // Какие прокси ноды доступны каким группам
    "node": "de-vps",
    "groups": [
      { "name": "ROUTER", "proxies": ["VLESS TCP", "HY2"] },
      { "name": "MOBILE", "proxies": ["VLESS TCP"] }
    ]
  }],
  "subscription_host": {               // Нода-хост подписок
    "node": "de-vps",
    "base_url": "https://sub.example.com:2096",
    "sub_dir": "/var/lib/essence-sub",
    "nginx_group": "www-data"
  },
  "subscription_default_headers": [    // Необязательно: заголовки по умолчанию (без ключа действуют встроенные)
    { "name": "Content-Disposition", "value": "attachment; filename=\"config.yaml\"" },
    { "name": "profile-update-interval", "value": "24" }
  ]
}

```

В `schema_version: 2` встроенного поля `pass` нет. Пароль ноды с
`auth: "password"` хранится в `secrets.json` под ключом
`node:<id>:ssh-password`; код получает его через `node_secret_get`, записывает
через `node_secret_set` и удаляет через `node_secret_delete`. Локальные секреты
и материализованный GitHub runtime используют `secrets.schema_version: 1`:
шифротекст AES-256-CBC/PBKDF2, привязанный к устройству. При экспорте GitHub
пароль расшифровывается; переносимый снимок имеет `vault_version: 2` и
`secrets.schema_version: 2` с исходными паролями. При импорте они шифруются
ключом принимающего устройства.

**Миграции формата.** Номер формата снимка GitHub — `vault_version`
(`GITHUB_VAULT_FORMAT`), локального состояния — `config.schema_version`
(`STATE_FORMAT_VERSION`). Повышение формата выполняет цепочка шагов
`_migrate_<kind>_<N>_to_<N+1>` (`format_migrate_chain`); шаги не удаляются.
Локальное состояние преобразуется автоматически. Снимок GitHub старого формата
не открывается (`github_format_outdated`); восстановление — командами
`source github-migrate-format` (обычный commit поверх истории, без force-push;
пароли, которые нельзя расшифровать на этом устройстве, становятся
`missing_secret`) или `source github-replace-with-local` (заменить GitHub
конфигурацией только этого компьютера). Обе команды показывают план и выполняются
только с `--yes`; без него ничего не меняется. Они сами проверяют пароль запуска
(секрет `script-password`); если опубликованный снимок несёт другой пароль,
его спросит следующее открытие сессии. Для репозитория без шифрования (`none`)
план предупреждает, что пароли SSH и ключи будут храниться в GitHub открыто.
Если снимок создан более новой версией (`minimum_remote_control_version` выше
установленной или формат новее — `github_format_newer`), остаётся только
обновить скрипт. `minimum_remote_control_version` задаётся форматом
(v2 → `1.1.0`), а не версией скрипта. При подключении к репозиторию старого
формата `source github-connect` предлагает `--existing migrate`; смена аккаунта
на такой репозиторий прерывается с подсказкой.

`age` защищает весь переносимый снимок; `none` хранит пароли SSH и приватные
ключи открыто, доступно читателям репозитория, включая историю Git.
Переносимые SSH-ключи лежат в `ssh/identities/<node-id>` и `.pub`, ключи
серверов — в `ssh/known_hosts`; локальное `identity: "system"` использует
системную SSH-настройку. Локальные служебные логические снимки могут содержать
открытые секреты даже при `age`; их файлы закрыты правами доступа.

---

## Хранение данных

| Режим | Директория |
|-------|-----------|
| Dev (из папки проекта) | `remote-control/.remote-data/` |
| Installed (Linux/macOS) | `~/.config/remote-control-essence/` |
| GitHub | постоянный bare-репозиторий `github-store.git`; временный worktree в `github-sessions/` удаляется при выходе |

При подключении GitHub (`source github-connect`) используется фиксированный приватный
репозиторий `<GitHub owner>/essence-remote-control-config`. Режим `age` хранит
логическое состояние в `state.json.age`; режим `none` хранит `manifest.json`,
`config.json`, `secrets.json` и снимки шаблонов/SSH без шифрования. Способ
хранения нельзя незаметно сменить для существующего репозитория.

Нечитаемый или отсутствующий пароль отдельной ноды не блокирует публикацию:
её настройки и связи сохраняются, но пароль не отправляется; состояние получает
`missing_secret` / `needs_setup`. Предыдущий пароль из GitHub не подставляется.
После публикации или применения снимка выводится предупреждение с именами
таких нод. Общая ошибка формата, записи или шифрования прерывает операцию.
Откат загрузки восстанавливает исходный runtime побайтово, включая нечитаемые секреты.

В списке нод (раздел **n**) проблемная нода выделена, в карточке ноды `w`
предлагает скрытый повторный ввод (`node password`); отказ, EOF или пустой пароль не меняют данные.
Сохранение обновляет только локальные SSH-креды и синхронизирует их штатным путём:
пароль на VPS не меняется, SSH и загрузка скриптов автоматически не запускаются.
Пакетные операции пропускают ноду без доступного пароля, не запрашивая ввод.
Статусы Git «синхронизировано» / «есть неотправленные изменения» описывают
доставку снимка, а не готовность SSH каждой ноды.

Офлайн-изменение сначала фиксируется в локальной ветке `main` и получает статус
«есть неотправленные изменения». Следующий процесс открывает именно этот commit,
а `source github-push` повторяет push. Если локальная и удалённая ветки изменились
независимо, автоматическое объединение останавливается с диагностикой, чтобы не
потерять данные. Каталог `generated/` никогда не синхронизируется.

При недоступном API проверки аккаунта повторный запуск использует существующий
кеш только с прежним локальным профилем, совпадающим origin и сохранённой веткой.
Подтверждённая ошибка авторизации или несовпадение аккаунта блокирует открытие;
локальные изменения при этом уже закреплены до проверки аккаунта и push.

Ошибка сохранения останавливает зависимые действия и не закрывает текущее меню.
Повтор запускается только вручную. При массовом назначении подключений или
синхронизации нод ранее сохранённые элементы остаются; после первого отказа
записи следующие элементы не меняются. Недоступная при обнаружении нода
по-прежнему не блокирует обнаружение остальных.

Публикация всех подписок сначала загружает серверный пакет, затем сохраняет
новые токены последовательно. При отказе записи токена уже загруженные файлы
и ранее сохранённые токены остаются, дальнейшие записи и очистка старых файлов
останавливаются. Это не атомарная транзакция между сервером и локальным состоянием.

Поздний отказ точки восстановления не означает, что файл, пароль запуска или
параметры SSH остались прежними: проверьте состояние перед повтором. При отказе
отката или завершающей очистки ноды сохраняются доступные резервные копии;
диагностика указывает их пути. Если рабочая копия GitHub уже потеряна, перезапустите
remote-control: текущая сессия не восстанавливает её автоматически.

Ключ расшифровки можно сохранить на устройстве либо экспортировать во внешний
файл восстановления.

Только в зашифрованном режиме доступны `source github-rewrap-password`,
`source github-rotate-key` и `source github-import-recovery-key --file PATH`.
Смена пароля и новый ключ имеют разные последствия:

- **`source github-rewrap-password`** (секреты `vault-password`,
  `new-vault-password`) — меняет только пароль, которым открывается
  существующий ключ. Текущая конфигурация не получает новый ключ; старые версии
  в истории GitHub могут открываться прежним паролем.
- **`source github-rotate-key --yes`** (секрет `new-vault-password`) — создаёт
  новый ключ и заново шифрует им текущую конфигурацию. Пароли нод не меняются.
  Старые версии в истории GitHub остаются доступными по прежнему ключу.

Пароль запуска является частью логического состояния: в режиме `age` его хеш
зашифрован, а в режиме без шифрования виден в `manifest.json` приватного
репозитория. Сам файл `.auth` в Git не добавляется.

## Пароль запуска

Раздел **o) Настройки** и команды `self password-set` / `self password-remove`. Установка и смена требуют текущий пароль (секрет `current-password`), если он уже задан; удаление требует проверки старого пароля и подтверждения плана. На активном устройстве хеш SHA-512 с солью материализуется в `.auth` с правами 600; для источника GitHub тот же хеш сохраняется в логическом состоянии согласно выбранному режиму шифрования. При запуске меню даёт три попытки ввода пароля, затем предлагает восстановление доступа.
Пароль запуска не может содержать LF (перевод строки): `self password-set`
возвращает `invalid` до записи, сохраняя прежний пароль.
