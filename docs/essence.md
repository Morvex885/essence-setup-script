# Essence Setup — серверный скрипт

Устанавливается на VPS-сервер. Настраивает прокси-протоколы, VPN-туннели, firewall, TLS-сертификаты и HTTPS-хостинг подписок для клиентов.

## Меню

| Пункт | Описание |
|---|---|
| **1) Базовая установка** | Установка mihomo, systemd-сервис, UFW, BBR, sysctl tuning |
| **2) VLESS Reality** | VLESS с XTLS-Reality (TCP, xHTTP, gRPC), Self-Steal / SNI режимы, Nginx + acme.sh |
| **3) Hysteria2** | Протокол Hysteria2 (QUIC), опционально с obfs salamander |
| **4) AmneziaWG 2.0** | AmneziaWG VPN-туннели с автоматическим созданием peers |
| **5) IPv6** | Включение / отключение IPv6 на сервере |
| **6) WARP** | Cloudflare WARP (WireGuard) как исходящий прокси |
| **7) Каскады нод** | Каскадные подключения между серверами (iptables DNAT или shared listener) |
| **8) Клиентский конфиг** | Показать готовый конфиг для подключения |
| **9) Серверный конфиг** | Показать текущий конфиг mihomo |
| **10) Обновить скрипты** | Обновление до последней версии |
| **s) Subscription hosting** | HTTPS-хостинг подписок через nginx (`/sub/<token>`) |
| **u) Удалить** | Полное удаление всех компонентов |

### Telegram Proxy — WEB и MTProto

Telegram Proxy состоит из двух независимых компонентов, которые используют общий
секрет, необязательный tag и MTProxy backend:

| Компонент | Входные порты | Назначение |
|---|---|---|
| **WEB relay** | TCP/443 через nginx, HTTP-01 на TCP/80 | Telegram WEB/WebSocket relay |
| **MTProto** | TCP/2398 | Клиентский MTProto |
| **Общий backend** | TCP/8080, TCP/8081 | Внутренние relay/health/readiness endpoints |
| **Статистика** | TCP/8888 | Только локальный backend stats; публичный доступ закрыт |

WEB требует hostname с DNS A-записью на публичный IPv4 и email для Let's Encrypt.
Установка WEB сначала проверяет provider firewall, готовит backend и relay, затем
получает сертификат и только после успешного `nginx -t` публикует конфигурацию.
Отмена выбора decoy-сайта или ошибка ACME откатывает файлы, users, units,
nginx, nftables и UFW к снимку до операции.

MTProto-only не требует hostname и сертификата, но provider firewall должен
разрешать TCP/2398. В combined-режиме WEB и MTProto можно удалять отдельно:
удаление WEB оставляет MTProto, tag и общий backend; удаление MTProto оставляет
WEB. `remove-all --force` удаляет оба компонента только после явного вызова.

Локальный CLI:

```text
telegram-proxy web install|restart|update|remove [--force]
telegram-proxy mtproto install|restart|refresh-ip|remove [--force]
telegram-proxy status [--json]
telegram-proxy connection
telegram-proxy diagnostics
telegram-proxy rotate-secret [--force]
telegram-proxy tag show|set|clear [--force для clear]
telegram-proxy remove-all --force
```

`status --json` — один JSON-объект без secret и tag. `connection` — единственная
команда, печатающая raw secret и ссылки; `tag show` печатает tag явно.
Диагностика редактирует secret, tag, Authorization и request credentials.
После rotate-secret оба включённых consumer'а проверяются; при ошибке старые
env/profiles и runtime возвращаются. Upstream relay собирается только из
зафиксированной ревизии `f7a6acc4d536a787d442fd7df3ba4ebfd728f406`; mutable
ветки не используются.

### VLESS Reality — подменю

| Пункт | Описание |
|---|---|
| **1) Настройка Reality** | Выбор режима (Self-Steal / SNI), домен, сертификат, ключи |
| **2) Добавить TCP** | VLESS TCP с flow xtls-rprx-vision на порту 443 |
| **3) Добавить xHTTP** | VLESS xHTTP — через Reality (порт 443 или кастомный) или через nginx TLS |
| **4) Добавить gRPC** | VLESS gRPC через Reality |
| **d) Удалить транспорт** | Динамический список установленных транспортов |
| **s) Статус** | Показать текущие настройки Reality и установленные транспорты |

#### Режимы Reality

- **Self-Steal** — скрипт маскируется под собственный домен с реальным TLS-сертификатом (acme.sh + Let's Encrypt). Нужен собственный домен с A-записью на сервер.
- **SNI** — трафик маскируется под чужой домен (например, `google.com`). Сертификат запрашивать не нужно, но можно развернуть локальный decoy-сайт.

### Hysteria2 — подменю

- **1) Установить** — самоподписанный сертификат, выбор порта, опциональный `obfs salamander` (маскирует QUIC-сигнатуру XOR'ом с общим паролем)
- **2) Удалить**

### AmneziaWG — подменю

- **1) Установить сервер** — интерфейс `awg0` в подсети 10.10.8.0/24, параметры обфускации (Jc/Jmin/Jmax, S1-S4, H1-H4)
- **2) Добавить клиента (peer)** — генерит конфиг, QR-код и mihomo-проксий
- **3) Удалить клиента**
- **4) Удалить AmneziaWG**

### Каскады — подменю

- **1) Добавить каскад** — два типа:
  - **iptables DNAT** — прозрачный proxy через netfilter для уже зашифрованного трафика (Reality / HY2)
  - **Shared listener** — добавить cascade-пользователя на существующий VLESS/Hysteria2 listener с под-правилом в IN-USER
- **2) Удалить каскад**

### Subscription hosting — подменю

После установки меняется набор пунктов:

| Пункт | До установки | После |
|---|---|---|
| **1)** | Установить | Статус |
| **2)** | — | Удалить |

Скрипт настраивает nginx, получает TLS-сертификаты через acme.sh и регистрирует директорию для per-client YAML + per-token nginx snippets. Два режима:

- **Порт 443 (nginx-integrated)** — разделяет порт с VLESS Reality через SNI routing (stream upstream). Нужен отдельный поддомен для подписок.
- **Кастомный порт (standalone)** — свой HTTPS-сервер, не зависит от VLESS.

Лимитирование: 10 req/min на IP, burst 5. Таймер `essence-sub-cleanup.timer` раз в 5 минут чистит просроченные подписки.

## Требования

- Debian / Ubuntu (с `apt`)
- Bash 3.2+
- Root-доступ
- Домен с A-записью, указывающей на IP сервера (для VLESS Reality в Self-Steal и для Subscription hosting)

## Установка

```bash
curl -fsSL https://raw.githubusercontent.com/Morvex885/essence-setup/main/setup-essence/install-essence.sh | sudo bash
```

После установки:
```bash
sudo essence-setup
```

## Обновление

При запуске скрипт автоматически проверяет наличие новой версии. Для обновления выберите пункт **10) Обновить скрипты** в меню.

## Файлы после установки

| Путь | Описание |
|---|---|
| `/etc/mihomo/config.yaml` | Конфиг mihomo (сервер) |
| `/etc/mihomo/client-config.txt` | Готовый клиентский конфиг |
| `/etc/mihomo/reality.conf` | Параметры Reality (режим, ключи, SNI, домен) |
| `/etc/mihomo/certs/hy2/` | Самоподписанные сертификаты Hysteria2 |
| `/etc/mihomo/wgcf-profile.conf` | WireGuard-профиль WARP (если установлен) |
| `/etc/mihomo/subscription.conf` | Параметры Subscription hosting (URL, порт, режим) |
| `/etc/mihomo/amnezia/<peer>/` | Конфиги AmneziaWG peers + QR |
| `/etc/amnezia/amneziawg/awg0.conf` | Серверный AWG-интерфейс |
| `/etc/nginx/ssl/<domain>/` | TLS-сертификаты (Let's Encrypt) |
| `/etc/nginx/snippets/essence-sub/` | Per-token nginx-снипеты подписок |
| `/var/lib/essence-sub/` | Опубликованные `<token>.yaml` |
| `/var/www/<domain>/` | Decoy-сайт (при Self-Steal / SNI+cert) |

## Полезные команды

```bash
systemctl status mihomo              # Статус mihomo
journalctl -u mihomo -f              # Логи mihomo
nano /etc/mihomo/config.yaml         # Редактировать серверный конфиг
cat /etc/mihomo/client-config.txt    # Показать клиентский конфиг
awg show                             # Статус AmneziaWG
nginx -t && systemctl reload nginx   # Перезагрузить nginx после правок
```
