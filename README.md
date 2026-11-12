> **ОТКАЗ ОТ ОТВЕТСТВЕННОСТИ / DISCLAIMER**
>
> Данный репозиторий создан исключительно в **образовательных целях** для изучения сетевых технологий, протоколов шифрования, настройки обратных прокси и администрирования Linux-серверов.
>
> Автор **не несёт ответственности** за действия третьих лиц и за любой ущерб, прямой или косвенный, возникший в результате использования материалов репозитория. Весь риск использования лежит исключительно на пользователе.
>
> Используйте только в соответствии с законодательством вашей страны.

# Essence

Bash-скрипты для настройки прокси-сервера и Rust-клиент `essence-rc` для управления серверами и клиентскими конфигами на базе ядра [mihomo (Clash.Meta)](https://github.com/MetaCubeX/mihomo).

Поддерживаемые протоколы: **VLESS Reality** (TCP, xHTTP, gRPC), **Hysteria2**, **AmneziaWG**, **WARP**, **Каскады нод**.

<img width="1746" height="1000" alt="image" src="https://github.com/user-attachments/assets/038a7816-7fb4-44e2-965f-2a84a09667f8" />

## Компоненты

| Компонент | Описание | Документация |
|-----------|----------|-------------|
| **Essence Setup** | Серверный скрипт. Устанавливается на VPS, настраивает протоколы | [docs/essence.md](docs/essence.md) |
| **Remote Control** | Локальный бинарник `essence-rc` (Linux, macOS, Windows, Termux). Управляет серверами по SSH, генерирует клиентские конфиги | [docs/remote-control.md](docs/remote-control.md), [remote-control/README.md](remote-control/README.md) |

## Возможности

### Серверная часть (Essence Setup)

- **Установка mihomo** — бинарник под архитектуру сервера (amd64-v3/v2, armv7, arm64), systemd-сервис, UFW с автоопределением SSH-порта, BBR и sysctl-тюнинг
- **VLESS Reality** — XTLS-Reality с тремя транспортами:
  - **TCP** (flow `xtls-rprx-vision`) на 443
  - **xHTTP** через Reality или через nginx TLS
  - **gRPC** через Reality
  Два режима: **Self-Steal** (свой домен + acme.sh) или **SNI** (маскировка под чужой SNI)
- **Hysteria2** — QUIC с опциональным `obfs salamander` для маскировки пакетов
- **AmneziaWG 3.1** — WireGuard с DPI-обфускацией (Header Protection, content padding, randomized timings, Random Trailers, Disable Cookies), per-peer конфиги с QR-кодами
- **WARP** — Cloudflare WARP как исходящий прокси через `wgcf` (опционально WARP+)
- **Каскады нод** — два типа:
  - **iptables DNAT** — прозрачная пересылка уже-зашифрованного трафика
  - **Shared listener** — подключение к существующему VLESS/HY2 listener на outbound-сервере
- **Decoy-сайты** — рандомизированные HTML-шаблоны (Simple Web Templates, SNI Templates, Nothing Templates) с анти-fingerprint обфускацией
- **Хостинг подписок** — HTTPS-публикация через nginx (отдельный `/sub/<token>`), два режима (совместный SNI с VLESS на 443 или отдельный порт), ограничение запросов и автоочистка просроченных подписок
- **TLS-сертификаты** — общий acme.sh lifecycle для VLESS, подписок и Web Proxy: переиспользование пригодной пары, восстановление сохранённого архива без нового заказа, автоматическое продление через постоянный HTTP-01 route; [правила удаления и выдачи](docs/essence.md#общий-lifecycle-сертификатов-acme)
- **Telegram Proxy** — Web Proxy через HTTPS/WebSocket и MTProto Proxy используют общую службу MTProxy, секрет и Спонсорский тег; служба устанавливается автоматически и удаляется после отключения последнего способа доступа
- **Telegram-порты** — Web Proxy: 443/80, локальный relay: 8080/8081, служба MTProxy: 2398, закрытая статистика: 8888; при одном Web Proxy внешний TCP/2398 закрыт, внутренние порты ограничены nftables/UFW
- **Telegram CLI** — `telegram-proxy menu` открывает меню; `backend restart` перезапускает службу MTProxy, `web restart` — Web Proxy. Доступны `status [--json]`, `connection`, `diagnostics`, `rotate-secret`, `tag`, `web`, `mtproto`, `remove-all`. Успешные локальные установка, смена секрета и обновление IP автоматически печатают ссылки; `--force` их скрывает. Спонсорский тег печатается только по `tag show`; [строгая грамматика CLI](docs/essence.md#telegram-proxy--способы-доступа-и-общая-служба)
- **IPv6 toggle** — включение/отключение IPv6 на сервере
- **Полное удаление** — удаление всех установленных компонентов

### Локальная часть (Remote Control)

- **Единое ядро команд** — вся логика в командах `сущность действие --флаги` → JSON `{ok,data|error}`; терминальное меню (`essence-rc` без аргументов) — только слой экранов поверх ядра, а `essence-rc serve` отдаёт то же ядро по протоколу JSON-строк для веб-панели и приложений ([remote-control/README.md](remote-control/README.md))
- **Управление нодами** — добавление VPS с паролями под AES-256-GCM (ключ устройства), переименование с каскадным апдейтом ссылок, теги, удаление с опциональной очисткой сервера
- **Усиление защиты SSH** — генерация переносимого ed25519-ключа, копирование на сервер, отключение пароля, смена SSH-порта (49152-65535) и обновление firewall с проверкой результата
- **Клиенты** — создание с auto-generated `vless_uuid` + `hy2_password`, наследование нод от группы или кастомный список, смена группы с миграцией, переименование с миграцией директории
- **Группы** — шаблон на группу, маркеры `# --- GROUP ---` в YAML для per-group блоков, поддержка мульти-группы (`GROUP1/GROUP2`)
- **Подключения нод для групп** — автодискавер по SSH (VLESS/HY2/AWG/каскады), цветной обзор покрытия, батч-назначение подключений группам, авточистка stale-записей
- **Клиенты AmneziaWG** — обзор используемых, неиспользуемых и отсутствующих клиентов, пакетное создание и удаление; при ошибке обновления сохраняется последний снимок, изменения блокируются до успешного обновления
- **Генерация конфигов** — по группе или всем, per-client credentials injection, кеш proxy-конфигов с нод, проверка дубликатов, синхронизация входных подключений. Итог показывает готовых, пропущенных и ошибочных клиентов; публикация подписок — отдельное действие
- **Подписки** — публикация, отзыв и смена токенов, пакетное обновление, миграция между нодами, проверка HTTP 200 и очистка осиротевших файлов
- **HTTP-заголовки подписок** — наследование `default → group → client` с показом итогового значения и источника, безопасное quoting для nginx
- **Шаблоны** — создание на основе `default.yaml` или другого шаблона, редактор (`$VISUAL`/`$EDITOR`, nano, vi; в Windows — notepad) в меню, экспорт и импорт файлом, несколько шаблонов на проект
- **Обновления** — проверка версии и обновление бинарника командой `self update` (SHA-256 из `SHA256SUMS`) или из раздела «Настройки»
- **Пароль запуска** — Argon2id; для GitHub входит в логическое состояние и следует выбранному режиму шифрования
- **Каталог данных** — `~/.local/share/essence-remote-control` (Linux/Termux), `~/Library/Application Support/essence-remote-control` (macOS), `%APPDATA%\essence-remote-control` (Windows); переопределяется `ESSENCE_RC_DATA_DIR`
- **Командная строка** — `essence-rc <сущность> <действие> [--json]` без вопросов: источник, ноды, группы, шаблоны, клиенты, подключения, генерация, подписки, AmneziaWG, Telegram и сам remote-control; опасные действия показывают план и выполняются только с `--yes` (необязательный `--plan-token` из плана гарантирует, что план не изменился); решения (`*_required`) возвращаются кодами с данными, секреты — через `--secrets-stdin` (`essence-rc help`)

Remote Control поддерживает переносимый источник состояния GitHub. При первом
выборе используется фиксированный приватный репозиторий
`<owner>/essence-remote-control-config`; имя и владельца нельзя случайно заменить.
Способ хранения выбирается один раз: зашифрованное хранилище `age` либо дерево
без шифрования. Ключ расшифровки можно сохранить на устройстве или экспортировать
во внешний файл восстановления. Офлайн-изменения сохраняются в локальной ветке
и получают статус «есть неотправленные изменения»; независимое изменение
локальной и удалённой веток останавливает синхронизацию без потери одной из версий.
Сгенерированные конфиги из `generated/` в GitHub не отправляются.
Пароли SSH переносятся между устройствами и заново шифруются локальным ключом.
В режиме `none` они и приватные SSH-ключи открыты читателям репозитория и остаются
в истории Git. Недоступный пароль не блокирует остальные ноды: проблемная нода
переносится без него и предлагает повторный ввод в карточке ноды (`n` → нода → `w`),
без изменения пароля на VPS или автоматического SSH.


Серверные shell entrypoints требуют Bash 3.2 или новее.

## Быстрый старт

Запустите Remote Control (`essence-rc`) — он сам загрузит серверные скрипты на VPS при первом подключении к ноде.

**Linux / macOS / Android (Termux) — установка:**
```bash
curl -fsSL https://raw.githubusercontent.com/Morvex885/essence-setup-script/main/install-essence-rc.sh | bash
essence-rc
```

Установщик определяет ОС и архитектуру (Linux x86_64/aarch64/armv7, macOS
Intel/Apple Silicon, Termux aarch64), скачивает `essence-rc-<target>.tar.gz` из
последнего релиза, сверяет SHA256 с `SHA256SUMS` и ставит бинарник в
`/usr/local/bin/essence-rc` (при необходимости через `sudo`); в Termux — в
`$PREFIX/bin` без root. Конкретная версия: `ESSENCE_RC_VERSION=v2.0.0`.

**Windows (x64 / ARM64):**

1. Скачайте из [последнего релиза](https://github.com/Morvex885/essence-setup-script/releases/latest)
   `essence-rc-x86_64-pc-windows-msvc.zip` (или `essence-rc-aarch64-pc-windows-msvc.zip`) и `SHA256SUMS`.
2. Сверьте хеш в PowerShell — он должен совпасть со строкой архива в `SHA256SUMS`
   (для ARM64 подставьте в обе команды `essence-rc-aarch64-pc-windows-msvc.zip`):
   ```powershell
   (Get-FileHash .\essence-rc-x86_64-pc-windows-msvc.zip -Algorithm SHA256).Hash.ToLower()
   Select-String essence-rc-x86_64-pc-windows-msvc.zip .\SHA256SUMS
   ```
3. Распакуйте `essence-rc.exe`, например, в `%USERPROFILE%\bin`. Если этого каталога
   нет в `PATH`, добавьте его один раз (PowerShell, затем откройте новое окно терминала):
   ```powershell
   New-Item -ItemType Directory -Force "$env:USERPROFILE\bin" | Out-Null
   [Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path', 'User') + ";$env:USERPROFILE\bin", 'User')
   ```
   Затем запустите `essence-rc`. Без настройки `PATH` — по полному пути
   (PowerShell: `& "$env:USERPROFILE\bin\essence-rc.exe"`, cmd:
   `"%USERPROFILE%\bin\essence-rc.exe"`).

**Из исходников (для разработки):**
```bash
git clone https://github.com/Morvex885/essence-setup-script.git
cd essence-setup-script/remote-control
cargo run -p essence-rc --release
```

> **Ручная установка на VPS (альтернативный способ):**
> Если нужно установить серверный скрипт без Remote Control:
> ```bash
> curl -fsSL https://raw.githubusercontent.com/Morvex885/essence-setup-script/main/setup-essence/install-essence.sh | sudo bash
> sudo essence-setup
> ```

## Пошаговое руководство

### 1. Запустить Remote Control

Запустите скрипт локально (см. "Быстрый старт" выше). При первом запуске будут автоматически созданы три группы: **ROUTER**, **PC**, **MOBILE**.

### 2. Добавить ноду

В главном меню нажмите `n`, затем `a` — введите IP ноды, SSH-порт, логин и способ авторизации (ключ или пароль). Для усиления защиты сначала выбирается новый порт, затем показываются нода и последствия; один вопрос с ответом «нет» по умолчанию разрешает установку ключа и отключение пароля.

### 3. Подключиться к ноде и настроить протоколы

`n` → выберите ноду по номеру → `o) Меню сервера`. Серверные скрипты загрузятся на VPS автоматически. В меню сервера:
- Выполните **базовую установку** (mihomo, systemd, UFW, BBR)
- Настройте нужные протоколы: VLESS Reality, Hysteria2, AmneziaWG, WARP, каскады

### 4. Группы

Три стандартные группы (ROUTER, PC, MOBILE) уже созданы. При необходимости добавьте свои: `g` → `a`. Каждой группе можно назначить свой шаблон конфига.

### 5. Создать клиентов

`c` → `a` → введите имя клиента и выберите группу. `vless_uuid` и `hy2_password` генерируются автоматически.

### 6. Настроить подключения нод группам

`p` → выберите ноду (вход в раздел сам запускает синхронизацию). Скрипт автоматически обнаружит настроенные протоколы по SSH. Назначьте обнаруженные прокси нужным группам.

### 7. Сгенерировать конфиги

`f` → `a` (все клиенты) или `g` (по группе). Конфиги с per-client credentials появятся в директории `generated/`; итог перечисляет готовых, пропущенных и ошибочных клиентов и ноды.

### 8. Опубликовать подписки

`s` → выберите ноду-хост для подписок → опубликуйте токены клиентам. Массовое обновление и обзор не печатают ссылки; данные конкретного клиента доступны через «Показать подписку». Клиенты получают конфиг по HTTPS:

```
https://<domain>:<port>/sub/<token>
```

## Требования

**Сервер:** Debian / Ubuntu, root-доступ, домен с A-записью (для VLESS Self-Steal и Subscription hosting)

**Локально:** только `essence-rc` (SSH встроен). Для источника GitHub — `git` и `gh`; для QR-кода подписки — `qrencode` (необязательно).

## Структура проекта

```
essence-setup/
+-- common/
|   +-- common.sh                  # UI, цвета, jq-обёртки, проверка обновлений
|   +-- cert.sh                    # Работа с TLS-сертификатами (acme.sh)
|   +-- ensure-deps.sh             # Автоустановка зависимостей
|   +-- protocols/                 # Билдеры YAML-листенеров
|       +-- vless-tcp.sh
|       +-- vless-xhttp.sh
|       +-- vless-grpc.sh
|       +-- hy2.sh
|       +-- iptables-dnat.sh       # Правила DNAT для каскадов
|       +-- uri.sh                 # Парсер/билдер vless:// hy2://
+-- setup-essence/                 # Серверный скрипт
|   +-- setup-essence.sh           # Точка входа
|   +-- install-essence.sh         # Установщик
|   +-- modules/
|       +-- base.sh                # Базовая установка (mihomo, systemd, UFW, BBR)
|       +-- vless.sh               # VLESS Reality (TCP, xHTTP, gRPC)
|       +-- hysteria.sh            # Hysteria2
|       +-- amneziawg.sh           # AmneziaWG + peers
|       +-- cascade.sh             # Каскадные подключения
|       +-- warp.sh                # Cloudflare WARP
|       +-- ipv6.sh                # IPv6 toggle
|       +-- fake-site.sh           # Decoy-сайты
|       +-- subscription.sh        # HTTPS subscription hosting
|       +-- uninstall.sh           # Полное удаление
+-- remote-control/                # Remote Control на Rust (Cargo workspace)
|   +-- core/                      # rc-core: модель, состояние, команды, SSH, GitHub, билдеры
|   |   +-- src/cli.rs             # Каталог команд (грамматика v2) и справка
|   |   +-- src/dispatch.rs        # Единый диспетчер CLI и serve, Session::mutate
|   |   +-- templates/default.yaml # Встроенный шаблон конфига
|   +-- tui/                       # essence-rc-tui: терминальное меню (только через serve)
|   +-- bin/                       # essence-rc: CLI, serve v2, запуск меню
|   +-- README.md                  # Архитектура и проверки шагов переписывания
+-- install-essence-rc.sh          # Установщик essence-rc
+-- tests/                         # BATS-тесты серверной части (unit + fuzz)
+-- docs/                          # Документация
+-- VERSION                        # Текущая версия
```
