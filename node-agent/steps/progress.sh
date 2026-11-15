#!/bin/bash
# ─── Прогресс исполнителя ───────────────────────────────────────────────────
# Общий процент операции (`progress=` в <op>/status, 0–100, только растёт) и
# текущее действие (`detail=`, без управляющих символов, до 120 символов, без
# секретов: только имена пакетов, доменов и постоянные тексты).
#
# Этапу достаётся диапазон процентов по весу (progress_plan): долгие
# (packages, prepare с AmneziaWG и Telegram, certificate) — больше. Внутри
# этапа шаг выбирает долю диапазона (progress_span) и движется по ней
# (progress_in); apt сообщает свой процент через APT::Status-Fd (agent_apt).
# Одни проценты пишутся не чаще раза в секунду (по $SECONDS — Bash 3.2 без
# printf '%(…)T'), смена действия — сразу (их столько, сколько шагов). Запись
# — write_status из apply.sh (tmp + mv); без него (этап подключён отдельно,
# тесты) значения только запоминаются.

PROGRESS=0
DETAIL=""
PROGRESS_STAGES=()
PROGRESS_BOUNDS=()
PROGRESS_STAGE_LO=0
PROGRESS_STAGE_HI=100
PROGRESS_SPAN_LO=0
PROGRESS_SPAN_HI=100
PROGRESS_WRITTEN=-1
PROGRESS_DIRTY=false

# Вес фичи внутри этапа prepare (сборка модуля ядра, сборка Go — минуты).
progress_feature_weight() {
    case "$1" in
        awg) echo 30 ;;
        telegram) echo 35 ;;
        *) echo 1 ;;
    esac
}

# Веса этапов операции по spec: строки «этап вес».
_progress_weights() {
    local weight feature count
    if [[ "$OP_MODE" == teardown ]]; then
        printf '%s\n' "config 6" "firewall 2" "cleanup 2"
        return
    fi
    weight=20
    [[ "$NGINX" == true ]] && weight=25
    printf 'packages %s\n' "$weight"
    printf '%s\n' "system 1" "mihomo 4" "dns 1"
    if [[ -n "$SITE_NAME" ]]; then echo "site 4"; else echo "site 1"; fi
    count=0
    for weight in $CERTS; do count=$((count + 1)); done
    printf 'certificate %s\n' $((count ? 4 + 6 * count : 1))
    weight=2
    [[ "$HY2_CERT" == true ]] && weight=$((weight + 1))
    for feature in $FEATURES; do
        weight=$((weight + $(progress_feature_weight "$feature")))
    done
    printf 'prepare %s\n' "$weight"
    printf '%s\n' "config 4" "firewall 1" "cleanup 1"
}

# progress_plan — границы этапов (PROGRESS_STAGES, PROGRESS_BOUNDS: начало
# каждого этапа и 100 в конце) из весов текущего spec.
progress_plan() {
    local name weight total=0 sum=0 names=() weights=() i
    while read -r name weight; do
        names+=("$name")
        weights+=("$weight")
        total=$((total + weight))
    done < <(_progress_weights)
    PROGRESS_STAGES=("${names[@]}")
    PROGRESS_BOUNDS=()
    for i in "${!weights[@]}"; do
        PROGRESS_BOUNDS+=($((sum * 100 / total)))
        sum=$((sum + weights[i]))
    done
    PROGRESS_BOUNDS+=(100)
}

# _progress_clean <текст> → DETAIL: без управляющих символов, до 120 символов.
# Локаль UTF-8 — чтобы и то и другое считалось по символам, а не байтам.
_progress_clean() {
    local LC_ALL=C.UTF-8
    local text="${1//[[:cntrl:]]/}"
    DETAIL="${text:0:120}"
} 2>/dev/null

_progress_write() {
    PROGRESS_WRITTEN="$SECONDS"
    PROGRESS_DIRTY=false
    if declare -F write_status >/dev/null; then
        write_status
    fi
}

# _progress_raise <абсолютный процент> — только вверх, не больше 100.
_progress_raise() {
    local value="$1"
    ((value > 100)) && value=100
    ((value > PROGRESS)) && PROGRESS="$value"
    return 0
}

# progress_stage <этап> — диапазон этапа; процент — его начало, действие пусто.
# Запись — вместе со stage= (write_status вызывает stage()).
progress_stage() {
    local i
    PROGRESS_STAGE_LO="$PROGRESS"
    PROGRESS_STAGE_HI="$PROGRESS"
    for i in "${!PROGRESS_STAGES[@]}"; do
        if [[ "${PROGRESS_STAGES[$i]}" == "$1" ]]; then
            PROGRESS_STAGE_LO="${PROGRESS_BOUNDS[$i]}"
            PROGRESS_STAGE_HI="${PROGRESS_BOUNDS[$((i + 1))]}"
            break
        fi
    done
    PROGRESS_SPAN_LO="$PROGRESS_STAGE_LO"
    PROGRESS_SPAN_HI="$PROGRESS_STAGE_HI"
    _progress_raise "$PROGRESS_STAGE_LO"
    DETAIL=""
}

# progress_span <от> <до> — шаг занимает эту долю (в процентах) этапа.
progress_span() {
    local width=$((PROGRESS_STAGE_HI - PROGRESS_STAGE_LO))
    PROGRESS_SPAN_LO=$((PROGRESS_STAGE_LO + width * $1 / 100))
    PROGRESS_SPAN_HI=$((PROGRESS_STAGE_LO + width * $2 / 100))
    progress_in 0
}

# progress_in <процент шага> — процент внутри текущего шага; запись не чаще
# раза в секунду (пропущенное запишет следующая запись или progress_flush).
progress_in() {
    local pct="$1"
    ((pct < 0)) && pct=0
    ((pct > 100)) && pct=100
    _progress_raise $((PROGRESS_SPAN_LO + (PROGRESS_SPAN_HI - PROGRESS_SPAN_LO) * pct / 100))
    if [[ "$SECONDS" != "$PROGRESS_WRITTEN" ]]; then
        _progress_write
    else
        PROGRESS_DIRTY=true
    fi
}

# progress_detail <текст> — новое текущее действие; пишется сразу.
progress_detail() {
    local before="$DETAIL"
    _progress_clean "$1"
    [[ "$DETAIL" == "$before" ]] && return 0
    _progress_write
}

# progress_note <процент шага> <текст> — частые обновления (строки apt):
# и процент, и действие — не чаще раза в секунду.
progress_note() {
    _progress_clean "$2"
    progress_in "$1"
}

# progress_flush — записать отложенное обновление.
progress_flush() {
    [[ "$PROGRESS_DIRTY" == true ]] && _progress_write
    return 0
}

# _apt_action <пакет> <сообщение> → REPLY: действие dpkg по строке pmstatus
# (сообщения apt — английские).
_apt_action() {
    local package="$1" message="$2"
    case "$message" in
        "Preparing to configure"*|Configuring*|"Setting up"*)
            if [[ "$package" == *-dkms ]]; then
                printf -v REPLY 'сборка модуля ядра %s' "${package%-dkms}"
            else
                printf -v REPLY '%s: настройка' "$package"
            fi ;;
        "Preparing for removal"*|Removing*|Removed*|"Completely removing"*) printf -v REPLY '%s: удаление' "$package" ;;
        Preparing*) printf -v REPLY '%s: подготовка' "$package" ;;
        Unpacking*) printf -v REPLY '%s: распаковка' "$package" ;;
        Installing*|Installed*) printf -v REPLY '%s: установка' "$package" ;;
        "Running post-installation trigger"*) printf -v REPLY '%s: триггеры' "$package" ;;
        "Running dpkg"*) REPLY='запуск dpkg' ;;
        *) printf -v REPLY '%s: обработка' "$package" ;;
    esac
}

# _agent_apt_status <от> <до> <pid apt> — строки APT::Status-Fd со стандартного
# входа (`dlstatus:<n>:<процент>:<текст>`, `pmstatus:<пакет>[:<arch>]:<процент>:<текст>`):
# dlstatus — первые 30 % доли шага [от, до], pmstatus — остальные. Чтение
# кончается на EOF или через секунду тишины после выхода apt: потомки apt
# (скрипты пакетов, оставленные в фоне), унаследовавшие дескриптор, не держат шаг.
_agent_apt_status() {
    local from="$1" to="$2" pid="$3" mid line kind package pct rest REPLY status gone=false
    mid=$((from + (to - from) * 3 / 10))
    while :; do
        if IFS= read -r -t 1 line; then
            :
        else
            status=$?
            ((status > 128)) || break
            [[ "$gone" == true ]] && break
            kill -0 "$pid" 2>/dev/null || gone=true
            continue
        fi
        kind="${line%%:*}"
        rest="${line#*:}"
        package="${rest%%:*}"
        rest="${rest#*:}"
        pct="${rest%%:*}"
        if [[ ! "${pct%%.*}" =~ ^[0-9]+$ && "$rest" == *:* ]]; then
            rest="${rest#*:}"
            pct="${rest%%:*}"
        fi
        pct="${pct%%.*}"
        [[ "$pct" =~ ^[0-9]{1,3}$ ]] || continue
        ((pct > 100)) && pct=100
        case "$kind" in
            dlstatus) progress_note $((from + (mid - from) * pct / 100)) "загрузка пакетов" ;;
            pmstatus)
                _apt_action "$package" "${rest#*:}"
                progress_note $((mid + (to - mid) * pct / 100)) "$REPLY" ;;
        esac
    done
}

# agent_apt <от> <до> <команда apt-get> [аргументы…] — apt-get без вопросов;
# его процент (APT::Status-Fd на дескрипторе 3, приватный FIFO) ведёт долю
# [от, до] текущего шага. apt идёт в фоне, читатель — в этом же процессе
# (процент и время записи общие) и не ждёт потомков apt после его выхода.
# Вывод apt — в журнал операции. Код — код apt-get.
agent_apt() {
    local from="$1" to="$2" command="$3" rc=0 dir pid
    shift 3
    dir="$(mktemp -d)" || return 1
    if ! mkfifo -m 600 "$dir/status"; then
        rm -rf "$dir"
        return 1
    fi
    DEBIAN_FRONTEND=noninteractive apt-get "$command" -o APT::Status-Fd=3 "$@" 3>"$dir/status" &
    pid=$!
    _agent_apt_status "$from" "$to" "$pid" <"$dir/status"
    wait "$pid" || rc=$?
    rm -rf "$dir"
    if ((rc == 0)); then
        progress_in "$to"
    fi
    progress_flush
    return "$rc"
}
