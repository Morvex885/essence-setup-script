//! CLI grammar v2: `noun verb --flags`, one catalog for parsing and help.
//!
//! The catalog ports v1 `cli_spec_*` token lists (`name=` value, `name+`
//! repeatable, `name` boolean) with the v2 renames: `sub` → `subscription`,
//! and `--name` as the single selector of the command's own object (nodes for
//! `conn`/`awg`/`telegram`, clients/nodes for `subscription`). Relation flags
//! (`--node`, `--group`, `--client`) keep their v1 meaning. Each command is
//! parsed by a clap command built from its catalog row. Global flags
//! `--json --yes --plan-token --secrets-stdin --help` may appear anywhere.
//! Flag values may not contain a newline; no flag carries a secret value.
//! An `@name` token declares request input (file contents): the daemon's
//! parser does not know it, the client's parser reads it as `--name PATH`;
//! `@name?` is optional input (the client reads it only when given).

use std::collections::{BTreeMap, BTreeSet};

use clap::{Arg, ArgAction, Command, error::{ContextKind, ContextValue, ErrorKind}};
use serde_json::{Value, json};

use crate::error::{RcError, Result};

const NOSESSION: u8 = 1;
const TTY: u8 = 2;
/// Accepted only from the local socket.
const LOCAL: u8 = 4;
/// Executed by the CLI process itself, never sent to the daemon.
const CLIENT: u8 = 8;

/// One command: tokens use v1 syntax without `@secret` / `!flag` markers;
/// `@name` is request input (see the module docs).
struct Spec {
    noun: &'static str,
    verb: &'static str,
    tokens: &'static str,
    secrets: &'static [&'static str],
    flags: u8,
}

const fn spec(noun: &'static str, verb: &'static str, tokens: &'static str,
    secrets: &'static [&'static str], flags: u8) -> Spec
{
    Spec { noun, verb, tokens, secrets, flags }
}

const VAULT: &[&str] = &["vault-password", "new-vault-password"];
const TELEGRAM: &str = "name+ all component=";
/// Listener flags of `web start` (and, after `--web`, of `daemon run|start`).
const WEB: &str = "bind= port= tls-cert= tls-key= no-tls";
/// `daemon run|start`: the listener and the data directory (`--data-dir`
/// wins over `ESSENCE_RC_DATA_DIR`; services pass it this way).
const DAEMON_WEB: &str = "web bind= port= tls-cert= tls-key= no-tls data-dir=";

static CATALOG: &[Spec] = &[
    spec("status", "", "", &[], 0),
    spec("session", "status", "", &[], NOSESSION),
    spec("session", "open", "remember-key", &["vault-password", "script-password", "access-token"], NOSESSION),
    spec("source", "init-local", "", &[], NOSESSION),
    spec("source", "status", "", &[], 0),
    spec("source", "github-accounts", "", &[], NOSESSION),
    spec("source", "github-login", "login=", &[], NOSESSION),
    spec("source", "github-connect",
        "login= create-repo make-private storage= existing= provision-keys= remember-key replace-target", VAULT, NOSESSION),
    spec("source", "github-fetch", "", &[], 0),
    spec("source", "github-push", "", &[], 0),
    spec("source", "github-change-account",
        "login= create-repo make-private storage= existing= without-cache replace-target", VAULT, 0),
    spec("source", "github-rewrap-password", "", VAULT, 0),
    spec("source", "github-rotate-key", "", &["new-vault-password"], 0),
    spec("source", "github-import-recovery-key", "@file", &[], 0),
    spec("source", "github-switch-local", "", &[], 0),
    spec("source", "github-replace-with-local", "provision-keys=", &["vault-password", "script-password"], NOSESSION),
    spec("source", "github-migrate-format", "", &["vault-password", "script-password"], NOSESSION),
    spec("source", "github-delete-repo", "", &[], 0),
    spec("self", "version", "", &[], NOSESSION),
    spec("self", "update", "", &[], 0),
    spec("self", "uninstall", "remove-data", &[], 0),
    spec("self", "password-set", "", &["password", "current-password"], 0),
    spec("self", "password-remove", "", &["current-password"], 0),
    spec("daemon", "status", "", &[], NOSESSION),
    spec("daemon", "stop", "", &[], NOSESSION | LOCAL),
    spec("daemon", "run", DAEMON_WEB, &[], CLIENT),
    spec("daemon", "start", DAEMON_WEB, &[], CLIENT),
    spec("web", "status", "", &[], NOSESSION),
    spec("web", "start", WEB, &[], NOSESSION | LOCAL),
    spec("web", "stop", "", &[], NOSESSION | LOCAL),
    spec("web", "link", "", &[], NOSESSION | LOCAL),
    spec("web", "run", "bind= port= tls-cert= tls-key= no-tls no-open", &[], CLIENT),
    spec("web", "open", "no-open", &[], CLIENT),
    spec("web", "install-service", WEB, &[], CLIENT),
    spec("web", "uninstall-service", "", &[], CLIENT),
    spec("node", "list", "", &[], 0),
    spec("node", "show", "name=", &[], 0),
    spec("node", "aliases", "name= set+ unset+", &[], 0),
    spec("node", "rename", "name= new-name=", &[], 0),
    spec("node", "tag", "name= tag=", &[], 0),
    spec("node", "password", "name=", &["password"], 0),
    spec("node", "add",
        "name= ip= port= user= auth= tag= host-key= accept-new-host-key replace-host-key= defer-ssh-setup",
        &["password"], 0),
    spec("node", "trust-host-key", "name= host-key=", &[], 0),
    spec("node", "delete", "name= scope= revoke-key", &[], 0),
    spec("node", "check", "name=", &[], 0),
    spec("node", "upload-scripts", "name= force", &[], 0),
    spec("node", "harden", "name= port=", &[], 0),
    spec("node", "setup-ssh", "provision-keys= on-failure=", &[], 0),
    spec("node", "shell", "name=", &[], TTY),
    spec("conn", "list", "name= discover", &[], 0),
    spec("conn", "set", "name= group+ proxy+", &[], 0),
    spec("conn", "sync", "name=", &[], 0),
    spec("awg", "status", "name=", &[], 0),
    spec("awg", "sync", "name=", &[], 0),
    spec("awg", "remove", "name= peer+ orphans", &[], 0),
    spec("telegram", "status", TELEGRAM, &[], 0),
    spec("telegram", "install", TELEGRAM, &[], 0),
    spec("telegram", "refresh-ip", TELEGRAM, &[], 0),
    spec("telegram", "web-update", TELEGRAM, &[], 0),
    spec("telegram", "web-restart", TELEGRAM, &[], 0),
    spec("telegram", "backend-restart", TELEGRAM, &[], 0),
    spec("telegram", "remove", TELEGRAM, &[], 0),
    spec("telegram", "remove-all", TELEGRAM, &[], 0),
    spec("telegram", "menu", "name=", &[], TTY),
    spec("group", "list", "", &[], 0),
    spec("group", "add", "name=", &[], 0),
    spec("group", "delete", "name=", &[], 0),
    spec("group", "set-template", "name= template=", &[], 0),
    spec("template", "list", "", &[], 0),
    spec("template", "show", "name=", &[], 0),
    spec("template", "create", "name= from= group=", &[], 0),
    spec("template", "export", "name= output=", &[], CLIENT),
    spec("template", "import", "name= @file", &[], 0),
    spec("template", "delete", "name=", &[], 0),
    spec("template", "groups", "name= group+", &[], 0),
    spec("template", "check", "name= @file?", &[], 0),
    spec("client", "list", "group=", &[], 0),
    spec("client", "show", "name=", &[], 0),
    spec("client", "config", "name=", &[], 0),
    spec("client", "connections", "name= node= proxy+ reset", &[], 0),
    spec("client", "add", "name= group=", &[], 0),
    spec("client", "rename", "name= new-name=", &[], 0),
    spec("client", "nodes", "name= inherit node+", &[], 0),
    spec("client", "set-group", "name= group=", &[], 0),
    spec("client", "delete", "name+", &[], 0),
    spec("generate", "", "all group= client=", &[], 0),
    spec("subscription", "host", "name=", &[], 0),
    spec("subscription", "list", "", &[], 0),
    spec("subscription", "show", "name=", &[], 0),
    spec("subscription", "headers", "client= group= default set+ unset+", &[], 0),
    spec("subscription", "publish", "name= ttl=", &[], 0),
    spec("subscription", "publish-all", "", &[], 0),
    spec("subscription", "rotate", "name=", &[], 0),
    spec("subscription", "revoke", "name=", &[], 0),
    spec("subscription", "migrate", "name=", &[], 0),
];

/// Help catalog: general lines, then nouns in byte order (v1 `LC_ALL=C sort`).
static HELP: &[(&str, &[(&str, &str)])] = &[
    ("help", &[
        ("help [СУЩНОСТЬ]", "Справка по командам (то же: --help, -h, <сущность> --help)"),
        ("… --json", "Ответ одним JSON-объектом {id, ok, data} или {id, ok, error} в stdout; журнал — в stderr"),
        ("… --yes [--plan-token T]", "Подтвердить опасное действие; T — plan_token из ответа confirmation_required"),
        ("… --secrets-stdin", "Секреты из stdin: JSON-объект {\"имя\":\"значение\"}; без флага — скрытый ввод с консоли"),
        ("ESSENCE_RC_DATA_DIR, RC_LOCK_WAIT, ESSENCE_RC_RUNTIME_DIR, ESSENCE_RC_DAEMON_LINGER", "Окружение: каталог данных, ожидание блокировки (с), каталог сокета демона, простой демона до выхода (с); RC_LOCK_WAIT и GITHUB_TOKEN читаются из окружения демона"),
        ("--connect URL [--fingerprint SHA256:…] [--insecure] КОМАНДА", "Выполнить команду на удалённом демоне (https://host[:port]); --fingerprint закрепляет сертификат, --insecure разрешает http:// не на loopback"),
        ("ESSENCE_RC_CONNECT, ESSENCE_RC_FINGERPRINT, ESSENCE_RC_INSECURE", "Окружение: то же, что --connect, --fingerprint и --insecure (=1)"),
        ("Коды выхода", "0 — успех; 1 — ошибка; 2 — неверное использование, нужно решение или --yes; telegram: 3 — не установлено, 4 — частично"),
    ]),
    ("awg", &[
        ("awg status --name N", "Клиенты AmneziaWG на ноде"),
        ("awg sync --name N", "Создать недостающих клиентов AmneziaWG"),
        ("awg remove --name N (--peer P… | --orphans) [--yes]", "Удалить клиентов AmneziaWG"),
    ]),
    ("client", &[
        ("client list [--group G]", "Список клиентов"),
        ("client show --name C", "Подробности клиента (с секретами)"),
        ("client config --name C", "Содержимое готового конфига клиента (с секретами)"),
        ("client connections --name C [--node N (--proxy P… | --reset [--yes])]", "Подключения клиента"),
        ("client add --name C --group G", "Добавить клиента"),
        ("client rename --name C --new-name D [--yes]", "Переименовать клиента"),
        ("client nodes --name C (--inherit [--yes] | --node N…)", "Ноды клиента"),
        ("client set-group --name C --group G [--yes]", "Сменить группу клиента"),
        ("client delete --name C… [--yes]", "Удалить клиентов"),
    ]),
    ("conn", &[
        ("conn list [--name N [--discover]]", "Подключения нод по группам"),
        ("conn set --name N --group G… [--proxy P…]", "Назначить подключения группам (без --proxy — снять)"),
        ("conn sync [--name N]", "Обнаружить подключения нод по SSH и убрать устаревшие назначения"),
    ]),
    ("daemon", &[
        ("daemon status", "Состояние демона: клиенты, сессия, терминалы"),
        ("daemon stop", "Остановить демон после текущей операции"),
        ("daemon run [--data-dir PATH] [--web [--bind IP] [--port P] [--tls-cert PATH --tls-key PATH | --no-tls]]", "Запустить демон на переднем плане; с --web — постоянный режим с веб-панелью; --data-dir важнее ESSENCE_RC_DATA_DIR"),
        ("daemon start [--data-dir PATH] [--web [--bind IP] [--port P] [--tls-cert PATH --tls-key PATH | --no-tls]]", "Запустить демон в фоне и напечатать адрес подключения"),
    ]),
    ("generate", &[
        ("generate (--all | --group G | --client C)", "Сгенерировать конфиги"),
    ]),
    ("group", &[
        ("group list", "Список групп"),
        ("group add --name G", "Добавить группу"),
        ("group delete --name G [--yes]", "Удалить группу"),
        ("group set-template --name G --template T", "Назначить шаблон группе"),
    ]),
    ("node", &[
        ("node list", "Список нод"),
        ("node show --name N", "Подробности ноды и варианты удаления"),
        ("node aliases --name N [--set ORIG=ALIAS…] [--unset ORIG…]", "Псевдонимы подключений (без --set/--unset — обнаружить по SSH)"),
        ("node rename --name N --new-name M", "Переименовать ноду (имя: латиница, цифры, «.», «_», «-»)"),
        ("node tag --name N --tag T", "Задать тег ноды (пустой допустим; до 32 символов, без управляющих и служебных символов)"),
        ("node password --name N", "Сохранить пароль SSH (секрет password)"),
        ("node add --name N --ip IP [--port 22] [--user root] --auth key|password --tag T [--host-key SHA256:… | --accept-new-host-key] [--replace-host-key SHA256:… [--yes]] [--defer-ssh-setup]", "Добавить ноду (для --auth password — секрет password)"),
        ("node trust-host-key --name N --host-key SHA256:… [--yes]", "Доверять новому ключу сервера ноды"),
        ("node delete --name N [--scope local|server] [--revoke-key] [--yes]", "Удалить ноду"),
        ("node check --name N", "Проверить SSH-подключение"),
        ("node upload-scripts --name N [--force [--yes]]", "Загрузить скрипты на ноду"),
        ("node harden --name N [--port P] [--yes]", "Усилить защиту SSH: ключ, отключение пароля, новый порт (без --port — детерминированный свободный порт из плана)"),
        ("node setup-ssh [--provision-keys yes|no] [--on-failure rollback|defer] [--yes]", "Завершить отложенную SSH-настройку нод (GitHub)"),
        ("node shell --name N", "Открыть меню сервера по SSH (нужен терминал)"),
    ]),
    ("self", &[
        ("self version", "Текущая и последняя версия"),
        ("self update [--yes]", "Обновить essence-rc до последней версии"),
        ("self uninstall [--remove-data] [--yes]", "Удалить essence-rc (данные сохраняются без --remove-data)"),
        ("self password-set", "Установить или сменить пароль запуска (секреты password, current-password)"),
        ("self password-remove [--yes]", "Убрать пароль запуска (секрет current-password)"),
    ]),
    ("session", &[
        ("session status", "Состояние: создана ли конфигурация, открыта ли сессия"),
        ("session open [--remember-key]", "Открыть источник и проверить пароль запуска (секреты script-password, vault-password, access-token)"),
    ]),
    ("source", &[
        ("source init-local", "Создать локальную конфигурацию"),
        ("source status", "Источник: тип, репозиторий, ветка, хранение, синхронизация"),
        ("source github-accounts", "Сохранённые аккаунты GitHub и глобальный вход gh"),
        ("source github-login --login L", "Войти в GitHub через браузер (код устройства — в журнале)"),
        ("source github-connect --login L [--create-repo] [--make-private] [--storage age|none] [--existing remote|local|migrate] [--provision-keys yes|no] [--remember-key] [--replace-target] [--yes]", "Подключить GitHub (секреты vault-password, new-vault-password)"),
        ("source github-fetch", "Загрузить конфигурацию из GitHub"),
        ("source github-push", "Отправить конфигурацию в GitHub"),
        ("source github-change-account --login L [--create-repo] [--make-private] [--storage age|none] [--existing remote|local] [--without-cache] [--replace-target] [--yes]", "Сменить аккаунт GitHub (секреты vault-password, new-vault-password)"),
        ("source github-rewrap-password", "Сменить пароль доступа (секреты vault-password, new-vault-password)"),
        ("source github-rotate-key [--yes]", "Новый ключ шифрования (секрет new-vault-password)"),
        ("source github-import-recovery-key --file PATH", "Импортировать ключ восстановления для текущего сеанса"),
        ("source github-switch-local", "Работать локально без синхронизации с GitHub"),
        ("source github-replace-with-local [--provision-keys yes|no] [--yes]", "Заменить конфигурацию GitHub конфигурацией этого компьютера (секреты script-password, vault-password)"),
        ("source github-migrate-format [--yes]", "Преобразовать конфигурацию GitHub в текущий формат (секреты script-password, vault-password)"),
        ("source github-delete-repo [--yes]", "Удалить репозиторий GitHub (конфигурация останется локально)"),
    ]),
    ("status", &[
        ("status", "Сводка: версия, источник, счётчики, проблемы"),
    ]),
    ("subscription", &[
        ("subscription host [--name N]", "Хост-нода подписок (с --name — задать)"),
        ("subscription list", "Список подписок"),
        ("subscription show --name C", "Ссылка и заголовки подписки"),
        ("subscription headers (--client C | --group G | --default) [--set NAME=VALUE…] [--unset NAME…]", "Заголовки подписки"),
        ("subscription publish --name C [--ttl 30d]", "Опубликовать подписку (TTL: 12h, 30d, 2w)"),
        ("subscription publish-all [--yes]", "Опубликовать все готовые подписки и удалить с хоста подписки без клиента"),
        ("subscription rotate --name C [--yes]", "Перевыпустить ссылку"),
        ("subscription revoke --name C [--yes]", "Отозвать подписку"),
        ("subscription migrate --name N [--yes]", "Перенести подписки на другую ноду"),
    ]),
    ("telegram", &[
        ("telegram status [--name N… | --all]", "Состояние Telegram Proxy"),
        ("telegram install (--name N… | --all) [--yes]", "Действия Telegram Proxy: установить"),
        ("telegram refresh-ip (--name N… | --all) [--yes]", "Действия Telegram Proxy: обновить IP"),
        ("telegram web-update (--name N… | --all) [--yes]", "Действия Telegram Proxy: обновить веб-часть"),
        ("telegram web-restart (--name N… | --all) [--yes]", "Действия Telegram Proxy: перезапустить веб-часть"),
        ("telegram backend-restart (--name N… | --all) [--yes]", "Действия Telegram Proxy: перезапустить backend"),
        ("telegram remove --component web|mtproto (--name N… | --all) [--yes]", "Удалить компонент Telegram Proxy"),
        ("telegram remove-all (--name N… | --all) [--yes]", "Удалить Telegram Proxy целиком"),
        ("telegram menu --name N [--yes]", "Серверное меню Telegram Proxy одной ноды (нужен терминал)"),
    ]),
    ("template", &[
        ("template list", "Список шаблонов"),
        ("template show --name T", "Показать шаблон"),
        ("template create --name N [--from T] [--group G]", "Создать шаблон на основе другого"),
        ("template export --name T --output PATH [--yes]", "Сохранить шаблон в файл"),
        ("template import --name T --file PATH [--yes]", "Загрузить шаблон из файла"),
        ("template delete --name T [--yes]", "Удалить пользовательский шаблон"),
        ("template groups --name T [--group G…] [--yes]", "Задать группы шаблона (остальные его группы — на default.yaml)"),
        ("template check [--name T] [--file PATH]", "Проверить шаблон (YAML, маркеры, схема mihomo): файл, если указан, иначе шаблон T"),
    ]),
    ("web", &[
        ("web status", "Состояние веб-панели: адрес, TLS, отпечаток сертификата, подключения"),
        ("web start [--bind IP] [--port P] [--tls-cert PATH --tls-key PATH | --no-tls]", "Запустить веб-панель в работающем демоне (порт 0 — выбирает ОС)"),
        ("web stop", "Остановить веб-панель и закрыть сетевые подключения"),
        ("web link", "Ссылка для входа в веб-панель; без пароля запуска — с одноразовым кодом на 5 минут"),
        ("web run [--bind IP] [--port P] [--tls-cert PATH --tls-key PATH | --no-tls] [--no-open]", "Запустить веб-панель и открыть её в браузере; Ctrl+C — остановить"),
        ("web open [--no-open]", "Открыть работающую веб-панель в браузере"),
        ("web install-service [--bind IP] [--port P] [--tls-cert PATH --tls-key PATH | --no-tls]", "Установить автозапуск веб-панели"),
        ("web uninstall-service", "Удалить автозапуск веб-панели"),
    ]),
];

/// A parsed command. Option values are retained for handlers; the original
/// flag arguments (without noun and verb) form the confirmation scope.
pub struct Invocation {
    pub noun: String,
    pub verb: String,
    pub json: bool,
    pub yes: bool,
    pub plan_token: Option<String>,
    pub secrets_stdin: bool,
    pub help: bool,
    help_noun: Option<String>,
    values: BTreeMap<&'static str, Vec<String>>,
    flags: BTreeSet<&'static str>,
    secrets: &'static [&'static str],
    inputs: Vec<&'static str>,
    session: bool,
    tty: bool,
    local: bool,
    client: bool,
    /// Catalog row of a command (none for help).
    spec: Option<&'static Spec>,
    confirmation: Vec<String>,
}

impl Invocation {
    fn help(help_noun: Option<String>, json: bool) -> Self {
        Self {
            noun: "help".into(), verb: String::new(), json, yes: false, plan_token: None,
            secrets_stdin: false, help: true, help_noun, values: BTreeMap::new(), flags: BTreeSet::new(),
            secrets: &[], inputs: Vec::new(), session: false, tty: false, local: false, client: false, spec: None,
            confirmation: Vec::new(),
        }
    }

    pub fn has(&self, name: &str) -> bool {
        self.flags.contains(name) || self.values.contains_key(name)
    }

    pub fn value(&self, name: &str) -> Option<&str> {
        self.values.get(name).and_then(|values| values.first()).map(String::as_str)
    }

    pub fn values(&self, name: &str) -> &[String] {
        self.values.get(name).map_or(&[], Vec::as_slice)
    }

    pub fn allowed_secrets(&self) -> &'static [&'static str] {
        self.secrets
    }

    /// Request input names (`@name` tokens); the client reads them from `--name PATH`.
    pub fn inputs(&self) -> &[&'static str] {
        &self.inputs
    }

    /// The input is `@name?`: the client reads it only when `--name` is given.
    pub fn input_optional(&self, name: &str) -> bool {
        self.spec.is_some_and(|spec| catalog_tokens(spec).any(|(base, kind)| base == name && kind == '?'))
    }

    /// Accepted only from the daemon's local socket.
    pub fn local_only(&self) -> bool {
        self.local
    }

    /// Executed by the CLI process; the daemon never runs it.
    pub fn client_side(&self) -> bool {
        self.client
    }

    /// `argv` as sent to the daemon: without `--secrets-stdin` and without
    /// the client-side input flags (`--name PATH`, `--name=PATH` of every
    /// `@name`). Flag values are skipped by the catalog's grammar, so a value
    /// that looks like one of these flags stays.
    pub fn daemon_argv(&self, argv: &[String]) -> Vec<String> {
        let mut kept = Vec::with_capacity(argv.len());
        let mut args = argv.iter();
        while let Some(arg) = args.next() {
            let Some(flag) = arg.strip_prefix("--") else {
                kept.push(arg.clone());
                continue;
            };
            if flag == "secrets-stdin" {
                continue;
            }
            let (name, inline) = flag.split_once('=').map_or((flag, false), |(name, _)| (name, true));
            let takes_value = !inline && (name == "plan-token"
                || self.spec.is_some_and(|spec| matches!(token_kind(spec, name, true), Some('=' | '+'))));
            if self.inputs.contains(&name) {
                if takes_value {
                    args.next();
                }
                continue;
            }
            kept.push(arg.clone());
            if takes_value && let Some(value) = args.next() {
                kept.push(value.clone());
            }
        }
        kept
    }

    pub fn requires_session(&self) -> bool {
        self.session
    }

    /// `!tty` commands need an interactive console (`node shell`, `telegram menu`).
    pub fn requires_tty(&self) -> bool {
        self.tty
    }

    /// Original arguments except the noun and verb positionals and
    /// `--secrets-stdin` (a transport flag, stripped before dispatch in v1).
    pub fn confirmation_args(&self) -> &[String] {
        &self.confirmation
    }

    pub fn help_noun(&self) -> Option<&str> {
        self.help_noun.as_deref()
    }
}

fn usage(message: impl Into<String>) -> RcError {
    RcError::new("usage", message)
}

fn hint(noun: &str) -> String {
    if noun.is_empty() { "Справка: essence-rc --help".into() } else { format!("Справка: essence-rc {noun} --help") }
}

fn known_noun(noun: &str) -> bool {
    noun == "help" || CATALOG.iter().any(|spec| spec.noun == noun)
}

fn find(noun: &str, verb: &str) -> Option<&'static Spec> {
    CATALOG.iter().find(|spec| spec.noun == noun && spec.verb == verb)
}

fn bare(noun: &str) -> bool {
    find(noun, "").is_some()
}

/// Leading/interleaved global flags; `--plan-token` consumes its value.
pub fn global_width(argv: &[String], index: usize) -> Option<usize> {
    match argv[index].as_str() {
        "--json" | "--yes" | "--secrets-stdin" | "--help" | "-h" => Some(1),
        "--plan-token" => Some(2),
        arg if arg.starts_with("--plan-token=") => Some(1),
        _ => None,
    }
}

fn wants_help(argv: &[String], index: usize) -> bool {
    matches!(argv[index].as_str(), "--help" | "-h")
}

/// Index of the next non-global token at or after `index`, noting help flags.
fn next_positional(argv: &[String], mut index: usize, help: &mut bool) -> Option<usize> {
    while index < argv.len() {
        match global_width(argv, index) {
            Some(width) => {
                *help |= wants_help(argv, index);
                index += width;
            }
            None => return Some(index),
        }
    }
    None
}

/// Every catalog token of a row as `(name, kind)`: `=` value, `+`
/// repeatable, `b` boolean, `@` request input, `?` optional request input.
fn catalog_tokens(spec: &'static Spec) -> impl Iterator<Item = (&'static str, char)> {
    spec.tokens.split_whitespace().map(|token| {
        if let Some(name) = token.strip_prefix('@') {
            return name.strip_suffix('?').map_or((name, '@'), |name| (name, '?'));
        }
        match token.as_bytes().last() {
            Some(b'=') => (&token[..token.len() - 1], '='),
            Some(b'+') => (&token[..token.len() - 1], '+'),
            _ => (token, 'b'),
        }
    })
}

/// A row's flags as the parser sees them. An `@name` input is a value flag
/// only for the client parser (`client`); the daemon's parser skips it.
fn tokens(spec: &'static Spec, client: bool) -> impl Iterator<Item = (&'static str, char)> {
    catalog_tokens(spec).filter_map(move |(name, kind)| match kind {
        '@' | '?' => client.then_some((name, '=')),
        _ => Some((name, kind)),
    })
}

/// Request input names (`@name` / `@name?` tokens) of a row.
fn inputs(spec: &'static Spec) -> impl Iterator<Item = &'static str> {
    catalog_tokens(spec).filter_map(|(name, kind)| matches!(kind, '@' | '?').then_some(name))
}

fn token_kind(spec: &'static Spec, name: &str, client: bool) -> Option<char> {
    tokens(spec, client).find_map(|(base, kind)| (base == name).then_some(kind))
}

/// v1 `_cli_wants_help`: `--help`/`-h` in a flag position, never a flag value.
fn help_in_flags(spec: &'static Spec, args: &[String], client: bool) -> bool {
    let mut skip = false;
    for arg in args {
        if skip {
            skip = false;
            continue;
        }
        match arg.as_str() {
            "--help" | "-h" => return true,
            "--plan-token" => skip = true,
            flag if flag.starts_with("--") && !flag.contains('=') => {
                skip = matches!(token_kind(spec, &flag[2..], client), Some('=' | '+'));
            }
            _ => {}
        }
    }
    false
}

/// Parse an argument vector (without the program name) as the daemon does:
/// `@name` inputs are not flags.
pub fn parse(argv: &[String]) -> Result<Invocation> {
    parse_with(argv, false)
}

/// The CLI's parse: additionally accepts `--name PATH` for every `@name`
/// input, available through `value(name)`.
pub fn parse_client(argv: &[String]) -> Result<Invocation> {
    parse_with(argv, true)
}

fn parse_with(argv: &[String], client: bool) -> Result<Invocation> {
    if argv.iter().any(|arg| arg.contains('\0')) {
        return Err(usage("Аргументы не могут содержать NUL."));
    }
    let json = argv.iter().any(|arg| arg == "--json");
    let mut help = false;
    let Some(noun_index) = next_positional(argv, 0, &mut help) else {
        if !help && argv.iter().any(|arg| arg == "--plan-token" || arg.starts_with("--plan-token=")) {
            return Err(usage("Флаг --plan-token используется только вместе с --yes."));
        }
        return Ok(Invocation::help(None, json));
    };
    let noun = argv[noun_index].as_str();
    if !known_noun(noun) {
        return Err(usage(format!("Неизвестная команда: {}. {}", printable(noun), hint(""))));
    }
    if noun == "help" {
        let topic = next_positional(argv, noun_index + 1, &mut help);
        if let Some(index) = topic {
            if next_positional(argv, index + 1, &mut help).is_some() {
                return Err(usage(format!("Лишний аргумент. {}", hint(""))));
            }
            let topic = argv[index].as_str();
            if topic == "help" || !known_noun(topic) {
                return Err(usage(format!("Неизвестная команда: {}. {}", printable(topic), hint(""))));
            }
            return Ok(Invocation::help(Some(topic.into()), json));
        }
        return Ok(Invocation::help(None, json));
    }
    if help && !bare(noun) {
        return Ok(Invocation::help(Some(noun.into()), json));
    }
    let (verb, verb_index) = if bare(noun) {
        ("", None)
    } else {
        let mut verb_help = false;
        match next_positional(argv, noun_index + 1, &mut verb_help) {
            _ if verb_help => return Ok(Invocation::help(Some(noun.into()), json)),
            Some(index) if argv[index] == "help" => return Ok(Invocation::help(Some(noun.into()), json)),
            Some(index) => (argv[index].as_str(), Some(index)),
            None => return Err(usage(format!("Не указано действие для «{noun}». {}", hint(noun)))),
        }
    };
    let Some(spec) = find(noun, verb) else {
        return Err(usage(format!("Неизвестная команда: {noun} {}. {}", printable(verb), hint(noun))));
    };
    let rest: Vec<String> = argv.iter().enumerate()
        .filter(|(index, _)| *index != noun_index && Some(*index) != verb_index)
        .map(|(_, arg)| arg.clone())
        .collect();
    if help || help_in_flags(spec, &rest, client) {
        return Ok(Invocation::help(Some(noun.into()), json));
    }
    parse_flags(spec, rest, json, client)
}

/// Unknown tokens are echoed only as a flag name: positional or `=value`
/// text could be something the user did not mean to print.
fn printable(token: &str) -> String {
    if token.starts_with("--") {
        token.split('=').next().unwrap_or(token).chars().filter(|c| !c.is_control()).take(64).collect()
    } else if token.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_') && token.len() <= 64 {
        token.into()
    } else {
        "«…»".into()
    }
}

fn command(spec: &'static Spec, client: bool) -> Command {
    let global = |id: &'static str| Arg::new(id).long(id).action(ArgAction::SetTrue).overrides_with(id);
    let mut command = Command::new("essence-rc")
        .no_binary_name(true)
        .disable_help_flag(true)
        .disable_version_flag(true)
        .arg(global("json"))
        .arg(global("yes"))
        .arg(global("secrets-stdin"))
        .arg(Arg::new("plan-token").long("plan-token").action(ArgAction::Set).num_args(1).allow_hyphen_values(true));
    for (name, kind) in tokens(spec, client) {
        let arg = match kind {
            '=' => Arg::new(name).long(name).action(ArgAction::Set).num_args(1).allow_hyphen_values(true),
            '+' => Arg::new(name).long(name).action(ArgAction::Append).num_args(1).allow_hyphen_values(true),
            _ => Arg::new(name).long(name).action(ArgAction::SetTrue).overrides_with(name),
        };
        command = command.arg(arg);
    }
    command
}

fn clap_error(spec: &Spec, error: &clap::Error) -> RcError {
    let noun = spec.noun;
    let argument = match error.get(ContextKind::InvalidArg) {
        Some(ContextValue::String(text)) => printable(text.split_whitespace().next().unwrap_or(text)),
        _ => String::new(),
    };
    let message = match error.kind() {
        ErrorKind::UnknownArgument if argument.starts_with("--") => format!("Неизвестный флаг: {argument}."),
        ErrorKind::UnknownArgument => "Лишний аргумент.".to_string(),
        ErrorKind::ArgumentConflict => format!("Флаг {argument} указан дважды."),
        ErrorKind::InvalidValue => format!("Флаг {argument} требует значение."),
        ErrorKind::TooManyValues | ErrorKind::NoEquals => format!("Флаг {argument} не принимает значение."),
        _ => "Неверные аргументы команды.".to_string(),
    };
    usage(format!("{message} {}", hint(noun)))
}

fn parse_flags(spec: &'static Spec, rest: Vec<String>, json: bool, client: bool) -> Result<Invocation> {
    // v1 has no end-of-options marker: `--` is never a valid flag.
    if rest.iter().any(|arg| arg == "--") {
        return Err(usage(format!("Лишний аргумент. {}", hint(spec.noun))));
    }
    let matches = command(spec, client).try_get_matches_from(&rest).map_err(|error| clap_error(spec, &error))?;
    let mut values = BTreeMap::new();
    let mut flags = BTreeSet::new();
    for (name, kind) in tokens(spec, client) {
        if kind == 'b' {
            if matches.get_flag(name) {
                flags.insert(name);
            }
        } else if let Some(found) = matches.get_many::<String>(name) {
            values.insert(name, found.cloned().collect::<Vec<_>>());
        }
    }
    let plan_token = matches.get_one::<String>("plan-token").cloned();
    let checked = values.iter().map(|(name, list)| (*name, list.as_slice()))
        .chain(plan_token.as_ref().map(|token| ("plan-token", std::slice::from_ref(token))));
    for (name, list) in checked {
        if list.iter().any(|value| value.contains('\n')) {
            return Err(usage(format!("Значение флага --{name} не может содержать перевод строки.")));
        }
    }
    let yes = matches.get_flag("yes");
    if plan_token.is_some() && !yes {
        return Err(usage("Флаг --plan-token используется только вместе с --yes."));
    }
    Ok(Invocation {
        noun: spec.noun.into(),
        verb: spec.verb.into(),
        json,
        yes,
        plan_token,
        secrets_stdin: matches.get_flag("secrets-stdin"),
        help: false,
        help_noun: None,
        values,
        flags,
        secrets: spec.secrets,
        inputs: inputs(spec).collect(),
        session: spec.flags & NOSESSION == 0,
        tty: spec.flags & TTY != 0,
        local: spec.flags & LOCAL != 0,
        client: spec.flags & CLIENT != 0,
        spec: Some(spec),
        confirmation: rest.into_iter().filter(|arg| arg != "--secrets-stdin").collect(),
    })
}

fn help_lines(noun: Option<&str>) -> impl Iterator<Item = &'static (&'static str, &'static str)> {
    HELP.iter()
        .filter(move |(section, _)| noun.is_none_or(|noun| *section == noun))
        .flat_map(|(_, lines)| lines.iter())
}

/// `{"commands":[{"usage","description"}]}` for the whole catalog or one noun.
pub fn help(noun: Option<&str>) -> Value {
    let commands: Vec<Value> = help_lines(noun)
        .map(|(usage, description)| json!({"usage": usage, "description": description}))
        .collect();
    json!({"commands": commands})
}

/// Human-readable Russian help.
pub fn render_help(noun: Option<&str>) -> String {
    let mut text = String::from("Essence Remote Control — управление нодами\n\nИспользование: essence-rc <сущность> <действие> [флаги]\n\nКоманды:\n");
    for (usage, description) in help_lines(noun) {
        text.push_str("  ");
        text.push_str(usage);
        text.push_str("\n      ");
        text.push_str(description);
        text.push('\n');
    }
    text
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> Vec<String> {
        list.iter().map(|arg| arg.to_string()).collect()
    }

    fn code(list: &[&str]) -> &'static str {
        parse(&args(list)).err().map_or("ok", |error| error.code)
    }

    #[test]
    fn every_catalog_command_has_help_and_parses() {
        for spec in CATALOG {
            let mut argv = vec![spec.noun];
            if !spec.verb.is_empty() {
                argv.push(spec.verb);
            }
            let invocation = parse(&args(&argv)).unwrap_or_else(|error| panic!("{argv:?}: {}", error.message));
            assert_eq!((invocation.noun.as_str(), invocation.verb.as_str()), (spec.noun, spec.verb));
            let prefix = if spec.verb.is_empty() { spec.noun.to_string() } else { format!("{} {}", spec.noun, spec.verb) };
            assert!(help_lines(Some(spec.noun)).any(|(usage, _)| usage.starts_with(&prefix)), "{argv:?}");
        }
        assert!(!help_lines(None).any(|(usage, _)| usage.starts_with("sub ")));
    }

    #[test]
    fn values_repeats_and_globals_anywhere() {
        let invocation = parse(&args(&[
            "--json", "client", "--yes", "delete", "--name", "a", "--name=b", "--plan-token", "-x",
        ])).unwrap();
        assert_eq!((invocation.noun.as_str(), invocation.verb.as_str()), ("client", "delete"));
        assert!(invocation.json && invocation.yes);
        assert_eq!(invocation.values("name"), ["a", "b"]);
        assert_eq!(invocation.plan_token.as_deref(), Some("-x"));
        assert_eq!(invocation.confirmation_args(), args(&["--json", "--yes", "--name", "a", "--name=b", "--plan-token", "-x"]));
        let tag = parse(&args(&["node", "tag", "--name", "n", "--tag", ""])).unwrap();
        assert_eq!(tag.value("tag"), Some(""));
        let generate = parse(&args(&["generate", "--all", "--secrets-stdin"])).unwrap();
        assert!(generate.has("all") && generate.secrets_stdin && generate.verb.is_empty());
        assert_eq!(generate.confirmation_args(), args(&["--all"]));
    }

    #[test]
    fn grammar_violations_are_usage() {
        for argv in [
            &["bogus"][..], &["node"], &["node", "frobnicate"], &["node", "list", "--bogus"],
            &["node", "list", "extra"], &["node", "show", "--name", "a", "--name", "b"],
            &["node", "show", "--name", "a\nb"], &["node", "show", "--name"], &["status", "--yes=1"],
            &["status", "--plan-token=x"], &["--plan-token", "x", "status"], &["--plan-token", "x"],
            &["node", "password", "--name", "n", "--password", "secret"], &["status", "--"],
            &["help", "bogus"], &["help", "node", "extra"], &["", "status"], &["sub", "list"],
            &["status", "a\0b"],
        ] {
            assert_eq!(code(argv), "usage", "{argv:?}");
        }
    }

    #[test]
    fn help_forms_and_session_requirements() {
        for (argv, noun) in [
            (&[][..], None), (&["--json"], None), (&["-h"], None), (&["help"], None),
            (&["help", "node"], Some("node")), (&["node", "--help"], Some("node")),
            (&["node", "help"], Some("node")), (&["node", "show", "-h"], Some("node")),
            (&["status", "--help"], Some("status")),
        ] {
            let invocation = parse(&args(argv)).unwrap();
            assert!(invocation.help, "{argv:?}");
            assert_eq!(invocation.help_noun(), noun, "{argv:?}");
        }
        // A flag value is never a help request (v1 `_cli_wants_help`).
        let value = parse(&args(&["node", "show", "--name", "-h"])).unwrap();
        assert!(!value.help);
        assert_eq!(value.value("name"), Some("-h"));
        assert!(!parse(&args(&["session", "open"])).unwrap().requires_session());
        assert!(parse(&args(&["self", "password-set"])).unwrap().requires_session());
        assert!(parse(&args(&["node", "shell", "--name", "n"])).unwrap().requires_tty());
        assert_eq!(parse(&args(&["self", "password-set"])).unwrap().allowed_secrets(), ["password", "current-password"]);
        assert_eq!(help(Some("generate"))["commands"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn client_rows_parse_on_the_client_and_are_marked() {
        let rows: Vec<&Spec> = CATALOG.iter().filter(|spec| spec.flags & CLIENT != 0).collect();
        assert_eq!(rows.iter().map(|spec| (spec.noun, spec.verb)).collect::<Vec<_>>(),
            [("daemon", "run"), ("daemon", "start"), ("web", "run"), ("web", "open"), ("web", "install-service"),
                ("web", "uninstall-service"), ("template", "export")]);
        for argv in [
            &["daemon", "run"][..], &["daemon", "start", "--json"],
            &["daemon", "run", "--web", "--bind", "0.0.0.0", "--port", "0", "--no-tls"],
            &["web", "run", "--port", "8443", "--tls-cert", "c.pem", "--tls-key", "k.pem", "--no-open"],
            &["web", "open", "--no-open"],
            &["daemon", "run", "--data-dir", "/srv/essence", "--web"],
            &["web", "install-service", "--bind", "0.0.0.0", "--port", "8443"],
            &["web", "uninstall-service"],
            &["template", "export", "--name", "t", "--output", "/tmp/out.yaml", "--yes"],
        ] {
            let invocation = parse_client(&args(argv)).unwrap_or_else(|error| panic!("{argv:?}: {}", error.message));
            assert!(invocation.client_side() && !invocation.local_only(), "{argv:?}");
            // The daemon parses the same grammar and refuses it in dispatch.
            assert!(parse(&args(argv)).unwrap().client_side(), "{argv:?}");
        }
        let export = parse_client(&args(&["template", "export", "--name", "t", "--output", "o"])).unwrap();
        assert_eq!((export.value("name"), export.value("output")), (Some("t"), Some("o")));
        for argv in [&["daemon", "run", "--bogus"][..], &["daemon", "start", "extra"], &["template", "export", "--file", "x"]] {
            assert_eq!(parse_client(&args(argv)).err().map(|error| error.code), Some("usage"), "{argv:?}");
        }
        let stop = parse(&args(&["daemon", "stop"])).unwrap();
        assert!(stop.local_only() && !stop.client_side() && !stop.requires_session());
        let status = parse(&args(&["daemon", "status"])).unwrap();
        assert!(!status.local_only() && !status.client_side() && !status.requires_session());
        for verb in ["start", "stop", "link"] {
            let web = parse(&args(&["web", verb])).unwrap();
            assert!(web.local_only() && !web.client_side() && !web.requires_session(), "{verb}");
        }
        let web = parse(&args(&["web", "status"])).unwrap();
        assert!(!web.local_only() && !web.requires_session());
        assert_eq!(parse(&args(&["session", "open"])).unwrap().allowed_secrets(), ["vault-password", "script-password", "access-token"]);
        assert!(parse(&args(&["client", "config", "--name", "c"])).unwrap().requires_session());
    }

    #[test]
    fn inputs_are_client_flags_and_never_reach_the_daemon() {
        for argv in [
            &["template", "import", "--name", "t", "--file", "in.yaml"][..],
            &["source", "github-import-recovery-key", "--file=key.txt"],
        ] {
            assert_eq!(code(argv), "usage", "the daemon does not know --file: {argv:?}");
            let invocation = parse_client(&args(argv)).unwrap();
            assert_eq!(invocation.inputs(), ["file"]);
            assert!(invocation.value("file").is_some());
        }
        let bare = parse(&args(&["template", "import", "--name", "t"])).unwrap();
        assert_eq!((bare.inputs(), bare.value("file")), (&["file"][..], None));
        assert!(parse(&args(&["template", "show", "--name", "t"])).unwrap().inputs().is_empty());
        assert!(parse(&args(&["--json"])).unwrap().inputs().is_empty());
        // `@file?`: optional input — the client reads it only when given.
        let check = parse_client(&args(&["template", "check", "--name", "t"])).unwrap();
        assert_eq!((check.inputs(), check.value("file"), check.input_optional("file")), (&["file"][..], None, true));
        assert!(!bare.input_optional("file"));
        assert_eq!(code(&["template", "check", "--file", "t.yaml"]), "usage", "the daemon does not know --file");
        let file = parse_client(&args(&["template", "check", "--file", "t.yaml"])).unwrap();
        assert_eq!(file.daemon_argv(&args(&["template", "check", "--file", "t.yaml"])), args(&["template", "check"]));
        // Repeated input flags follow the value-flag rule.
        assert_eq!(parse_client(&args(&["template", "import", "--file", "a", "--file", "b"])).err().map(|e| e.code), Some("usage"));

        for (argv, sent) in [
            (&["--json", "template", "import", "--name", "t", "--file", "in.yaml", "--secrets-stdin", "--yes"][..],
                &["--json", "template", "import", "--name", "t", "--yes"][..]),
            (&["template", "import", "--file=in.yaml", "--plan-token", "--file", "--yes", "--name", "--file"],
                &["template", "import", "--plan-token", "--file", "--yes", "--name", "--file"]),
            (&["source", "github-import-recovery-key", "--file", "k", "--json"], &["source", "github-import-recovery-key", "--json"]),
            (&["--secrets-stdin", "help", "template"], &["help", "template"]),
        ] {
            let invocation = parse_client(&args(argv)).unwrap_or_else(|error| panic!("{argv:?}: {}", error.message));
            let daemon = invocation.daemon_argv(&args(argv));
            assert_eq!(daemon, args(sent), "{argv:?}");
            parse(&daemon).unwrap_or_else(|error| panic!("{daemon:?}: {}", error.message));
        }
    }
}
