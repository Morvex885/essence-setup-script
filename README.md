> **ОТКАЗ ОТ ОТВЕТСТВЕННОСТИ / DISCLAIMER**
>
> Данный репозиторий создан исключительно в **образовательных целях** для изучения сетевых технологий, протоколов шифрования, настройки обратных прокси и администрирования Linux-серверов.
>
> Автор **не несёт ответственности** за действия третьих лиц и за любой ущерб, прямой или косвенный, возникший в результате использования материалов репозитория. Весь риск использования лежит исключительно на пользователе.
>
> Используйте только в соответствии с законодательством вашей страны.

# Essence

Набор bash-скриптов для настройки прокси-сервера и управления клиентскими конфигами на базе ядра [mihomo (Clash.Meta)](https://github.com/MetaCubeX/mihomo).

Поддерживаемые протоколы: **VLESS Reality** (TCP, xHTTP, gRPC), **Hysteria2**, **AmneziaWG**, **WARP**, **Каскады нод**.

<img width="1746" height="1000" alt="image" src="https://github.com/user-attachments/assets/038a7816-7fb4-44e2-965f-2a84a09667f8" />

## Компоненты

| Компонент | Описание | Документация |
|-----------|----------|-------------|
| **Essence Setup** | Серверный скрипт. Устанавливается на VPS, настраивает протоколы | [docs/essence.md](docs/essence.md) |
| **Remote Control** | Локальный скрипт. Управляет серверами по SSH, генерирует клиентские конфиги | [docs/remote-control.md](docs/remote-control.md) |

## Возможности

### Серверная часть (Essence Setup)

- **Установка mihomo** — бинарник под архитектуру сервера (amd64-v3/v2, armv7, arm64), systemd-сервис, UFW с автоопределением SSH-порта, BBR и sysctl-тюнинг
- **VLESS Reality** — XTLS-Reality с тремя транспортами:
  - **TCP** (flow `xtls-rprx-vision`) на 443
  - **xHTTP** через Reality или через nginx TLS
  - **gRPC** через Reality
  Два режима: **Self-Steal** (свой домен + acme.sh) или **SNI** (маскировка под чужой SNI)
- **Hysteria2** — QUIC с опциональным `obfs salamander` для маскировки пакетов
- **AmneziaWG 2.0** — WireGuard с DPI-обфускацией (jitter, packet size, hash randomization), per-peer конфиги с QR-кодами
- **WARP** — Cloudflare WARP как исходящий прокси через `wgcf` (опционально WARP+)
- **Каскады нод** — два типа:
  - **iptables DNAT** — прозрачная пересылка уже-зашифрованного трафика
  - **Shared listener** — подключение к существующему VLESS/HY2 listener на outbound-сервере
- **Decoy-сайты** — рандомизированные HTML-шаблоны (Simple Web Templates, SNI Templates, Nothing Templates) с анти-fingerprint обфускацией
- **Subscription hosting** — HTTPS-хостинг подписок через nginx (per-token `/sub/<token>`), два режима (SNI-share с VLESS на 443 или standalone на кастомном порту), rate-limit, таймер автоочистки просроченных
- **TLS-сертификаты** — acme.sh + Let's Encrypt с автоматическим обновлением
- **IPv6 toggle** — включение/отключение системно
- **Полное удаление** — очистка всех компонентов (mihomo, AWG, WARP, nginx-конфиги, сертификаты, firewall-правила, sysctl)

### Локальная часть (Remote Control)

- **Управление нодами** — добавление VPS с AES-256-CBC шифрованием паролей, переименование с каскадным апдейтом ссылок, теги, удаление с опциональной очисткой сервера
- **SSH Hardening** — за один шаг: генерация ed25519-ключа, копирование на сервер, отключение пароля, смена SSH-порта (49152-65535), обновление firewall. Автоматический откат при любой ошибке
- **Клиенты** — создание с auto-generated `vless_uuid` + `hy2_password`, наследование нод от группы или кастомный список, смена группы с миграцией, переименование с миграцией директории
- **Группы** — шаблон на группу, маркеры `# --- GROUP ---` в YAML для per-group блоков, поддержка мульти-группы (`GROUP1/GROUP2`)
- **Подключения нод для групп** — автодискавер по SSH (VLESS/HY2/AWG/каскады), цветной обзор покрытия, батч-назначение подключений группам, авточистка stale-записей
- **AWG peers** — унифицированное управление: обзор используемых/orphan/missing peers, батч-создание недостающих, удаление orphan, один SSH на ноду
- **Генерация конфигов** — по группе или всем, per-client credentials injection, fetch-кеш proxy-конфигов с нод (один SSH на ноду), проверка дубликатов имён, автосинк listeners на нодах, автообновление подписок
- **Подписки (Subscriptions)** — публикация/отзыв/ротация токенов, пакетное обновление, миграция между нодами, HTTP-верификация (200 check), orphan-sweep
- **HTTP-заголовки подписок** — трёхуровневая наследуемость (`default → group → client`) с показом источника в resolved-view, автоквотинг для nginx
- **Шаблоны** — редактор (nano/vi) с боилерплейтом из `default.yaml`, поддержка нескольких шаблонов на проект
- **Обновления** — фоновая проверка версии при запуске, self-update из главного меню
- **Пароль на скрипт** — SHA512+salt в `.auth`, защита от случайного доступа к конфигу с кредами
- **Dev / Installed режимы** — автоопределение (dev при наличии `.git`, installed иначе), данные в `.remote-data/` или `~/.config/remote-control-essence/`

## Быстрый старт

Запустите Remote Control — он сам загрузит серверные скрипты на VPS при первом подключении к ноде.

**Linux / macOS — установка:**
```bash
curl -fsSL https://raw.githubusercontent.com/Morvex885/essence-setup-script/main/remote-control/install-remote-control.sh | sudo bash
remote-control-essence
```

**Windows:**

Скачайте [последний релиз](https://github.com/Morvex885/essence-setup-script/releases/latest) или клонируйте репозиторий, затем запустите:
```cmd
remote-control.cmd
```

**Из исходников (для разработки):**
```bash
git clone https://github.com/Morvex885/essence-setup-script.git
cd essence-setup-script
bash remote-control/remote-control-essence.sh
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

В главном меню нажмите `a` — введите IP сервера, SSH-порт, логин и способ авторизации (ключ или пароль). Если выбран пароль, скрипт предложит SSH hardening: генерация ed25519-ключа, отключение пароля, смена SSH-порта на случайный.

### 3. Подключиться к ноде и настроить протоколы

Выберите ноду по номеру → `1) Открыть меню сервера`. Серверные скрипты загрузятся на VPS автоматически. В меню сервера:
- Выполните **базовую установку** (mihomo, systemd, UFW, BBR)
- Настройте нужные протоколы: VLESS Reality, Hysteria2, AmneziaWG, WARP, каскады

### 4. Группы

Три стандартные группы (ROUTER, PC, MOBILE) уже созданы. При необходимости добавьте свои: `G` → `a`. Каждой группе можно назначить свой шаблон конфига.

### 5. Создать клиентов

`C` → `a` → введите имя клиента и выберите группу. `vless_uuid` и `hy2_password` генерируются автоматически.

### 6. Настроить подключения нод группам

`P` → выберите ноду. Скрипт автоматически обнаружит настроенные протоколы по SSH. Назначьте обнаруженные прокси нужным группам.

### 7. Сгенерировать конфиги

`F` → `a` (все клиенты) или `g` (по группе). Конфиги с per-client credentials появятся в директории `generated/`.

### 8. Опубликовать подписки

`S` → выберите ноду-хост для подписок → опубликуйте токены клиентам. Клиенты получают конфиг по HTTPS:

```
https://<domain>:<port>/sub/<token>
```

## Требования

**Сервер:** Debian / Ubuntu, root-доступ, домен с A-записью (для VLESS Self-Steal и Subscription hosting)

**Локально:** `ssh`, `jq`, `openssl`. На Windows — WSL. Отсутствующие зависимости скрипт пробует поставить сам через `common/ensure-deps.sh`.

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
+-- remote-control/                # Локальный скрипт
|   +-- remote-control-essence.sh  # Точка входа
|   +-- install-remote-control.sh  # Установщик
|   +-- modules/
|   |   +-- nodes.sh               # Хранилище нод, шифрование паролей
|   |   +-- ssh.sh                 # SSH/SCP обёртки
|   |   +-- hardening.sh           # SSH hardening (ключ + порт)
|   |   +-- clients.sh             # Клиенты + per-client credentials
|   |   +-- groups.sh              # Группы + шаблоны
|   |   +-- connections.sh         # Подключения нод для групп + дискавер
|   |   +-- awg_peers.sh           # AWG peers lifecycle
|   |   +-- templates.sh           # Обработка шаблонов (группы-маркеры)
|   |   +-- generate.sh            # Генерация конфигов + listener sync
|   |   +-- subscription.sh        # Публикация/ротация/отзыв подписок
|   |   +-- self.sh                # Обновление, пароль, удаление
|   +-- templates/
|       +-- default.yaml           # Шаблон конфига по умолчанию
+-- tests/                         # BATS-тесты (unit + fuzz)
+-- docs/                          # Документация
+-- remote-control.cmd             # Лаунчер для Windows (WSL)
+-- VERSION                        # Текущая версия
```
