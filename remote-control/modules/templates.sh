#!/bin/bash
# ─── Обработка шаблонов с групповыми тегами ─────────────────────────────────
#
# Формат тегов в шаблоне:
#   # --- GROUP ---        — начало блока
#   ...содержимое...
#   # --- GROUP ---        — конец блока (тот же тег)
#
# Мульти-группа:
#   # --- ROUTER/PC ---    — активен для ROUTER и PC
#
# Логика:
#   - Если целевая группа входит в список → оставить содержимое, убрать маркеры
#   - Если не входит → удалить блок целиком (маркеры + содержимое)

BUILTIN_TEMPLATES_DIR="$SCRIPT_DIR/templates"
if [[ -z ${TEMPLATES_DIR:-} || ${CONFIG_SOURCE:-local} != github ]]; then
    TEMPLATES_DIR="${TEMPLATES_DIR:-$CONFIG_DIR/templates}"
fi

_find_template() {
    local name="${1:-default.yaml}"
    [[ "$name" =~ ^[A-Za-z0-9._-]+\.yaml$ ]] || { echo ""; return; }
    if [[ -f "$TEMPLATES_DIR/$name" ]]; then
        echo "$TEMPLATES_DIR/$name"
    elif [[ ${CONFIG_SOURCE:-local} != github && -f "$BUILTIN_TEMPLATES_DIR/$name" ]]; then
        echo "$BUILTIN_TEMPLATES_DIR/$name"
    else
        echo ""
    fi
}

# Возвращает путь к шаблону, назначенному группе (или default.yaml)
_template_for_group() {
    local group="$1"
    local tpl
    tpl=$(jq_r --arg g "$group" '.groups[] | select(.name==$g) | .template // "default.yaml"')
    [[ -z "$tpl" ]] && tpl="default.yaml"
    _find_template "$tpl"
}

# Имя шаблона группы (для сообщений)
_template_name_for_group() {
    local group="$1"
    local tpl
    tpl=$(jq_r --arg g "$group" '.groups[] | select(.name==$g) | .template // "default.yaml"')
    [[ -z "$tpl" ]] && tpl="default.yaml"
    echo "$tpl"
}

# Список пользовательских и встроенных шаблонов без дублей.
_list_templates() {
    local -a templates=()
    local dir f name
    for dir in "$TEMPLATES_DIR" "$BUILTIN_TEMPLATES_DIR"; do
        [[ -d "$dir" ]] || continue
        for f in "$dir"/*.yaml; do
            [[ -f "$f" ]] || continue
            name=$(basename "$f")
            array_contains "$name" "${templates[@]}" || templates+=("$name")
        done
    done
    [[ ${#templates[@]} -gt 0 ]] && printf '%s\n' "${templates[@]}" | sort
}

# core_template_import NAME FILE — атомарно копирует FILE в $TEMPLATES_DIR/NAME.yaml.
# NAME указывается без .yaml (суффикс отбрасывается). Результат: CORE_TEMPLATE_IMPORT_NAME.
core_template_import() {
    local name="${1:-}" file="${2:-}" tmp
    CORE_TEMPLATE_IMPORT_NAME=""
    name="${name%.yaml}"
    if [[ ! "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
        rc_fail invalid "Имя шаблона может содержать только буквы, цифры, точку, - и _"
        return 1
    fi
    if [[ -z "$file" || ! -f "$file" || ! -r "$file" ]]; then
        rc_fail invalid "Файл '$file' не найден или недоступен для чтения."
        return 1
    fi
    mkdir -p "$TEMPLATES_DIR" || { rc_fail failed "Не удалось создать каталог шаблонов."; return 1; }
    tmp=$(umask 077; mktemp "$TEMPLATES_DIR/.import.XXXXXX") || {
        rc_fail failed "Не удалось создать временный файл шаблона."
        return 1
    }
    if ! cp -- "$file" "$tmp" || ! mv -f "$tmp" "$TEMPLATES_DIR/${name}.yaml"; then
        rm -f "$tmp"
        rc_fail failed "Не удалось сохранить шаблон ${name}.yaml."
        return 1
    fi
    CORE_TEMPLATE_IMPORT_NAME="${name}.yaml"
    success "Шаблон ${name}.yaml импортирован"
}

# core_template_create NAME [FROM] [GROUP] — новый пользовательский шаблон на основе
# FROM или default.yaml (иначе пустой); с GROUP сразу назначается группе.
# Результат: CORE_TEMPLATE_CREATE_NAME, CORE_TEMPLATE_CREATE_BASE (пусто для пустого шаблона).
core_template_create() {
    local name="${1:-}" from="${2:-}" group="${3:-}" new_file base_file
    CORE_TEMPLATE_CREATE_NAME=""
    CORE_TEMPLATE_CREATE_BASE=""
    name="${name%.yaml}"
    if [[ ! "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
        rc_fail invalid "Имя шаблона может содержать только буквы, цифры, точку, - и _"
        return 1
    fi
    new_file="$TEMPLATES_DIR/${name}.yaml"
    if [[ -e "$new_file" || -L "$new_file" ]]; then
        rc_fail conflict "Шаблон '${name}.yaml' уже существует."
        return 1
    fi
    if [[ -n "$from" ]]; then
        base_file=$(_find_template "$from")
        [[ -n "$base_file" ]] || { rc_fail not_found "Шаблон '$from' не найден."; return 1; }
    else
        from="default.yaml"
        base_file=$(_find_template "$from")
    fi
    mkdir -p "$TEMPLATES_DIR" || { rc_fail failed "Не удалось создать каталог шаблонов."; return 1; }
    if [[ -n "$base_file" ]]; then
        cp -- "$base_file" "$new_file" || { rm -f "$new_file"; rc_fail failed "Не удалось создать шаблон ${name}.yaml."; return 1; }
        CORE_TEMPLATE_CREATE_BASE="$from"
    else
        : > "$new_file" || { rc_fail failed "Не удалось создать шаблон ${name}.yaml."; return 1; }
        warn "default.yaml не найден — создан пустой шаблон"
    fi
    if [[ -n "$group" ]] && ! core_group_set_template "$group" "${name}.yaml"; then
        rm -f "$new_file"
        return 1
    fi
    CORE_TEMPLATE_CREATE_NAME="${name}.yaml"
    success "Шаблон ${name}.yaml создан"
}

# process_template <template_file> <target_group>
# Выводит обработанный шаблон в stdout
process_template() {
    local template="$1"
    local target="$2"

    local in_block=0
    local block_match=0
    local block_tag=""

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Проверяем маркер группы: # --- GROUP --- или # --- GROUP1/GROUP2 ---
        if [[ "$line" =~ ^#\ ---\ ([A-Z0-9/_]+)\ ---$ ]]; then
            local tag="${BASH_REMATCH[1]}"

            if [[ "$in_block" -eq 0 ]]; then
                # Начало блока
                in_block=1
                block_tag="$tag"
                block_match=$(_group_matches "$tag" "$target")
                # Маркер не выводится
                continue
            elif [[ "$tag" == "$block_tag" ]]; then
                # Конец блока (совпадающий тег)
                in_block=0
                block_tag=""
                # Маркер не выводится
                continue
            fi
        fi

        if [[ "$in_block" -eq 1 ]]; then
            if [[ "$block_match" -eq 1 ]]; then
                echo "$line"
            fi
            # Если не match — строка удаляется (не выводится)
        else
            echo "$line"
        fi
    done < "$template"
}

# Проверяет, входит ли target_group в tag (разделитель /)
# _group_matches "ROUTER/PC" "PC" → 1
# _group_matches "ROUTER/PC" "MOBILE" → 0
_group_matches() {
    local tag="$1"
    local target="$2"

    [[ -z "$target" ]] && { echo 0; return; }

    IFS='/' read -ra groups <<< "$tag"
    for g in "${groups[@]}"; do
        if [[ "$g" == "$target" ]]; then
            echo 1
            return
        fi
    done
    echo 0
}
