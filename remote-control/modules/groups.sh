#!/bin/bash
# ─── Группы клиентов ────────────────────────────────────────────────────────

_group_client_count() {
    jq_r --arg g "$1" '[.clients[] | select(.group==$g)] | length'
}

_group_nodes_csv() {
    jq_r --arg g "$1" '
        [.connections[] | select(any(.groups[]?; .name == $g)) | .node]
        | unique | join(",")'
}

_group_exists() {
    [[ -n "${1:-}" && "$(jq_r --arg g "$1" 'any(.groups[]; .name==$g)')" == true ]]
}

# core_group_add NAME — имя приводится к верхнему регистру; допустимые символы —
# как у клиента (имя группы становится каталогом в $GENERATED_DIR).
# Результат: CORE_GROUP_ADD_NAME.
core_group_add() {
    local name
    CORE_GROUP_ADD_NAME=""
    name=$(printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]')
    [[ -n "$name" ]] || { rc_fail invalid "Название группы не указано."; return 1; }
    if [[ ! "$name" =~ ^[A-Z0-9._-]+$ || "$name" =~ ^\.+$ ]]; then
        rc_fail invalid "Название группы может содержать только буквы, цифры, точку, - и _"
        return 1
    fi
    if _group_exists "$name"; then
        rc_fail conflict "Группа '$name' уже существует."
        return 1
    fi

    jq_w --arg g "$name" '.groups += [{name: $g, template: "default.yaml"}]' || return 1
    CORE_GROUP_ADD_NAME="$name"
    success "Группа $name добавлена"
}

_group_delete_check() {
    local name="${1:-}" count
    _group_exists "$name" || { rc_fail not_found "Группа '$name' не найдена."; return 1; }
    count=$(_group_client_count "$name")
    if [[ "${count:-0}" -gt 0 ]]; then
        rc_fail conflict "В группе '$name' есть клиенты. Сначала удалите их."
        return 1
    fi
}

core_group_delete_plan() {
    CORE_PLAN_LINES=()
    _group_delete_check "${1:-}" || return 1
    CORE_PLAN_LINES=("Группа: $1" "Назначения подключений этой группе будут удалены.")
}

core_group_delete() {
    local target="${1:-}"
    _group_delete_check "$target" || return 1
    jq_w --arg g "$target" '
        .groups |= map(select(.name != $g)) |
        .connections |= map(.groups |= [.[] | select(.name!=$g)]) |
        .connections |= [.[] | select(.groups | length > 0)]' || return 1
    success "Группа $target удалена"
}

# core_group_set_template GROUP TEMPLATE — суффикс .yaml необязателен.
# Результат: CORE_GROUP_TEMPLATE (имя с .yaml).
core_group_set_template() {
    local group="${1:-}" template="${2:-}"
    CORE_GROUP_TEMPLATE=""
    _group_exists "$group" || { rc_fail not_found "Группа '$group' не найдена."; return 1; }
    [[ -n "$template" && "$template" != *.yaml ]] && template="${template}.yaml"
    if [[ -z "$template" ]] || ! _list_templates | grep -qxF -- "$template"; then
        rc_fail not_found "Шаблон '$template' не найден."
        return 1
    fi
    jq_w --arg g "$group" --arg t "$template" \
        '.groups |= map(if .name==$g then .template=$t else . end)' || return 1
    CORE_GROUP_TEMPLATE="$template"
    success "Группа $group: шаблон — $template"
}
