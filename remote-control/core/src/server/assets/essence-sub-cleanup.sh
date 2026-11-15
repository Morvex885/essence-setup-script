#!/bin/bash
SUB_DIR={{sub_dir}}
LIST="${SUB_DIR}/expiry.list"
SNIP_DIR=/etc/nginx/snippets/essence-sub
# Истёкшая ссылка снимается целиком: YAML и location-сниппет, затем одна
# проверка и перезагрузка nginx. Список сроков только читается: запись
# истёкшего токена остаётся, пока его не удалит subscription remove/rotate,
# поэтому повторная публикация без нового срока снова снимается здесь.
[[ -f "$LIST" ]] || exit 0
exec 9>"${SUB_DIR}/.expiry.lock" || exit 1
flock -x 9 || exit 1
NOW=$(date +%s) || exit 1
removed=0 failed=0
while read -r token expires || [[ -n "$token" ]]; do
  [[ "$token" =~ ^[0-9a-f]{64}$ && "$expires" =~ ^[0-9]+$ ]] || continue
  (( 10#$expires <= NOW )) || continue
  for file in "${SUB_DIR}/${token}.yaml" "${SNIP_DIR}/sub-${token}.conf"; do
    [[ -e "$file" || -L "$file" ]] || continue
    if rm -f -- "$file"; then removed=1; else failed=1; fi
  done
done < "$LIST" || failed=1
if (( removed )); then
  { nginx -t && systemctl reload nginx; } >/dev/null 2>&1 || failed=1
fi
exit "$failed"
