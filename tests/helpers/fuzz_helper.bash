#!/bin/bash
# ─── Fuzz Helper Library ──────────────────────────────────────────────────────
# Dictionaries, generators, and mutation functions for fuzz tests.
# Inspired by OSS-Fuzz dictionaries and kotlinx.fuzz oracle-centric approach.
#
# Usage: source this in fuzz test setup() alongside test_helper.

# ─── Dictionaries ─────────────────────────────────────────────────────────────

DICT_SHELL_INJECTION=(
    ';' '|' '||' '&&' '&' '$' '!'
    '>' '>>' '<' '<<'
    "'" '"' '`' '\' '(' ')' '{' '}' '[' ']'
    '`id`' '$(id)' '${IFS}' '$((1))'
    ';cat /etc/passwd' '|cat /etc/passwd'
    '$(cat /etc/passwd)' '`cat /etc/passwd`'
    '${PATH}' '${HOME}' '${RANDOM}'
    $'\n' $'\r' $'\t' $'\x00'
    '$(())'  '`echo`' '$()' '${}'
    ';rm -rf /' '&&exit' '||true'
    '*' '?' '~'
)

DICT_PATH_TRAVERSAL=(
    '.' '..' '...' '../' '../../' '../../../'
    './' '/' '//' '///'
    '../../../etc/passwd' '/etc/passwd' '/dev/null' '/tmp'
    '..\\' '..\\..\\' '..\\..\\..\\'
    '%2e%2e' '%2e%2e%2f' '%252e%252e'
    $'.\x00.' $'..\x00' $'/\x00'
    '....//....//.....//'
    '.%00.' '..%00'
)

DICT_FORMAT_STRINGS=(
    '%s' '%d' '%x' '%n' '%p' '%%'
    '%s%s%s%s%s' '%x%x%x%x' '%n%n%n%n'
    '%08x' '%-20s' '%*d' '%1000000s'
    '%00' '%0d' '%0s'
)

DICT_UTF8_EDGE=(
    $'\xc0\x80'          # overlong null
    $'\xc0\xaf'          # overlong /
    $'\xe0\x80\x80'      # 3-byte overlong null
    $'\xf0\x80\x80\x80'  # 4-byte overlong
    $'\xfe\xff'          # invalid start bytes
    $'\x80'              # lone continuation byte
    $'\xc0'              # truncated 2-byte
    $'\xe0\x80'          # truncated 3-byte
    $'\xed\xa0\x80'      # surrogate half U+D800
    $'\xef\xbf\xbd'      # replacement char U+FFFD
    $'\xff\xfe'          # BOM reversed
    $'\xf4\x90\x80\x80'  # above U+10FFFF
    $'\x80\x80\x80'      # all continuation bytes
)

DICT_BOUNDARY=(
    '' ' ' '  ' $'\t' $'\n' $'\r\n' $'\r'
    'a' 'Z' '0' '.' '-' '_'
    $'\x00' $'\x01' $'\x7f' $'\xff'
)

# ─── Random Generators ────────────────────────────────────────────────────────

# random_int <min> <max>
# Echoes a random integer in [min, max]
random_int() {
    local min=$1 max=$2
    echo $(( RANDOM % (max - min + 1) + min ))
}

# random_string <length> <charset>
# Echoes a random string of given length from ASCII charset.
# NOTE: charset must be ASCII-only (single-byte chars). For multi-byte, use random_utf8.
random_string() {
    local len=$1 charset=$2
    local result=""
    local clen=${#charset}
    for ((i = 0; i < len; i++)); do
        result+="${charset:$((RANDOM % clen)):1}"
    done
    printf '%s' "$result"
}

# random_ascii <length>
random_ascii() {
    random_string "$1" "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
}

# random_pick <array_name>
# Echoes a random element from the named array
random_pick() {
    local -n _arr=$1
    printf '%s' "${_arr[RANDOM % ${#_arr[@]}]}"
}

# random_utf8 <num_chars>
# Generates a random UTF-8 string of N visible characters.
# Sets globals: FUZZ_UTF8_STR (the string), FUZZ_UTF8_LEN (char count)
# Uses arrays to avoid ${str:N:1} byte-vs-char issues on non-UTF-8 locales.
random_utf8() {
    local count=${1:-$((RANDOM % 20 + 1))}
    local -a ascii_chars=(a b c d e f g h i j k l m n o p q r s t u v w x y z 0 1 2 3 4 5 6 7 8 9)
    local -a cyrillic_chars=(а б в г д е ж з и к л м н о п р с т у ф х ц ч ш щ э ю я)
    local -a cjk_chars=(漢 字 中 国 人 大 学 生 日 本 語)
    FUZZ_UTF8_STR=""
    FUZZ_UTF8_LEN=$count
    for ((i = 0; i < count; i++)); do
        local pool=$((RANDOM % 3))
        case $pool in
            0) FUZZ_UTF8_STR+="${ascii_chars[RANDOM % ${#ascii_chars[@]}]}" ;;
            1) FUZZ_UTF8_STR+="${cyrillic_chars[RANDOM % ${#cyrillic_chars[@]}]}" ;;
            2) FUZZ_UTF8_STR+="${cjk_chars[RANDOM % ${#cjk_chars[@]}]}" ;;
        esac
    done
}

# random_tag [max_parts]
# Generates a random tag like "ABC/DEF/GHI" with 1..max_parts parts
random_tag() {
    local max_parts=${1:-5}
    local parts=$((RANDOM % max_parts + 1))
    local tag=""
    local charset="ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    for ((p = 0; p < parts; p++)); do
        local plen=$((RANDOM % 8 + 1))
        local part=""
        for ((c = 0; c < plen; c++)); do
            part+="${charset:$((RANDOM % ${#charset})):1}"
        done
        [[ -n "$tag" ]] && tag+="/"
        tag+="$part"
    done
    printf '%s' "$tag"
}

# ─── Mutation Functions ───────────────────────────────────────────────────────

# mutate_inject <string> <dict_array_name>
# Injects a random token from the dictionary at a random position in the string
mutate_inject() {
    local str="$1"
    local -n _dict=$2
    local token="${_dict[RANDOM % ${#_dict[@]}]}"
    local pos
    if [[ ${#str} -eq 0 ]]; then
        pos=0
    else
        pos=$((RANDOM % (${#str} + 1)))
    fi
    printf '%s' "${str:0:$pos}${token}${str:$pos}"
}

# mutate_replace_byte <string>
# Replaces a random byte in the string with a random byte
mutate_replace_byte() {
    local str="$1"
    [[ ${#str} -eq 0 ]] && { printf '%s' "$str"; return; }
    local pos=$((RANDOM % ${#str}))
    local random_char
    random_char=$(printf "\\x$(printf '%02x' $((RANDOM % 256)))")
    printf '%s' "${str:0:$pos}${random_char}${str:$((pos + 1))}"
}

# mutate_repeat <string> <max_repeats>
# Repeats a random segment of the string
mutate_repeat() {
    local str="$1"
    local max_rep=${2:-5}
    [[ ${#str} -eq 0 ]] && { printf '%s' "$str"; return; }
    local pos=$((RANDOM % ${#str}))
    local seg_len=$((RANDOM % 3 + 1))
    local segment="${str:$pos:$seg_len}"
    local repeats=$((RANDOM % max_rep + 2))
    local repeated=""
    for ((r = 0; r < repeats; r++)); do
        repeated+="$segment"
    done
    printf '%s' "${str:0:$pos}${repeated}${str:$((pos + seg_len))}"
}

# ─── High-Level Fuzz Strategy ─────────────────────────────────────────────────

# fuzz_mutated_input <valid_string> <dict_array_name>
# Applies a random mutation strategy to the input:
#   0 = inject token from dict
#   1 = replace random byte
#   2 = repeat segment
#   3 = pure dict payload
fuzz_mutated_input() {
    local str="$1"
    local dict_name="$2"
    local strategy=$((RANDOM % 4))
    case $strategy in
        0) mutate_inject "$str" "$dict_name" ;;
        1) mutate_replace_byte "$str" ;;
        2) mutate_repeat "$str" ;;
        3) random_pick "$dict_name" ;;
    esac
}
