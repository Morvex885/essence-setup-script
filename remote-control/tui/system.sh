#!/bin/bash
# ─── Экраны TUI: запуск, сводка, источник конфигурации, настройки ────────────
# Данные — только результаты команд ядра через tui_call (tui_q/tui_eq).
# Каждый экран — цикл полного кадра: данные → кадр → ввод. 0/EOF → rc 0.
# Пароли идут только через tui_secret и очищаются на любом исходе.

# ─── Помощники ───────────────────────────────────────────────────────────────

# _tui_read_secret PROMPT → TUI_ANSWER (скрытый ввод); rc 1 — EOF.
_tui_read_secret() {
    local s
    IFS= read -rsp "  $1: " s || { echo ""; return 1; }
    echo ""
    TUI_ANSWER="${s%$'\r'}"
}

# _tui_new_password NAME — новый пароль дважды в секрет NAME. rc 1 — отмена,
# пустой ввод или несовпадение (с предупреждением).
_tui_new_password() {
    local name="$1" first
    _tui_read_secret "Новый пароль" || return 1
    first="$TUI_ANSWER"
    TUI_ANSWER=""
    if [[ -z "$first" ]]; then
        warn "Пароль не может быть пустым."
        return 1
    fi
    _tui_read_secret "Повторите пароль" || { first=""; return 1; }
    if [[ "$TUI_ANSWER" != "$first" ]]; then
        TUI_ANSWER=""
        first=""
        warn "Пароли не совпадают."
        return 1
    fi
    TUI_ANSWER=""
    tui_secret "$name" "$first"
    first=""
}

# _tui_version V → V с префиксом v ровно один раз.
_tui_version() { printf 'v%s' "${1#v}"; }

# _tui_flag_set VALUE FLAG… — флаг решения в TUI_FLAGS без повторов (FLAG — 1–2 слова).
_tui_flag_set() {
    local i
    for ((i = 0; i < ${#TUI_FLAGS[@]}; i++)); do
        if [[ "${TUI_FLAGS[$i]}" == "$1" ]]; then
            if [[ $# -eq 2 ]]; then TUI_FLAGS[$((i + 1))]="$2"; fi
            return 0
        fi
    done
    TUI_FLAGS+=("$@")
}

# _tui_provision_decision — ответ на key_provisioning_required: --provision-keys.
_tui_provision_decision() {
    review_frame "Переносимый SSH-ключ" "Ноды: $(tui_eq '(.nodes // []) | join(", ")')"
    if confirm_yn "Создать переносимый SSH-ключ для этих нод?" N; then
        _tui_flag_set --provision-keys yes
    else
        _tui_flag_set --provision-keys no
    fi
}

# ─── Запуск ──────────────────────────────────────────────────────────────────

tui_startup() {
    tui_call session status || return 1
    if [[ "$(tui_q '.configured')" != true ]]; then
        _tui_first_run || return $?
    fi
    _tui_session_open
}

# rc 0 — конфигурация создана; 2 — «Выход» по выбору пользователя; 1 — EOF/сбой.
_tui_first_run() {
    while true; do
        _tui_head "Первый запуск"
        menu_item 1 "Локальная конфигурация" GREEN
        menu_item 2 "Конфигурация в GitHub" GREEN
        menu_item 0 "Выход" NC
        box_bot
        _tui_prompt "Выберите источник" || return 1
        case "$TUI_CHOICE" in
            1) tui_call source init-local && return 0 ;;
            2) tui_github_wizard connect && return 0 ;;
            0) return 2 ;;
            *) warn "Неверный выбор." ;;
        esac
    done
}

# Цикл session open с накопленными секретами; коды — по плану запуска.
_tui_session_open() {
    local vault_tries=0 script_tries=0
    local -a remember=()
    while true; do
        if tui_call session open "${remember[@]}"; then
            tui_secrets_clear
            return 0
        fi
        case "$TUI_CODE" in
            vault_password_required|vault_password_invalid)
                if (( vault_tries >= 3 )); then
                    vault_tries=0
                    tui_secrets_clear
                    startup_recovery_menu "Доступ к конфигурации GitHub" true || return 1
                    continue
                fi
                vault_tries=$((vault_tries + 1))
                _tui_read_secret "Пароль доступа к конфигурации GitHub" || { tui_secrets_clear; return 1; }
                tui_secret vault-password "$TUI_ANSWER"
                TUI_ANSWER=""
                remember=()
                confirm_yn "Сохранить ключ расшифровки на этом устройстве?" N && remember=(--remember-key)
                ;;
            auth_required|auth_failed)
                if (( script_tries >= 3 )); then
                    script_tries=0
                    tui_secrets_clear
                    startup_recovery_menu "Восстановление доступа" true || return 1
                    continue
                fi
                script_tries=$((script_tries + 1))
                _tui_read_secret "Введите пароль" || { tui_secrets_clear; return 1; }
                tui_secret script-password "$TUI_ANSWER"
                TUI_ANSWER=""
                ;;
            github_format_outdated|github_format_newer|github_format_invalid)
                _tui_github_recovery || { tui_secrets_clear; return 1; }
                ;;
            locked)
                tui_secrets_clear
                startup_recovery_menu "Конфигурация занята" true || return 1
                ;;
            *)
                tui_secrets_clear
                startup_recovery_menu "Не удалось открыть конфигурацию" true || return 1
                ;;
        esac
    done
}

# Экран «Конфигурация GitHub требует восстановления» по ошибке session open.
# rc 0 — конфигурация опубликована, сессию можно открыть снова.
_tui_github_recovery() {
    local code="$TUI_CODE" message version required
    message=$(tui_eq '.message')
    version=$(tui_eq '.version // empty')
    required=$(tui_eq '.required // empty')
    while true; do
        _tui_head "Конфигурация GitHub требует восстановления"
        box_line " $message" " ${YELLOW}${message}${NC}"
        [[ -z "$version" ]] || box_line " Формат конфигурации: v${version}"
        [[ -z "$required" ]] || box_line " Требуется remote-control: $(_tui_version "$required")"
        box_mid
        [[ "$code" != github_format_outdated ]] || menu_item 1 "Преобразовать конфигурацию" YELLOW
        [[ "$code" == github_format_newer ]] || menu_item 2 "Заменить конфигурацией с этого устройства" RED
        menu_item 0 "Выход" NC
        box_bot
        _tui_prompt || return 1
        case "$TUI_CHOICE" in
            1)
                if [[ "$code" != github_format_outdated ]]; then
                    warn "Неверный выбор."
                    continue
                fi
                _tui_recovery_run "Преобразование конфигурации GitHub" \
                    "Преобразовать и опубликовать конфигурацию?" source github-migrate-format && return 0
                ;;
            2)
                if [[ "$code" == github_format_newer ]]; then
                    warn "Неверный выбор."
                    continue
                fi
                _tui_recovery_run "Замена конфигурации GitHub" \
                    "Заменить конфигурацию в GitHub?" source github-replace-with-local && return 0
                ;;
            0) return 1 ;;
            *) warn "Неверный выбор." ;;
        esac
    done
}

# _tui_recovery_run TITLE QUESTION ARGV… — команда восстановления с подтверждением:
# свой пароль запуска (auth_*) и решение о переносимых ключах.
_tui_recovery_run() {
    local title="$1" question="$2" tries=0
    shift 2
    TUI_FLAGS=()
    while true; do
        tui_run_confirmed "$title" "$question" "$@" "${TUI_FLAGS[@]}" && return 0
        case "$TUI_CODE" in
            auth_required|auth_failed)
                (( tries < 3 )) || return 1
                tries=$((tries + 1))
                _tui_read_secret "Введите пароль" || return 1
                tui_secret script-password "$TUI_ANSWER"
                TUI_ANSWER=""
                ;;
            key_provisioning_required) _tui_provision_decision ;;
            *) return 1 ;;
        esac
    done
}

# ─── Сводка ──────────────────────────────────────────────────────────────────

tui_dashboard() {
    local version latest type repo sync line plain missing host
    while true; do
        if ! tui_call status; then
            startup_recovery_menu "Не удалось получить сводку" true || return 0
            continue
        fi
        version=$(tui_q '.version')
        latest=$(tui_q '.update.latest // empty')
        type=$(tui_q '.source.type')
        repo=$(tui_q '.source.repo // empty')
        sync=$(tui_q '.source.sync // empty')
        missing=$(tui_q '.password_missing | join(", ")')
        host=$(tui_q '.subscription_host // empty')
        echo ""
        box_top
        box_center "Remote Control $(_tui_version "$version")"
        if [[ "$(tui_q '.update.available')" == true ]]; then
            plain="Доступно обновление $(_tui_version "$latest") — раздел o"
            box_line " $plain" " ${YELLOW}${plain}${NC}"
        fi
        box_mid
        if [[ "$type" == github ]]; then
            case "$sync" in
                clean) plain="синхронизировано"; line="${GREEN}синхронизировано${NC}" ;;
                pending) plain="ожидает отправки"; line="${YELLOW}ожидает отправки${NC}" ;;
                *) plain="нет связи"; line="${YELLOW}нет связи${NC}" ;;
            esac
            box_line " Источник: GitHub $repo • $plain" " Источник: GitHub $repo • $line"
        else
            box_line " Источник: локальная"
        fi
        box_line " Ноды: $(tui_q '.counts.nodes')  Клиенты: $(tui_q '.counts.clients')  Группы: $(tui_q '.counts.groups')"
        if [[ -n "$host" ]]; then
            box_line " Хост подписок: $host"
        else
            box_line " Хост подписок не задан" " ${DIM}Хост подписок не задан${NC}"
        fi
        [[ -z "$missing" ]] || box_line " Нет пароля SSH: $missing" " ${YELLOW}Нет пароля SSH: ${missing}${NC}"
        if [[ "$(tui_q '.ssh_setup_pending')" == true ]]; then
            plain="Отложена SSH-настройка нод — раздел n → h"
            box_line " $plain" " ${YELLOW}${plain}${NC}"
        fi
        box_mid
        menu_item n "Ноды" CYAN
        menu_item c "Клиенты" CYAN
        menu_item g "Группы" CYAN
        menu_item m "Шаблоны" CYAN
        menu_item p "Подключения" CYAN
        menu_item f "Генерация конфигов" CYAN
        menu_item s "Подписки" CYAN
        menu_item a "AmneziaWG" CYAN
        menu_item t "Telegram Proxy" CYAN
        box_mid
        menu_item i "Источник конфигурации" CYAN
        menu_item o "Настройки" CYAN
        menu_item 0 "Выход" NC
        box_bot
        _tui_prompt || return 0
        case "$TUI_CHOICE" in
            n|N) tui_nodes ;;
            c|C) tui_clients ;;
            g|G) tui_groups ;;
            m|M) tui_templates ;;
            p|P) tui_connections ;;
            f|F) tui_generate ;;
            s|S) tui_subscriptions ;;
            a|A) tui_awg ;;
            t|T) tui_telegram ;;
            i|I) tui_source ;;
            o|O) tui_settings ;;
            0) return 0 ;;
            *) warn "Неверный выбор." ;;
        esac
    done
}

# ─── Источник конфигурации ───────────────────────────────────────────────────

tui_source() {
    local type storage url
    while true; do
        tui_call source status || return 0
        type=$(tui_q '.type')
        storage=$(tui_q '.storage // empty')
        _tui_head "Источник конфигурации"
        if [[ "$type" == github ]]; then
            box_line " GitHub: $(tui_q '.repo')"
            box_line " Ветка: $(tui_q '.branch')"
            if [[ "$storage" == age ]]; then
                box_line " Хранение: зашифровано"
            else
                box_line " Хранение: без шифрования"
            fi
            case "$(tui_q '.sync')" in
                clean) box_line " Синхронизация: синхронизировано" " Синхронизация: ${GREEN}синхронизировано${NC}" ;;
                pending) box_line " Синхронизация: ожидает отправки" " Синхронизация: ${YELLOW}ожидает отправки${NC}" ;;
                *) box_line " Синхронизация: нет связи" " Синхронизация: ${YELLOW}нет связи${NC}" ;;
            esac
        else
            box_line " Источник: локальная"
        fi
        box_mid
        if [[ "$type" == github ]]; then
            menu_item f "Загрузить из GitHub" YELLOW
            menu_item p "Отправить в GitHub" YELLOW
            menu_item c "Сменить аккаунт" YELLOW
            if [[ "$storage" == age ]]; then
                menu_item r "Сменить пароль доступа" YELLOW
                menu_item v "Новый ключ шифрования" RED
                menu_item k "Импортировать ключ восстановления" YELLOW
            fi
            menu_item e "Работать локально без синхронизации" YELLOW
            menu_item l "Заменить GitHub локальной конфигурацией" RED
            menu_item d "Удалить репозиторий" RED
        else
            menu_item g "Подключить GitHub" GREEN
        fi
        menu_item 0 "Назад" NC
        box_bot
        _tui_prompt || return 0
        if [[ "$type" != github ]]; then
            case "$TUI_CHOICE" in
                g|G) tui_github_wizard connect || true ;;
                0) return 0 ;;
                *) warn "Неверный выбор." ;;
            esac
            continue
        fi
        case "$TUI_CHOICE" in
            f|F) tui_call source github-fetch || true ;;
            p|P) tui_call source github-push || true ;;
            c|C) tui_github_wizard change || true ;;
            r|R)
                if [[ "$storage" != age ]]; then
                    warn "Неверный выбор."
                    continue
                fi
                if _tui_read_secret "Текущий пароль доступа"; then
                    tui_secret vault-password "$TUI_ANSWER"
                    TUI_ANSWER=""
                    _tui_new_password new-vault-password && tui_call source github-rewrap-password
                fi
                tui_secrets_clear
                ;;
            v|V)
                if [[ "$storage" != age ]]; then
                    warn "Неверный выбор."
                    continue
                fi
                _tui_new_password new-vault-password &&
                    tui_run_confirmed "Новый ключ шифрования" "Создать новый ключ?" source github-rotate-key
                tui_secrets_clear
                ;;
            k|K)
                if [[ "$storage" != age ]]; then
                    warn "Неверный выбор."
                    continue
                fi
                _tui_ask "Путь к файлу" || return 0
                [[ -z "$TUI_ANSWER" ]] || tui_call source github-import-recovery-key --file "$TUI_ANSWER" || true
                ;;
            e|E) tui_call source github-switch-local || true ;;
            l|L)
                _tui_recovery_run "Замена конфигурации GitHub" \
                    "Заменить конфигурацию в GitHub?" source github-replace-with-local || true
                tui_secrets_clear
                ;;
            d|D)
                if ! tui_run_confirmed "Удаление репозитория" "Удалить репозиторий?" source github-delete-repo; then
                    url=$(tui_eq '.settings_url // empty')
                    [[ -z "$url" ]] || info "Удалите репозиторий вручную: $(hyperlink "$url")"
                fi
                ;;
            0) return 0 ;;
            *) warn "Неверный выбор." ;;
        esac
    done
}

# ─── Мастер GitHub ───────────────────────────────────────────────────────────

# tui_github_wizard connect|change — аккаунт, затем повтор команды с решениями
# по кодам ответа. Отказ или EOF на любом шаге → «Отменено.», rc 1.
tui_github_wizard() {
    local mode="$1" verb=github-connect title="Подключение GitHub" login global rc=0
    local -a accounts labels
    [[ "$mode" != change ]] || { verb=github-change-account; title="Смена аккаунта GitHub"; }
    tui_call source github-accounts || return 1
    _tui_list_into '.accounts[]'; accounts=("${TUI_LIST[@]}")
    global=$(tui_q '.global_login // empty')
    if [[ -n "$global" ]] && ! printf '%s\n' "${accounts[@]}" | grep -qxF -- "$global"; then
        accounts+=("$global")
    fi
    labels=("${accounts[@]}" "Указать другой логин")
    if ! menu_select "Аккаунт GitHub" "Выберите аккаунт" "${labels[@]}"; then
        info "Отменено."
        return 1
    fi
    if (( MENU_SELECT_INDEX > ${#accounts[@]} )); then
        if ! _tui_ask "Логин GitHub" || [[ -z "$TUI_ANSWER" ]]; then
            info "Отменено."
            return 1
        fi
        login="$TUI_ANSWER"
    else
        login="${accounts[$((MENU_SELECT_INDEX - 1))]}"
    fi
    TUI_FLAGS=()
    _tui_wizard_loop "$verb" "$title" "$login" || rc=$?
    tui_secrets_clear
    (( rc == 0 )) || return "$rc"
    if [[ "$mode" == change ]] && [[ -n "$(tui_q '.old_repo_settings_url // empty')" ]]; then
        info "Прежний репозиторий можно удалить вручную: $(hyperlink "$(tui_q '.old_repo_settings_url')")"
    fi
}

# Повтор команды мастера; каждое решение добавляет флаг или секрет. Опасные
# решения (приватность, замена конфигурации или файлов репозитория) не
# спрашиваются отдельно: их подтверждает план команды в tui_run_confirmed.
_tui_wizard_loop() {
    local verb="$1" title="$2" login="$3" vault_tries=0 repo choice i
    local -a choices labels
    while true; do
        tui_run_confirmed "$title" "Выполнить?" source "$verb" --login "$login" "${TUI_FLAGS[@]}" && return 0
        case "$TUI_CODE" in
            github_auth_required)
                confirm_yn "Войти в GitHub через браузер сейчас?" Y || { info "Отменено."; return 1; }
                tui_call source github-login --login "$login" || return 1
                ;;
            repo_create_required)
                repo=$(tui_eq '.repo')
                confirm_yn "Создать приватный репозиторий $repo?" N || { info "Отменено."; return 1; }
                _tui_flag_set --create-repo
                ;;
            repo_private_required) _tui_flag_set --make-private ;;
            storage_mode_required)
                if ! menu_select "Хранение конфигурации GitHub" "Выберите способ хранения" \
                    "Зашифровать паролем (age)" "Без шифрования"; then
                    info "Отменено."
                    return 1
                fi
                if [[ "$MENU_SELECT_INDEX" == 1 ]]; then
                    _tui_flag_set --storage age
                else
                    _tui_flag_set --storage none
                fi
                ;;
            new_vault_password_required)
                _tui_new_password new-vault-password || { info "Отменено."; return 1; }
                ;;
            existing_config_action_required)
                choices=()
                while IFS= read -r choice; do
                    choices+=("$choice")
                done < <(tui_eq '.choices[]?')
                labels=()
                for choice in "${choices[@]}"; do
                    case "$choice" in
                        remote) labels+=("Использовать конфигурацию из GitHub ($(tui_eq '.remote_counts | if . == null then "состав неизвестен" else "ноды \(.nodes), клиенты \(.clients)" end'))") ;;
                        local) labels+=("Заменить её конфигурацией с этого устройства") ;;
                        migrate) labels+=("Преобразовать конфигурацию из GitHub") ;;
                        *) labels+=("$choice") ;;
                    esac
                done
                if ! menu_select "Конфигурация в GitHub" "Выберите действие" "${labels[@]}"; then
                    info "Отменено."
                    return 1
                fi
                choice="${choices[$((MENU_SELECT_INDEX - 1))]}"
                _tui_flag_set --existing "$choice"
                ;;
            vault_password_required|vault_password_invalid)
                (( vault_tries < 3 )) || return 1
                vault_tries=$((vault_tries + 1))
                _tui_read_secret "Пароль доступа к конфигурации GitHub" || { info "Отменено."; return 1; }
                tui_secret vault-password "$TUI_ANSWER"
                TUI_ANSWER=""
                if [[ "$verb" == github-connect ]] &&
                   confirm_yn "Сохранить ключ расшифровки на этом устройстве?" N; then
                    _tui_flag_set --remember-key
                fi
                ;;
            key_provisioning_required) _tui_provision_decision ;;
            cache_skip_required)
                confirm_yn "Продолжить смену аккаунта без локального кэша?" N || { info "Отменено."; return 1; }
                _tui_flag_set --without-cache
                ;;
            target_replace_required) _tui_flag_set --replace-target ;;
            *) return 1 ;;
        esac
    done
}

# ─── Настройки ───────────────────────────────────────────────────────────────

tui_settings() {
    local checked available password_set version_data=""
    tui_call self version && version_data="$TUI_DATA"
    while true; do
        checked=false available=false
        if [[ -n "$version_data" ]]; then
            TUI_DATA="$version_data"
            checked=$(tui_q '.checked')
            available=$(tui_q '.update_available')
            _tui_head "Настройки"
            box_line " Версия: $(_tui_version "$(tui_q '.current')")"
            if [[ "$checked" == true ]]; then
                box_line " Последняя: $(_tui_version "$(tui_q '.latest')")"
            else
                box_line " Не удалось проверить обновления" " ${DIM}Не удалось проверить обновления${NC}"
            fi
        else
            _tui_head "Настройки"
        fi
        password_set=false
        tui_call status && password_set=$(tui_q '.script_password')
        if [[ "$password_set" == true ]]; then
            box_line " Пароль запуска: установлен"
        else
            box_line " Пароль запуска: не установлен"
        fi
        box_mid
        [[ "$available" != true ]] || menu_item u "Обновить remote-control" YELLOW
        if [[ "$password_set" == true ]]; then
            menu_item l "Сменить пароль запуска" YELLOW
            menu_item r "Убрать пароль запуска" RED
        else
            menu_item l "Установить пароль запуска" YELLOW
        fi
        menu_item x "Удалить remote-control" RED
        menu_item 0 "Назад" NC
        box_bot
        _tui_prompt || return 0
        case "$TUI_CHOICE" in
            u|U)
                if [[ "$available" != true ]]; then
                    warn "Неверный выбор."
                    continue
                fi
                if tui_run_confirmed "Обновление" "Обновить remote-control?" self update; then
                    info "Запустите remote-control-essence заново."
                    exit 0
                fi
                ;;
            l|L)
                if [[ "$password_set" == true ]]; then
                    if _tui_read_secret "Текущий пароль запуска"; then
                        tui_secret current-password "$TUI_ANSWER"
                        TUI_ANSWER=""
                        _tui_new_password password && tui_call self password-set
                    fi
                else
                    _tui_new_password password && tui_call self password-set
                fi
                tui_secrets_clear
                ;;
            r|R)
                if [[ "$password_set" != true ]]; then
                    warn "Неверный выбор."
                    continue
                fi
                if _tui_read_secret "Текущий пароль запуска"; then
                    tui_secret current-password "$TUI_ANSWER"
                    TUI_ANSWER=""
                    tui_run_confirmed "Пароль запуска" "Убрать пароль запуска?" self password-remove
                fi
                tui_secrets_clear
                ;;
            x|X)
                menu_select "Удаление remote-control" "Выберите объём" \
                    "Сохранить локальные данные" "Удалить локальные данные" || continue
                if [[ "$MENU_SELECT_INDEX" == 2 ]]; then
                    tui_run_confirmed "Удаление remote-control" "Удалить remote-control в выбранном объёме?" \
                        self uninstall --remove-data && exit 0
                else
                    tui_run_confirmed "Удаление remote-control" "Удалить remote-control в выбранном объёме?" \
                        self uninstall && exit 0
                fi
                ;;
            0) return 0 ;;
            *) warn "Неверный выбор." ;;
        esac
    done
}
