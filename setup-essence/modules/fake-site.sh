#!/bin/bash
# ─── Генерация сайта-заглушки ────────────────────────────────────────────────

setup_fake_site() {
    local TARGET_DIR="$1" SOURCE_CHOICE
    while true; do
        echo ""
        box_top
        box_center "Сайт-заглушка"
        box_mid
        menu_item 1 "Simple Web Templates (by eGamesAPI)" GREEN
        menu_item 2 "SNI Templates (by distillium)" GREEN
        menu_item 3 "Nothing Templates (by prettyleaf)" GREEN
        menu_item 4 "Случайный" NC
        menu_item 0 "Отмена" NC
        box_bot
        echo ""
        if ! IFS= read -rp "  Выберите действие [Enter = 4]: " SOURCE_CHOICE; then
            return 1
        fi
        SOURCE_CHOICE="${SOURCE_CHOICE%$'\r'}"
        [[ -z "$SOURCE_CHOICE" ]] && SOURCE_CHOICE=4
        case "$SOURCE_CHOICE" in
            1) _randomhtml "simple" "$TARGET_DIR"; return $? ;;
            2) _randomhtml "sni" "$TARGET_DIR"; return $? ;;
            3) _randomhtml "nothing" "$TARGET_DIR"; return $? ;;
            4) _randomhtml "" "$TARGET_DIR"; return $? ;;
            0) return 1 ;;
            *) warn "Неверный выбор." ;;
        esac
    done
}

_randomhtml() {
    local template_source="$1"
    local target_dir="$2"
    local _saved_dir="$PWD"

    cd /opt/ || { warn "Не удалось перейти в /opt/"; return 1; }

    rm -f main.zip 2>/dev/null
    rm -rf simple-web-templates-main/ sni-templates-main/ nothing-sni-main/ 2>/dev/null

    local template_urls=(
        "https://github.com/eGamesAPI/simple-web-templates/archive/refs/heads/main.zip"
        "https://github.com/distillium/sni-templates/archive/refs/heads/main.zip"
        "https://github.com/prettyleaf/nothing-sni/archive/refs/heads/main.zip"
    )

    local selected_url
    if [[ -z "$template_source" ]]; then
        selected_url=${template_urls[$RANDOM % ${#template_urls[@]}]}
    elif [[ "$template_source" == "simple" ]]; then
        selected_url=${template_urls[0]}
    elif [[ "$template_source" == "sni" ]]; then
        selected_url=${template_urls[1]}
    elif [[ "$template_source" == "nothing" ]]; then
        selected_url=${template_urls[2]}
    else
        selected_url=${template_urls[1]}
    fi

    info "Скачиваю шаблон..."
    local attempt=0
    while ! wget --timeout=15 --tries=2 --show-progress "$selected_url" -O main.zip; do
        attempt=$((attempt + 1))
        if [[ $attempt -ge 3 ]]; then
            warn "Не удалось скачать шаблон после 3 попыток."
            while true; do
                echo ""
                box_top
                box_center "Ошибка загрузки сайта"
                box_mid
                box_line " Не удалось скачать выбранный шаблон."
                menu_item 1 "Попробовать снова" GREEN
                menu_item 2 "Выбрать другой шаблон" YELLOW
                menu_item 0 "Отмена" NC
                box_bot
                echo ""
                if ! IFS= read -rp "  Выберите действие: " RETRY_CHOICE; then
                    rm -f main.zip
                    cd "$_saved_dir"
                    return 1
                fi
                RETRY_CHOICE="${RETRY_CHOICE%$'\r'}"
                case "$RETRY_CHOICE" in
                    1) attempt=0; break ;;
                    2)
                        rm -f main.zip
                        cd "$_saved_dir"
                        setup_fake_site "$target_dir"
                        return $?
                        ;;
                    0)
                        rm -f main.zip
                        cd "$_saved_dir"
                        return 1
                        ;;
                    *) warn "Неверный выбор." ;;
                esac
            done
            continue
        fi
        warn "Ошибка загрузки, повтор через 3 сек... $attempt/3"
        sleep 3
    done

    if ! unzip -o main.zip &>/dev/null; then
        rm -f main.zip
        cd "$_saved_dir"
        warn "Не удалось распаковать архив шаблона"
        return 1
    fi
    rm -f main.zip

    local template_dir
    if [[ "$selected_url" == *"eGamesAPI"* ]]; then
        template_dir="simple-web-templates-main"
        cd "$template_dir" || {
            rm -f main.zip
            cd "$_saved_dir"
            warn "Не удалось войти в $template_dir"
            return 1
        }
        rm -rf assets ".gitattributes" "README.md" "_config.yml" 2>/dev/null
    elif [[ "$selected_url" == *"nothing-sni"* ]]; then
        template_dir="nothing-sni-main"
        cd "$template_dir" || {
            rm -f main.zip
            cd "$_saved_dir"
            warn "Не удалось войти в $template_dir"
            return 1
        }
        rm -rf .github README.md 2>/dev/null
    else
        template_dir="sni-templates-main"
        cd "$template_dir" || {
            rm -f main.zip
            cd "$_saved_dir"
            warn "Не удалось войти в $template_dir"
            return 1
        }
        rm -rf assets "README.md" "index.html" 2>/dev/null
    fi

    local RandomHTML
    if [[ "$selected_url" == *"nothing-sni"* ]]; then
        local selected_number=$((RANDOM % 8 + 1))
        RandomHTML="${selected_number}.html"
    else
        local templates=()
        while IFS= read -r template; do
            templates+=("$template")
        done < <(find . -maxdepth 1 -type d -not -path . | sed 's|./||')
        RandomHTML="${templates[$RANDOM % ${#templates[@]}]}"
    fi

    if [[ "$selected_url" == *"distillium"* && "$RandomHTML" == "503 error pages" ]]; then
        local versions=("v1" "v2")
        local RandomVersion="${versions[$RANDOM % ${#versions[@]}]}"
        RandomHTML="$RandomHTML/$RandomVersion"
    fi

    # ── Антифингерпринтинг ────────────────────────────────────────────────────
    local random_meta_id random_comment random_class_suffix random_title_suffix
    local random_id_suffix random_meta_name random_username random_class_prefix
    random_meta_id=$(openssl rand -hex 16)
    random_comment=$(openssl rand -hex 8)
    random_class_suffix=$(openssl rand -hex 4)
    random_title_suffix=$(openssl rand -hex 4)
    random_id_suffix=$(openssl rand -hex 4)

    local meta_names=("viewport-id" "session-id" "track-id" "render-id" "page-id" "config-id")
    local meta_usernames=("Payee6296" "UserX1234" "AlphaBeta" "GammaRay" "DeltaForce" "EchoZulu" "Foxtrot99" "HotelCalifornia" "IndiaInk" "JulietBravo")
    local class_prefixes=("style" "data" "ui" "layout" "theme" "view")

    random_meta_name=${meta_names[$RANDOM % ${#meta_names[@]}]}
    random_username=${meta_usernames[$RANDOM % ${#meta_usernames[@]}]}
    random_class_prefix=${class_prefixes[$RANDOM % ${#class_prefixes[@]}]}

    local random_class="${random_class_prefix}-${random_class_suffix}"
    local random_title="Page_${random_title_suffix}"
    local random_footer_text="Designed by RandomSite_${random_title_suffix}"

    find "./$RandomHTML" -type f -name "*.html" -exec sed -i \
        -e "s|<!-- Website template by freewebsitetemplates.com -->||" \
        -e "s|<!-- Theme by: WebThemez.com -->||" \
        -e "s|<a href=\"http://freewebsitetemplates.com\">Free Website Templates</a>|<span>${random_footer_text}</span>|" \
        -e "s|<a href=\"http://webthemez.com\" alt=\"webthemez\">WebThemez.com</a>|<span>${random_footer_text}</span>|" \
        -e "s|id=\"Content\"|id=\"rnd_${random_id_suffix}\"|" \
        -e "s|id=\"subscribe\"|id=\"sub_${random_id_suffix}\"|" \
        -e "s|<title>.*</title>|<title>${random_title}</title>|" \
        -e "s/<\/head>/<meta name=\"${random_meta_name}\" content=\"${random_meta_id}\">\n<!-- ${random_comment} -->\n<\/head>/" \
        -e "s/<body/<body class=\"${random_class}\"/" \
        -e "s/CHANGEMEPLS/${random_username}/g" \
        {} \;

    find "./$RandomHTML" -type f -name "*.css" -exec sed -i \
        -e "1i\/* ${random_comment} */" \
        -e "1i.${random_class} { display: block; }" \
        {} \;

    info "Выбран шаблон: $RandomHTML"

    if [[ -d "${RandomHTML}" ]]; then
        rm -rf "${target_dir:?}"/*
        cp -a "${RandomHTML}"/. "$target_dir/"
        success "Шаблон скопирован в $target_dir"
    elif [[ -f "${RandomHTML}" ]]; then
        cp "${RandomHTML}" "$target_dir/index.html"
        success "Шаблон скопирован в $target_dir/index.html"
    else
        cd "$_saved_dir"
        warn "Шаблон '$RandomHTML' не найден в распакованном архиве"
        return 1
    fi

    cd /opt/
    rm -rf simple-web-templates-main/ sni-templates-main/ nothing-sni-main/
    cd "$_saved_dir"
}
