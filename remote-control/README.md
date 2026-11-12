# essence-rc: устройство

Cargo workspace (edition 2024) из пяти крейтов собирается в один исполняемый файл `essence-rc`. Версия встраивается из корневого `VERSION`; запуск не вызывает Bash. Ядро выполняется в фоновом демоне, а терминальное меню, разовый CLI и веб-панель работают как его клиенты на одном протоколе v3.

```sh
cd remote-control
cargo build --workspace --locked
cargo test --workspace --locked
cargo run -p essence-rc -- status --json
node --test web/tests-js/*.test.mjs
```

Пользовательская документация (режимы запуска, протокол, каталог команд, меню, веб-панель) — [docs/remote-control.md](../docs/remote-control.md). Здесь описано устройство кода.

## Крейты и границы

| Крейт | Роль | Зависит от |
|---|---|---|
| `core` (`rc-core`) | Ядро: модель, состояние, каталог команд, `dispatch`, SSH, GitHub, домены | — |
| `client` (`essence-rc-client`) | Типы протокола v3, трейт `Client`, `DaemonClient` (локальный сокет и WebSocket), `ScriptedClient`, точка подключения, запуск демона | — (`essence-rc-web` только в dev-зависимостях) |
| `web` (`essence-rc-web`) | HTTP/TLS/WebSocket-слушатель, вшитые ассеты панели | — |
| `tui` (`essence-rc-tui`) | Библиотека экранов ratatui | `client` |
| `bin` (`essence-rc`) | Единственный бинарник: демон, CLI, меню, `web *`, автозапуск | все |

Границы проверяет `tui/tests/boundary.rs`:

- `tui_client_and_web_cannot_import_core` — в манифестах `tui`, `client`, `web` нет `rc-core`, в их `src` нет `rc_core::`;
- `tui_is_a_library_of_the_single_binary` — у `tui` нет `[[bin]]` и `main.rs`.

С ядром `tui`, `client` и `web` общаются только по протоколу v3 через демон.

## Демон и клиенты

Пользовательское описание — разделы [«Демон»](../docs/remote-control.md#демон) и [«Протокол v3»](../docs/remote-control.md#протокол-v3).

Модули `bin/src/daemon/`:

| Модуль | Назначение |
|---|---|
| `mod.rs` | Жизненный цикл: запуск, простой, постоянный режим, остановка |
| `local.rs` | Локальная точка: блокировка единственного экземпляра, Unix-сокет или канал Windows, проверка собеседника, цикл приёма, журнал, сигналы, перезапуск после `self update` |
| `conn.rs` | Одно соединение: сообщения протокола, события и ответы, маршрутизация запросов |
| `core.rs` | Поток ядра и очередь заданий |
| `access.rs` | Допуск сетевых соединений: одноразовые коды, токены возобновления, пауза после неудач, лимиты неавторизованных |
| `terminal.rs` | Реестр нод с открытым терминалом, консоль протокола, терминальные потоки |
| `commands.rs` | `daemon status`, `daemon stop`, `web status`, `web start`, `web stop`, `web link`; общие флаги слушателя `web start` и `daemon run --web` |

Поток ядра один: он владеет `Session` (а с ней менеджером блокировок и хранилищем паролей) и выполняет задания строго по одному в порядке поступления. Задачи среды tokio принимают локальные и сетевые соединения, обслуживают каждое своим `Conn`, следят за простоем и сигналами. `daemon *` и `web *` демон отвечает сам, без очереди ядра (состояние ядра берётся из опубликованного снимка).

Порядок маршрутизации запроса (`conn.rs`): разбор и проверка `rc_core::dispatch::checked` (транспортный `--secrets-stdin`, секреты и входные данные команды — те же правила, что у ядра, для любого запроса, включая `help`, `daemon *` и `web *`) → команда клиента (`CLIENT`) → только локальная (`LOCAL`) → `help` → авторизация соединения → `daemon`/`web` → терминальная команда → `session open` → очередь. До авторизации соединения командой `session open` работают только `help`, `session status`, `session open` и, у локальных соединений, `self version`, `daemon *`, `web *`. Сетевой `session open` одного соединения идёт по одному; ядро освобождает место до отправки ответа, поэтому следующий `session open` сразу после ответа принимается.

Исходящие сообщения соединения идут через задачу записи. События и ответы, ещё не записанные клиенту, учитываются в байтах (`Conn::send`); больше 16 МиБ — соединение закрывается и запись прекращается сразу, ничего не теряется у соединения, которое остаётся. Вывод терминала ограничен собственными кредитами (`terminal.rs::Pressure`). Завершение задачи записи (ошибка, превышение, остановка демона) завершает и чтение соединения, после чего оно снимается с учёта (`Shared::disconnect`). При остановке очередь заданий закрывается до опустошения: поздний запрос получает `daemon_stopping`.

Терминальные команды (`node shell`, `telegram menu`): `conn.rs` резервирует ноду при приёме запроса; поток ядра вызывает `rc_core::dispatch::prepare_terminal` (поиск, подключение, скрипты) и получает `rc_core::terminal::TerminalJob`; задание выполняется на потоке `terminal-<нода>` против соединения запросившего клиента до завершения или отмены (закрытие, обрыв соединения, смена пароля запуска, остановка демона). Запись реестра снимает охранник потока. Ввод терминала — `terminal::input_channel` (`InputSender`/`InputReceiver`): до 64 событий и до 4 МиБ декодированного ввода, байты освобождаются, когда сессия читает событие; сессия (`rc_core::ssh::interactive`, `InputQueue`) читает дальше, только пока её буфер записи в канал — до 64 событий и 4 МиБ вместе с записью в полёте — не заполнен. Передача без ожидания, переполнение по любому пределу закрывает терминал (связь ввода снимается, сессия получает EOF после принятого ввода, клиент — `log` `error`). `close` тоже снимает связь, поэтому терминал, ввод которого закрыт до открытия, не запускается и отвечает `remote_failed` (`reason: closed`). Записи реестра и отложенная отмена после `close` адресуются ключом терминала `<id>#<n>` (уникален в соединении), так что новый терминал с тем же `id` таймер прежнего не отменяет.

Клиенты:

- `essence_rc_client::Client` — единственный вид демона для экранов и CLI; `DaemonClient` — протокол v3 по локальному сокету или каналу (с запуском демона по требованию, `client/src/spawn.rs`) либо по WebSocket (`client/src/remote.rs`); `Client::local_data_dir` знает каталог данных только локальный `DaemonClient` (для `--connect` — `None`); `ScriptedClient` — детерминированная подделка для тестов экранов, записывает argv и только имена секретов и входных данных;
- `essence_rc_client::files` — файлы машины пользователя для CLI и меню: `read_input_file` (обычный файл без перехода по ссылке — Unix `O_NOFOLLOW`, Windows `FILE_FLAG_OPEN_REPARSE_POINT`, тип проверяется по открытому дескриптору; не больше 1 МиБ и UTF-8, буфер обнуляется), `write_file_atomic` (временный файл, `sync_all`, `persist` только при подтверждённой перезаписи, иначе `persist_noclobber`; затем синхронизация каталога на Unix), `inside_data_dir` (ключ восстановления внутри каталога данных локального демона);
- `bin/src/oneshot.rs` — разовый CLI: подключение (`oneshot::connect`), неявный `session open`, секреты, чтение `--file`, команды `CLIENT`, вывод конверта или текста;
- `bin/src/remote.rs` — `--connect URL`, `--fingerprint`, `--insecure`, закрепление сертификатов в `<данные>/known-daemons.json` (`remote::connect`);
- `bin/src/terminal.rs::TerminalConsole` — реализация `essence_rc_client::TerminalIo` поверх управляющего терминала (Unix `/dev/tty`, Windows `CONIN$`/`CONOUT$`) и скрытый ввод секретов;
- `bin/src/webcmd.rs` — `web run` и `web open`;
- `bin/src/service.rs` — `web install-service` и `web uninstall-service`.

## Каталог данных и схема

Приоритет имеет `--data-dir` (у `daemon run|start`), затем `ESSENCE_RC_DATA_DIR` (пустое значение запрещено). Иначе используется `dirs::data_dir()/essence-remote-control`: Linux/Termux — `$XDG_DATA_HOME` или `$HOME/.local/share`, macOS — `~/Library/Application Support`, Windows — `%APPDATA%`.

Файлы и ресурсы:

- `config.json`: схема 2, типизированные ноды, группы, клиенты, подключения, подписки и заголовки;
- `manifest.json`: схема 2, минимальная версия, переносимость, доступ, метаданные шаблонов;
- `secrets.json`: схема 1, карта `node_passwords`;
- `secret.key`: случайный машинный ключ длиной 32 байта;
- `auth.txt`: PHC-хеш Argon2id;
- `source.json`: необязательные строгие метаданные GitHub; отсутствие означает local;
- `templates/`, `ssh/identities/`, `ssh/known-hosts.json`;
- `generated/`: конфиги клиентов;
- `web/cert.pem`, `web/key.pem`: самоподписанный сертификат веб-панели;
- `known-daemons.json` (+ `.lock`): закреплённые сертификаты удалённых демонов;
- `.rc-lock/owner`: служебное владение блокировкой.

Каталог времени выполнения демона (сокет, блокировка, журнал) отделён от каталога данных — см. раздел [«Каталог времени выполнения»](../docs/remote-control.md#каталог-времени-выполнения) (`client/src/endpoint.rs`). Идентификатор `<h>` — SHA-256 от сырых байтов путей (`as_encoded_bytes`); символьные ссылки существующей части каталога данных разрешаются (`endpoint::resolved`), недостающий хвост дописывается без создания каталогов, а демону передаётся путь как есть.

Модель использует обычные serde-структуры с явными доменными полями: включая aliases, credentials, client connections, subscription timestamps и заголовки уровня конфигурации/группы/клиента. Отсутствие, `null` и значения по умолчанию нормализуются; сохранение произвольных неизвестных полей и миграция старых форматов не поддерживаются. Канонические валидаторы имён, SSH-параметров и тегов применяются при загрузке и записи. Unicode-теги разрешены, управляющие и служебные символы запрещены. Пины имеют типизированные ключи `[host]:port`, **включая порт 22**, и проверенные SHA256-отпечатки; разные порты не разделяют доверие.

## Запись, секреты и пароль запуска

Запись публикуется через закрытый случайный временный файл в том же каталоге: запись → `sync_all` → атомарная замена. Ошибка до публикации сохраняет предыдущий файл и удаляет временный; ошибка синхронизации каталога после публикации не означает откат. Unix синхронизирует родительский каталог. Windows использует `MoveFileExW` с `WRITE_THROUGH`; эквивалентной Unix directory-fsync гарантии при потере питания нет.

На Unix новые файлы имеют 0600, каталоги — 0700. На Windows owner-only DACL задаётся **при создании**, без внешних ACL-команд; файловые системы без постоянных ACL отклоняются. Симлинки и reparse points не принимаются как чувствительные конечные назначения. На Unix доверенные существующие родительские пути канонизируются: стандартный macOS `/var` и симлинки в родительском HOME не блокируют работу. Windows-пины каталогов разделяют read/write-доступ для совместной работы процессов, запрещают delete/rename и после настройки DACL не удерживают право WRITE_DAC. Это защита локальных файлов, не изоляция от другого кода с полномочиями того же пользователя.

`secret.key` создаётся только при первой записи пароля; существующий пустой контейнер не мешает инициализации. При непустом контейнере потерянный/повреждённый ключ не заменяется автоматически. Ключ AES-256-GCM — SHA-256 машинного ключа, значение контейнера — base64 от nonce (12 байт), ciphertext и тега (16 байт). Идентификатор `node:<32hex>:ssh-password` входит в authenticated associated data: перестановка шифротекстов между нодами не проходит проверку. При каждом сохранении используется новый nonce. Прикладные открытые пароли и буферы ключей обёрнуты в `Zeroizing`; это не обещание полного стирания всей памяти процесса или внутренних состояний сторонних криптобиблиотек.

`auth.txt` содержит Argon2id v19 с профилем приложения: m=19456 KiB, t=2, p=1, соль 16 байт, результат 32 байта. Другие параметры, в том числе огромные корректно закодированные стоимости, отклоняются **до** дорогостоящей проверки. Пароль запуска и SSH-пароли не помещаются в вывод сводки.

Коды доступа и токены возобновления веб-панели живут только в памяти демона (`daemon/access.rs`, хранятся SHA-256) и на диск не пишутся.

## Блокировки

`State` владеет единым `LockManager`. Для вложенных операций используйте `State::secret_store()` и `State::auth_store()`: они разделяют тот же менеджер. Сессия может передать менеджер через `State::with_locks`. Конструкторы отдельных хранилищ требуют явного менеджера; создавать независимый менеджер внутри уже открытой транзакции нельзя.

Блокировка основана на атомарном mkdir, без flock. Повторный вход разрешён одному потоку через общий менеджер; другой поток или процесс не считается повторным входом. Mutation освобождается при нулевой глубине; Session сохраняется до `release_all` или уничтожения последнего владельца. `RC_LOCK_WAIT` (читается из окружения демона) принимает 1–6 десятичных цифр, по умолчанию 30 секунд, опрос — 200 мс. Занятая сессия отклоняется сразу. Сессию ядра держит демон: меню и команды подключаются к нему и работают в одной сессии, поэтому в режиме GitHub они не конкурируют за блокировку.

Владелец содержит PID, время рождения процесса и случайный токен. Linux использует start ticks из `/proc`; доступный boot ID усиливает различение перезагрузок. Если boot ID закрыт (важно для Termux), одинаковые start ticks при неполной информации трактуются консервативно как живой процесс. macOS использует `proc_pidinfo`; Windows — минимальные права `OpenProcess`, нулевой wait и creation FILETIME. Отказ доступа или неопределённый результат **не** доказывают смерть владельца.

Доказанно мёртвый владелец освобождается через выборы `.reclaim`, проверку идентичности каталога и переименование в уникальный `.rc-lock.stale.*`. Отсутствующий owner допускает восстановление только после 60 секунд. Некорректный owner и брошенные выборы блокируют операцию; ошибка содержит путь и указание проверить отсутствие других операций перед ручным удалением. Действующие блокировки вручную не удаляют.

Единственность самого демона обеспечивает отдельная блокировка `<h>.lock` в каталоге времени выполнения (Unix — `flock`, Windows — первый экземпляр канала), см. `daemon/local.rs`.

## Команды: каталог, диспетчер, конверт

**Каталог** (`rc_core::cli`): одна таблица служит и разбору, и справке; каждая команда разбирается clap-командой, построенной из своей строки каталога (builder API). `--name` — единый селектор объекта команды (`conn`/`awg`/`telegram` — нода, `subscription show|publish|rotate|revoke` — клиент, `subscription host|migrate` — нода); связи (`--node` у `client connections|nodes`, `--group`, `--client` у `generate`/`subscription headers`) задаются отдельными флагами. `generate` — существительное без глагола. Глобальные `--json --yes --plan-token --secrets-stdin --help/-h` допустимы в любом месте; `--flag=value` и `--flag value`, повтор одиночного флага, значение с переводом строки, NUL, `--`, неизвестный флаг и лишний аргумент — `usage`. Флагов с секретными значениями нет. Обязательность флагов проверяют обработчики доменов.

Флаги строки каталога:

- `NOSESSION` — команда работает без открытой сессии;
- `TTY` — терминальная команда (нужно поле `terminal` запроса, иначе `tty_required`);
- `LOCAL` — принимается только с локального сокета (сетевым соединениям — `local_only`);
- `CLIENT` — выполняется самим процессом клиента и демону не отправляется (демону — `usage` «Команда выполняется на стороне клиента.»).

Токен `@имя` объявляет входные данные — содержимое файла. `cli::parse` (разбор демона) его не знает; `cli::parse_client` (разбор клиента) читает его как флаг `--имя PATH`, а `Invocation::daemon_argv` убирает такие флаги из argv перед отправкой демону. Содержимое клиент передаёт полем `input` запроса; в ядре это `rc_core::request_input::Input` (JSON-объект строк, значения в `Zeroizing`, без `Debug`/`Clone`/`Serialize`, ошибки не содержат имён и значений).

**Диспетчер**: `rc_core::dispatch::dispatch(argv, secrets, input, agent_socket, &mut Session)` — единая точка выполнения всех команд демона; `agent_socket` — SSH-агент запросившего клиента (`SSH_AUTH_SOCK` из поля `env` локального запроса, `None` — без агента). Терминальные команды идут через `prepare_terminal` с той же сигнатурой и возвращают `TerminalJob`. Единственный путь изменений состояния — `Session::mutate`.

**Конверт**: `{"id","ok","data"|"error":{"code","message",…},"sync"?}`; `id` назначает транспорт, `sync` (`clean|pending|offline`) есть только у успеха в режиме GitHub. `RcError{code,message,extra,exit}` — единственный тип ошибки ядра: выход 2 для `usage`, `host_key_unknown`, `daemon_cert_unknown`, `plan_changed` и `*_required`, коды Telegram 3/4, 1 для прочих. Демон добавляет к ответу с ошибкой поле `exit`; разовый CLI завершается этим кодом. Поля JSON выводятся в порядке объявления (`serde_json/preserve_order`).

**Подтверждение** (`rc_core::confirmation`): область — `noun verb` и исходные аргументы без позиционных noun/verb, `--json`, `--yes`, `--plan-token[=T]` и транспортного `--secrets-stdin`; токен — первые 16 hex SHA-256(область`\n` + строки плана`\n` + extra). Без `--yes` — `confirmation_required{plan,plan_token}`, чужой токен — `plan_changed`, `--yes` без токена — согласие, `--plan-token` без `--yes` — `usage` уже при разборе. До согласия — только проверки и чтение.

**Секреты** (`rc_core::request_secrets::Secrets`): JSON-объект строк только из списка `password`, `current-password`, `vault-password`, `new-vault-password`, `script-password`, `access-token`; значения в `Zeroizing`, без `Debug`/`Clone`/`Serialize`, ошибки не содержат ключей и значений. Команда принимает только свои секреты; `access-token` (одноразовый код из `web link`) принимает только `session open`. Секреты приходят полем `secrets` запроса. Разовый CLI получает их только из `--secrets-stdin` либо скрытым вводом с консоли (crossterm raw mode, Unix и Windows, до трёх попыток на секрет, только если stdin — консоль). Скрытый ввод запускают ответы `auth_required`, `missing_secret`, `vault_password_required`, `new_vault_password_required` (секрет из подсказки `extra.secret`, без неё — единственный незаполненный секрет команды) и `auth_failed`, `vault_password_invalid` (повторно тот же секрет из подсказки; `oneshot.rs::prompt_target`). Для неявного `session open` CLI принимает `script-password`, `vault-password`, `access-token`. Подтверждения с консоли не запрашиваются: ввод `y` ничего не подтверждает. Переменных окружения с паролями нет.

**Сессия**: сессия ядра одна на демон; каждое соединение авторизуется само командой `session open` (`conn.rs`, `core.rs`, `access.rs`). Перед каждой командой, кроме `help`, `session status|open`, `self version`, `daemon *`, `web *`, разовый CLI сам отправляет `session open`. «Настроено» = есть `config.json` или `source.json`; без конфигурации соединение авторизуется, `session open` отвечает `not_configured`, а пустая локальная сессия (`Session::open_absent`) ничего не создаёт на диске, так что `status`, `source init-local` и мастер GitHub работают на чистой установке.

**Команда `status`**: `essence-rc status [--json]` не создаёт отсутствующий каталог данных; сводку читает открытая сессия — для local это локальные файлы без сети, для GitHub разовый CLI перед `status` выполняет неявный `session open` (синхронизация и пароль доступа, как перед любой командой с сессией). Начальный снимок содержит группы `ROUTER`, `PC`, `MOBILE`, без нод и клиентов. Поля сводки: `version`, `update`, `script_password`, `source`, `counts`, `password_missing`, `ssh_setup_pending`, `subscription_host`. Последнее поле — имя ноды, не объект хоста. Повреждённый отдельный пароль отмечается в `password_missing`; некорректный контейнер паролей завершает команду ошибкой. Обновления не запрашиваются: `latest: null`. `source.sync` — состояние открытой GitHub-сессии (`clean|pending|offline`), для local — `null`. Если `auth.txt` содержит поддерживаемый хеш, нужен пароль запуска (иначе `auth_required`); повреждённый хеш также блокирует доступ.

**Журнал** (`rc_core::log`): обработчики пишут в приёмник сессии; демон превращает записи в события `{"id","event":"log","level","text"}` запросившему соединению и `activity log` наблюдателям, разовый CLI печатает их в stderr с префиксами `[*] [✓] [!] [✗]` — и при `--json`, stdout занят одним конвертом. C0/C1 вырезаются. Секреты в текст журнала не попадают.

**`self update` и `self uninstall`** (`rc_core::self_manage`): `self update` — метаданные `releases/latest` (rustls, `GITHUB_TOKEN` из окружения демона только заголовком в памяти) → план → после согласия загрузка ассета `essence-rc-<target>.tar.gz|.zip` и `SHA256SUMS`, проверка SHA-256, извлечение и атомарная замена собственного бинарника (Unix — rename в том же каталоге; Windows — переименование старого, `MoveFileExW`, откат). `self uninstall` удаляет только текущий бинарник и с `--remove-data` каталог данных, если все его записи принадлежат известной раскладке; корень, HOME, его предки, предки бинарника и каталоги, доступные другим на запись, отклоняются (`unsafe_path`). root требуется, только если каталог бинарника недоступен на запись. После успешного выполнения демон останавливается; постоянный демон после `self update` перезапускается новым бинарником (`daemon/core.rs`, `daemon/local.rs`). `self uninstall` при установленном автозапуске — `conflict`.

## SSH

`RemoteTransport` / `RemoteSession` отделяют эффекты от команд; `SshTransport` использует russh и russh-sftp без Bash, `ssh`, `scp` или дочерних процессов. `connect` принимает пароль, файл ключа с необязательной passphrase либо системную идентичность: SSH-агент клиента (Unix-сокет / Windows OpenSSH named pipe; демон получает путь полем `env.SSH_AUTH_SOCK` локального запроса), затем стандартные файлы `~/.ssh/id_*`. Секреты передаются в памяти; структуры аутентификации не реализуют Debug/Serialize, ошибки не включают тексты ошибок библиотек с потенциальными секретами.

Host-key callback сравнивает SHA256-отпечаток с явным пином либо известными пинами выбранного `[host]:port`; доверие автоматически не записывается. Явный неверный пин возвращает `host_key_mismatch`, смена известного ключа — `host_key_changed` с `host`, `port`, `fingerprints`; отсутствие доверия — `host_key_unknown`. Отсутствующий пароль — `missing_secret`, отсутствующий/непригодный ключ — `needs_setup`. Удалённые сбои возвращают `remote_failed` с `reason`; истечение общего срока операции — `reason: "timeout"`, не успешный exit status. `exec` одновременно передаёт stdin и читает stdout/stderr, сохраняет ненулевой exit status. Timeout закрывает только канал команды; удерживаемая через `hold` сессия не требует повторной аутентификации после уничтожения исходного транспорта.

Рекурсивный SFTP-upload передаёт бинарные файлы и назначает `.sh` режим 0755 независимо от локальной ОС и существующих прав назначения. Симлинки и конфликтующие типы назначения отклоняются. Посторонние удалённые файлы сохраняются; обычные файлы заменяются на месте, без общего отката. Корневой `VERSION` публикуется последним через временный файл и POSIX rename; без поддержки атомарной замены существующий `VERSION` сохраняется с ошибкой. `ServerBundle` разворачивает встроенные `setup-essence.sh`, `modules/`, `common/`, `VERSION` во временный закрытый каталог. `FakeTransport` предоставляет строгую очередь эффектов и журнал без содержимого credentials/stdin.

## Источник GitHub

Код: `rc_core::github::{exec, store, vault, switch, commands}`; все изменения — через `Session::mutate`.

**Раскладка.** Локальный источник — корень каталога данных (`source init-local` создаёт `config.json` и `manifest.json`). GitHub: `source.json`, `github-store/` (bare-зеркало: `heads/main`, `heads/session/<id>`, `remotes/origin/main`, `archive/*`), `github-sessions/<id>/worktree`, `github-runtime/` (материализованное рабочее состояние: те же файлы, пароли зашифрованы машинным ключом), `credentials/gh/<login>/` (изолированные профили gh), `credentials/github-config.agekey` (только `--remember-key`), `account-switch/` (журнал смены аккаунта), `import-backups/` (прежние локальные файлы после `github-switch-local`). `auth.txt`, `secret.key`, `source.json` и блокировка всегда в корне; для открытого GitHub `Session.state` указывает на `github-runtime/` с тем же `LockManager`.

**Репозиторий.** `storage.json` `{"storage_version":1,"encryption":"age"|"none"}`. age: `recipient.txt`, `unlock.age` (файл ключа формата age-keygen, зашифрованный scrypt-паролем), `state.json.age` (снимок на x25519-recipient), всё крейтом `age` без внешних утилит. none: `config.json`, `secrets.json` (схема 2, пароли открытым текстом), `manifest.json`, `ssh/known-hosts.json`, `templates/*.yaml`, `ssh/identities/<id>{,.pub}`. Дерево и индекс git проверяются allowlist-ом (симлинки, спецфайлы, лишние пути — ошибка). Снимок формата 1: `vault_version`, `minimum_remote_control_version` (2.0.0), `portability`, `access`, `config`, `secrets`, `templates{name:{content,source,sha256}}`, `ssh{identities,known_hosts}`. Расшифрованный снимок существует только в памяти; ключ сессии — в памяти. Цепочка миграций формата существует, зарегистрированных шагов нет (формат 0 → `github_format_outdated`, `github-migrate-format` → `github_format_invalid`). Встроенные шаблоны разрешаются из бинарника; снимок несёт только файлы `templates/` состояния (пользовательские шаблоны). `known_hosts` — JSON-карта отпечатков.

**git/gh.** Дочерние процессы через `std::process::Command` без shell: удалены `GH_TOKEN GITHUB_TOKEN GH_HOST GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN SSH_ASKPASS GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE`; gh — `GH_CONFIG_DIR=credentials/gh/<login> NO_COLOR=1 GH_PROMPT_DISABLED=1`; git — `GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=` (пустое значение git пропускает) и `-c core.askPass= -c credential.helper= -c credential.https://github.com.helper=!gh auth git-credential -c credential.https://github.com.username=<login>`; сеть — 30 с. Токен импорта (`gh auth token` → `gh auth login --with-token`) передаётся только через pipe. Диагностика редактируется (`[скрыто]`), не длиннее 500 символов.

**Синхронизация.** Открытие: блокировка `session` на всё время GitHub-сессии → восстановление журнала смены аккаунта → проверка аккаунта и приватности → `fetch --no-tags origin main:refs/remotes/origin/main` → равны: `clean`; локальная впереди: `pending`; локальная позади: fast-forward; разошлись: `source_failed` (этап «сверка локальных и удалённых изменений»), без слияния; сеть недоступна: `offline` (или `pending`, если есть неотправленный commit). Мутация: блокировка → изменение → checkpoint манифеста → сериализация → запись в worktree (сбой — откат файлов runtime и `auth.txt`) → stage allowlist → commit `Essence Remote Control <remote-control@localhost>` → `update-ref` локальной ветки до сети → `push refs/heads/session/<id>:refs/heads/main`; сбой отправки — результат команды сохраняется, `sync:"pending"`. Конверт успеха в GitHub-режиме несёт `sync`; `status.source.sync` заполнен. Закрытие сессии (при остановке демона) отправляет отложенное, удаляет worktree и снимает блокировку.

**Команды.** `source init-local|status|github-accounts|github-login|github-connect|github-fetch|github-push|github-change-account|github-rewrap-password|github-rotate-key|github-import-recovery-key|github-switch-local|github-replace-with-local|github-migrate-format|github-delete-repo`; `session open` открывает GitHub (`vault_password_required|invalid`, `github_format_*`, `locked`, `source_failed`). Решения — флаги и секреты; отсутствующее решение — `*_required` (`repo_create_required`, `repo_private_required`, `storage_mode_required{choices}`, `new_vault_password_required`, `existing_config_action_required{choices,remote_counts,local_counts}`, `cache_skip_required`, `target_replace_required{repo,tracked_files,reason}`, `key_provisioning_required{nodes}`, `github_auth_required{login,hint}`) до изменений; неудачный connect удаляет созданное (новый каталог данных исчезает целиком). Создание репозитория, приватизация, замена, хранение без шифрования, ротация, удаление — после `Plan::confirm`. Разовый CLI спрашивает скрытым вводом и `vault-password`/`new-vault-password`. Ключ восстановления импортирует `source github-import-recovery-key --file PATH`: файл читает клиент и передаёт полем `input.file`.

**Чужой репозиторий.** Любой репозиторий без читаемой конфигурации Remote Control 2 (посторонние файлы, недопустимое дерево, нет `storage.json`, `github_format_invalid`) — решение `target_replace_required{repo,tracked_files,reason}`; с `--replace-target` (план с числом удаляемых файлов) файлы удаляются коммитом поверх истории и публикуется конфигурация устройства. Мастер меню спрашивает про замену с причиной.

**Смена аккаунта** ведёт журнал `prepared → push_unknown → target_committed → local_committed`; при следующем открытии `push_unknown` проверяется по удалённой ветке (нет ветки или другая история — откат; ожидаемый commit или потомок — завершение), прежний репозиторий не меняется. Снимки журнала `account-switch/old-state.sealed`/`target-state.sealed` (в них пароли нод) зашифрованы машинным ключом `secret.key` по схеме `secrets.json` (AES-256-GCM, AAD = роль файла + случайный id транзакции из `transaction.json`); ключ создаётся при первом использовании по правилам `SecretStore` (не заменяется при непустом контейнере паролей). Отсутствующий или неподходящий ключ при восстановлении — `source_failed` без изменений: журнал сохраняется для ручного восстановления.

**Онбординг нод** при `github-connect`/`github-replace-with-local` (`--provision-keys yes|no`) выполняет `rc_core::nodes::setup`; с `no` ноды публикуются с `needs_setup` (`missing_identity`, `missing_host_key`, `missing_secret` вычисляются при сериализации).

## Ноды и подключения

Код: `rc_core::nodes::{mod, basic, add, delete, scripts, harden, setup, shell, conn}`; PTY-канал — `RemoteTransport::interactive` (`transport.rs`, `ssh.rs`, `fake_transport.rs`).

**Команды.** `node list|show|aliases|rename|tag|password|add|trust-host-key|delete|check|upload-scripts|harden|setup-ssh|shell`, `conn list|set|sync`. Все изменения состояния — через `Session::mutate` (local: checkpoint манифеста; GitHub: снимок → commit → push, `sync` в конверте). SSH — только через `RemoteTransport` (russh); производственный транспорт создаётся в диспетчере, тесты подставляют `FakeTransport`. Переименование и удаление ноды обновляют `subscription_host`.

**Ключи серверов.** Пины только в `ssh/known-hosts.json` по `[host]:port`. Проверку выполняет сам handshake: `host_key_unknown`/`host_key_mismatch`/`host_key_changed` с `{host,port,fingerprints}` (отпечаток сервера) и без записи. `node add` закрепляет только согласованный отпечаток (`--host-key`, `--accept-new-host-key` — повторное подключение с закреплённым отпечатком, `--replace-host-key` — план и согласие; оба флага вместе не принимаются). `node trust-host-key` — подключение с ожидаемым отпечатком, план, согласие, затем запись; снимает `missing_host_key`.

**Удаление.** План и согласие до любых удалённых действий; аутентифицированное соединение удерживается (`hold()`) как канал восстановления; отзыв управляемого ключа с проверкой, затем `bash /root/essence-setup/setup-essence.sh uninstall --force`; при сбое ключ возвращается через удерживаемую сессию и проверяется новым входом, нода сохраняется. Одна мутация удаляет ноду, подключения, ссылки клиентов, `subscription_host`, пароль, пины (если адрес не используется другой нодой), проблемы переносимости и файлы ключа.

**Усиление и SSH-настройка.** `node harden`: порт в плане детерминирован (без `--port` — первый свободный из последовательности по id ноды, 49152–65535), `port_in_use{port}`; фазы apply → verify (новое подключение к новому порту с управляемым ключом) → при сбое rollback через удерживаемую исходную сессию (резервная копия `sshd_config`, `sshd -t` перед перезапуском); `hardening_failed{stage,rolled_back,console_required}`, `console_required:true` — только если откат не подтверждён. Состояние записывается одной мутацией после проверки. `node setup-ssh` (GitHub): `nothing_pending`, `key_provisioning_required{nodes}`, план с отпечатками серверов, ed25519-ключ в `ssh/identities/<id>{,.pub}`, установка в `authorized_keys` (идемпотентно), проверка входа новым ключом, откат с отзывом ключей, `--on-failure defer`, `onboarding_failed{node,step,rolled_back}`. Тот же API используют `node add` (GitHub, вход по ключу) и `github-connect`/`github-replace-with-local`.

**Скрипты и терминал.** `node upload-scripts`: проба каталога `/root/essence-setup`, сравнение с `VERSION`, `--force` — план и согласие, загрузка встроенного комплекта одной SFTP-операцией (`ServerBundle`, VERSION последним), проверка версии после загрузки. `node shell` — терминальная команда: `prepare_terminal` находит ноду, подключается и обновляет скрипты, возвращает `TerminalJob`; демон выполняет его на терминальном потоке как PTY (`TERM`, размер, window-change, реальный exit status) с меню `setup-essence.sh`. Без поля `terminal` в запросе — `tty_required` без SSH. Одна нода — один открытый терминал (`conflict`).

**Подключения.** Обнаружение — один `cat /etc/mihomo/client-config.txt` на ноду, разбор только YAML-ключей `name:`. `conn set` заменяет группы на месте одной записью; `conn sync` сначала опрашивает ноды без удержания блокировки, затем по одной мутации на изменённую ноду, чистит и `clients[].connections` (запись клиента остаётся, даже пустая), `partial{nodes,ok,failed,total,stopped_at}`.

## Клиенты, генерация, подписки, AmneziaWG, Telegram

Код: `rc_core::protocols` (чистые билдеры `uri`, `hy2`, `vless_tcp|grpc|xhttp`, `dnat`, `listener_users`), `rc_core::clients` (`groups`, `templates`, `client`, `generate`), `rc_core::subscription` (`commands`, `remote`), `rc_core::awg`, `rc_core::telegram` (`status`). Каждая команда каталога выполняется, неизвестная — `usage`.

**Билдеры и golden.** `core/tests/protocols_golden.rs` воспроизводит все случаи `core/tests/golden/protocols/*.json` (stdout побайтно и rc; для разборщиков URI — и строки stderr; DNAT — выполнением Rust-текста команд под теми же заглушками в POSIX bash, на Windows случаи DNAT пропускаются). IPv6-цель DNAT использует `ip6tables` и `[addr]:port` (unit-тест `dnat::tests::ipv6_target_uses_ip6tables_and_brackets`).

**Шаблоны.** Встроенные `core/templates/*.yaml` компилируются в бинарник; пользовательский файл с тем же именем имеет приоритет. Файлы машины пользователя трогает только клиент (`essence_rc_client::files`): `template export` (`CLIENT`) — `template show` плюс атомарная запись `--output`, существующий путь перезаписывается по плану, ссылка заменяется файлом, появившийся без плана файл не заменяется (`conflict` «Файл {output} появился во время экспорта: повторите команду.»); `--file` у `template import` — только обычный файл до 1 МиБ в UTF-8, символьная ссылка отклоняется (`invalid`). Импорт поверх существующего шаблона — по плану, `extra` которого — SHA-256 содержимого: токен для другого содержимого отвечает `plan_changed`.

**Генерация.** `generate --all|--group|--client`: по одному соединению на ноду (пиры AWG → конфигурация ноды → синхронизация пользователей listener), конфиги клиентов в `<данные>/generated/<group>/<client>/config.yaml` (0600, без ссылок); недоступная нода — `partial{ok,skipped,failed,nodes_ok,nodes_failed,dir}`, прежний конфиг клиента сохраняется. `client config --name C` возвращает содержимое готового конфига. `awg status|sync|remove` (remove — план и согласие).

**Подписки.** `subscription host|list|show|headers|publish|publish-all|rotate|revoke|migrate`: токен 64 hex сохраняется только после загрузки, проверка HTTP после публикации (`partial` со ссылкой), ротация/отзыв/миграция/очистка — план и согласие, `publish-all` сохраняет новые токены одной мутацией. Нет хоста — `not_configured`, нет сгенерированного конфига — `needs_setup`, на ноде нет модуля хостинга — `not_installed`.

**Telegram.** Сначала read-only предпроверка всех выбранных нод (SSH, пины, версия скриптов, SHA-256 встроенного комплекта), один план (`extra` = sha256 комплекта + VERSION), затем параллельные (до 4) воркеры на замороженном снимке предпроверки; недоступная нода — строка `error`, остальные выполняются. Итог: любая строка `error` → код 1/`remote_failed`; иначе `partial` → 4; иначе `not_installed` (хотя бы на части нод) → 3; иначе успех. `telegram menu` — терминальная команда: предпроверка одной ноды и PTY в серверное меню без автозагрузки скриптов (`invalid` с командой `node upload-scripts`), без поля `terminal` — `tty_required`.

## Терминальное меню

`essence-rc` без аргументов при терминальных stdin/stdout вызывает `essence_rc_tui::run_terminal(Frontend { client, terminal })` в своём процессе (`bin/src/main.rs`). `client` — `Box<dyn essence_rc_client::Client>`: `DaemonClient` локального демона из `oneshot::connect` (демон запускается по требованию, при сбое старта показываются последние строки его журнала) или удалённого из `remote::connect` при `--connect` (неизвестный сертификат подтверждается до входа в альтернативный экран). `terminal` — фабрика консоли терминальных команд (`TerminalConsole`). В перенаправленном stdin/stdout меню не запускается.

**Контекст экрана** (`tui/src/app.rs`): `ctx.call` / `ctx.request` / `ctx.request_with` (с `Input`) — все запросы к демону; каждый запрос сразу рисует строку состояния со спиннером и временем (`app::activity`), обновляемую каждые 100 мс и событиями журнала. Подтверждение — `confirm::run_confirmed` / `run_confirmed_with` (план из `confirmation_required`, один y/N, по умолчанию N, повтор с `--yes --plan-token`, `plan_changed` показывается заново не более двух раз); коды решений GitHub → флаги в `confirm::decision_flag`; обработчик кодов ноды; секреты только скрытым вводом и полем `secrets`. `error.message` неудачного ответа показывается один раз центрально (кроме `confirmation_required`, `plan_changed`, `*_required`).

**Вход** (`tui/src/system.rs`): `session open` с ответом `auth_required`/`auth_failed` спрашивает секрет по полю `secret` — пароль запуска или, при `secret: access-token` (подключение через `--connect` к панели без пароля запуска), «Код доступа (essence-rc web link)»; принятый код одноразовый и не повторяется.

**Экраны** (`system`, `source`, `nodes`, `clients`): рамка 68 + разделители без пустых секций (кадр без содержимого — без разделителя), буквенные клавиши в обоих регистрах, неизвестное — «Неверный выбор.», `0` — Назад/Отмена; стрелки дополняют ключи (`app::Picker`: ↑/↓ — подсветка, Enter/→ — выбор, Esc/← — `0`, Пробел — переключение в мультивыборе; режим кадра — `ui::Mode`). Цвет есть только у ключа пункта (`ui::View`), корневое меню группируется цветом раздела (`system::dashboard_view`). Все строки (рамка, журнал, строка ввода) переносятся по словам в ширине кадра. URL подписки — обычный текст без OSC8; вывод curl/JSON/QR и содержимое шаблона показываются внутри read-only рамки. Сбой чтения экрана предлагает «Повторить».

**Файлы.** Импорт — меню читает файл само (`files::read_input_file`: обычный файл, не ссылка, до 1 МиБ, UTF-8) и передаёт содержимое полем `input`; ключ восстановления внутри каталога данных локального демона отклоняется без запроса. Экспорт шаблона — `template show` и атомарная запись файла меню, существующий файл — вопрос «Перезаписать файл?», файл, появившийся без этого вопроса, не заменяется. Редактор шаблонов — `$VISUAL`/`$EDITOR`/`nano`/`vi` (Windows — `notepad`) на приватном временном файле с проверкой «без изменений»; результат уходит `template import --name N` с содержимым в `input.file` через план.

**Терминальные команды.** `node shell` и `telegram menu` выполняет демон в своей сессии; меню на время запроса приостанавливается (cooked mode, основной экран) и не читает терминал, ввод-вывод идёт через `TerminalIo` (`TerminalConsole`), Ctrl+C уходит только на удалённый терминал. `telegram menu` скрипты не загружает: ответ `invalid{state}` экран превращает в отдельную подтверждённую `node upload-scripts` (`--force` для повреждённой установки), без автоповтора.

**Сигналы.** Меню перехватывает SIGINT на всё время работы: в меню Ctrl+C (клавиша в raw mode или сигнал ОС) закрывает соединение с демоном и даёт выход 130; во время запроса, редактора или терминальной команды SIGINT игнорируется, а нажатия Ctrl+C, пришедшие во время запроса, отбрасываются. SIGTERM/SIGHUP/SIGQUIT (Windows — события консоли) восстанавливают терминал и завершают процесс 128+N; паника восстанавливает терминал и выходит с 1 без payload. Разовый CLI ведёт себя так же: SIGINT не рвёт команду, завершающие сигналы возвращают консоль из raw mode.

## Веб-панель

Пользовательское описание — раздел [«Веб-панель»](../docs/remote-control.md#веб-панель).

**Слушатель** (`essence-rc-web`, `web/src/lib.rs`) не знает протокола: каждое принятое WebSocket-соединение отдаётся демону как `Accepted` (текстовые кадры — строки `incoming`, строки `outgoing` — кадры). Маршруты: `/` → `index.html`; `/assets/{*path}` (расширения `html`, `css`, `js`, `mjs`, `svg`, `json`, `woff2`); `/ws`; остальное — 404. Ассеты вшиты в бинарник `include_dir!("$CARGO_MANIFEST_DIR/assets")`. Заголовки каждого ответа: CSP `default-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'`, `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: no-referrer`, `Cache-Control: no-store`. Проверка `Host`: на loopback — `localhost`, `127.0.0.1` или `[::1]` с портом слушателя; иначе IP-литерал или `localhost` с портом либо DNS-имя из SAN сертификата; у `/ws` `Origin`, если есть, совпадает с `Host`, `Origin: null` → 403. Лимиты (`Limits::default`): кадр до 4 МиБ, заголовки за 30 с, до 128 TCP-соединений, ping каждые 30 с, TLS-рукопожатие за 10 с. TLS — rustls только с `ring`; отпечаток — `SHA256:<64 hex>` от DER.

Сертификат, флаги слушателя, `web link` и коды доступа ведёт демон (`daemon/commands.rs`, `daemon/access.rs`); `web run|open` — `bin/src/webcmd.rs` (ссылка входа открывается через временный файл-переадресацию в каталоге времени выполнения, чтобы не попасть в argv).

**Фронтенд** (`web/assets/`) — Preact + htm без сборки и npm (`web/package.json` — только `{"private":true,"type":"module"}`). `index.html` подключает классические скрипты вендора `xterm.js`, `xterm-addon-fit.js`, `qrcode.js` и модуль `js/app.js`; `vendor/preact-htm.js` — ES-модуль (`html`, `render`, хуки). Вендоренные файлы не правятся; версии и SHA-256 — в `assets/vendor/VENDOR.md`.

| Модуль `assets/js/` | Назначение |
|---|---|
| `protocol.js` | Клиент протокола v3 по WebSocket, переподключение, токен возобновления в `sessionStorage` |
| `session.js` | Вход: код из ссылки, пароль запуска, токен возобновления |
| `router.js` | Маршруты `#/раздел/параметр`; `consumeTicket` стирает `#ticket=` из адреса |
| `app.js` | Каркас: меню разделов (`MENU`), контекст экранов (`makeContext`), шапка и индикаторы |
| `flows.js` | Подтверждение планом и коды решений (тот же алгоритм, что `tui/src/confirm.rs`) |
| `format.js` | Форматирование и тексты ошибок |
| `dialogs.js`, `ui.js` | Диалоги и общие компоненты |
| `terminal.js` | Терминал нод на xterm |
| `screens/*` | Экраны разделов (`screens/index.js` — `SCREENS`), чистые модели `*-model.js`, общие хуки `kit.js` |

## Автозапуск

`bin/src/service.rs` реализует `web install-service` и `web uninstall-service`: служба запускает `<exe> daemon run --web --data-dir <абсолютный путь> <флаги слушателя>` (Windows — `daemon start`; `ESSENCE_RC_RUNTIME_DIR` передаётся, только если задан явно). Перед установкой флаги проверяются так же, как у `web start`, работающий демон останавливается, файл службы пишется атомарно, при сбое изменения откатываются. Внешние программы запускаются без shell; генерация файлов — чистые функции.

| ОС | Где | Как |
|---|---|---|
| Linux с systemd (есть `/run/systemd/system`) | пользователь: `$XDG_CONFIG_HOME` или `~/.config` + `/systemd/user/essence-rc-web.service`; root: `/etc/systemd/system/essence-rc-web.service` | `Restart=always`, `RestartSec=2`, `WantedBy=default.target` (root — `multi-user.target`); `systemctl [--user] daemon-reload`, `enable`, `restart`; подсказка `loginctl enable-linger` |
| macOS | `~/Library/LaunchAgents/com.essence-rc.web.plist` | `RunAtLoad`, `KeepAlive`; `launchctl bootout` → `bootstrap gui/<uid>` |
| Windows | задача планировщика `essence-rc-web` (`/SC ONLOGON /RL LIMITED`) | при неудаче — `essence-rc-web.cmd` в папке автозагрузки |

Прочие ОС → `not_supported`. Для root бинарник и каталог данных должны принадлежать root и быть недоступны группе и прочим на запись (`unsafe_path`). Тесты подменяют признак systemd переменной `ESSENCE_RC_SYSTEMD_DIR`.

## Тесты

| Набор | Что проверяет |
|---|---|
| `bin/tests/cli_contract.rs` | Настоящий бинарник: одна JSON-строка, коды выхода, грамматика каталога, подтверждение, пароль запуска, отсутствие утечек секретов |
| `bin/tests/daemon_protocol.rs` | Протокол v3 на локальном сокете и CLI через демон по требованию; восстановление raw-консоли после SIGTERM/SIGHUP в настоящем псевдотерминале |
| `bin/tests/daemon_network.rs` | `daemon run --web --port 0`: код, пароль, токен возобновления, лимит 64 КиБ, пауза, `--connect` и закрепление |
| `bin/tests/service_process.rs` | Linux: `web install-service`/`uninstall-service` с поддельным `systemctl` (`ESSENCE_RC_SYSTEMD_DIR`), откат, `not_supported`, отказ с `--connect` |
| `bin/tests/github_source.rs` | GitHub-источник на настоящем git (локальные bare-репозитории через `url.insteadOf`), поддельный `gh` — сам тестовый бинарник, без сети (`harness = false`); мастер меню против демона |
| `bin/tests/state_process.rs` | Межпроцессные блокировки, атомарная запись, read-only `status` |
| `bin/tests/tui_e2e.rs` | Linux: меню настоящего бинарника в PTY против демона |
| `client/src/tests.rs`, `client/src/remote/tests.rs`, `client/tests/listener_e2e.rs` | `DaemonClient` на поддельном демоне; TLS, закрепление, WebSocket против настоящего слушателя |
| `web/tests/listener.rs` | Заголовки, Host, Origin, WebSocket, остановка, отпечаток |
| `tui/tests/boundary.rs`, `tui/src/*` | Границы крейтов; экраны на `ScriptedClient`/`ScriptedUi` (argv по клавишам, подтверждения, код → флаг, пустые и ошибочные состояния, отсутствие секретов в argv и кадрах) |
| `core/tests/protocols_golden.rs`, `core/tests/ssh_wire.rs`, `core/tests/ssh_e2e.rs` | Golden билдеров; loopback SSH/SFTP на сервере russh; OpenSSH-сценарий |
| `web/tests-js/*.test.mjs` | Модели экранов, `flows.js`, `format.js`, `protocol.js`, `session.js` (`node --test`, Node 22, без зависимостей) |

CI (`.github/workflows/tests.yml`): `cargo test --workspace --locked` идёт на `ubuntu-latest`, `windows-latest`, `macos-latest` (job `rust-test`); сборка 9 целей релиза — job `rust-build`; OpenSSH-сценарий с Debian sshd (`tests/ci/ssh_e2e.sh`) — job `rust-ssh-e2e`; JS-тесты панели — job `web-js-test`.

**Не проверяется автоматически:**

- реальная установка автозапуска: systemd проверяется только с поддельным `systemctl` (`service_process.rs`, Linux), launchd и планировщик Windows не проверяются;
- ручная работа панели в браузере (тесты покрывают модели и протокол, не DOM);
- реальные ноды (nginx/подписки, Telegram, AWG, DNAT);
- локальный `ssh_e2e` без `E2E_SSH=1` возвращается сразу: OpenSSH проверяет только CI.
